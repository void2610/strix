//
//  StreamResourceLoader.swift
//  Strix
//
//  progressive ストリーム（googlevideo の直 URL）を AVPlayer で扱うための ResourceLoader。
//  2 つの役割を持つ:
//   1. open-ended Range だと googlevideo に強くスロットリング（約 32KB/s）されるため、区切り付き Range に変換する。
//   2. AVPlayer が単一 MP4 を丸ごと先読み DL してしまうため、再生位置から一定窓より先の取得を遅延（ページング）し、
//      通信量を実際の再生分に近づける。
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers

private var streamLoaderAssociationKey = 0

final class StreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "strixstream"
    /// 1 リクエストあたりの最大バイト数。区切り付きにしてスロットリングを回避する。
    private static let chunkSize: Int64 = 2_097_152
    /// 再生位置からこの秒数より先のチャンクは、再生が近づくまで取得を遅延する。
    private static let prefetchWindowSeconds: Double = 60

    private let realURL: URL
    private let userAgent: String
    private let session = URLSession(configuration: .ephemeral)

    private let lock = NSLock()
    private weak var _player: AVPlayer?
    private var _totalLength: Int64?

    private init(realURL: URL, userAgent: String) {
        self.realURL = realURL
        self.userAgent = userAgent
    }

    /// 実 URL からカスタムスキームの AVURLAsset を作り、自身を delegate として保持させる
    static func makeAsset(realURL: URL, userAgent: String) -> AVURLAsset {
        var comps = URLComponents(url: realURL, resolvingAgainstBaseURL: false)
        comps?.scheme = scheme
        let asset = AVURLAsset(url: comps?.url ?? realURL)
        let loader = StreamResourceLoader(realURL: realURL, userAgent: userAgent)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "strix.stream"))
        objc_setAssociatedObject(asset, &streamLoaderAssociationKey, loader, .OBJC_ASSOCIATION_RETAIN)
        return asset
    }

    /// item にこの loader が紐づいていれば、ページング判定用の player を設定する。HLS 等の通常 item では何もしない。
    static func attachPlayer(_ player: AVPlayer, to item: AVPlayerItem?) {
        guard let asset = item?.asset as? AVURLAsset,
              let loader = objc_getAssociatedObject(asset, &streamLoaderAssociationKey) as? StreamResourceLoader else { return }
        loader.lock.lock()
        loader._player = player
        loader.lock.unlock()
    }

    private func snapshot() -> (AVPlayer?, Int64?) {
        lock.lock(); defer { lock.unlock() }
        return (_player, _totalLength)
    }

    private func setTotalLength(_ total: Int64) {
        lock.lock(); _totalLength = total; lock.unlock()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        Task { await handle(loadingRequest) }
        return true
    }

    private func handle(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }
        let start = dataRequest.requestedOffset
        await waitUntilWithinWindow(loadingRequest: loadingRequest)
        if loadingRequest.isCancelled { return }

        let end = start + min(Int64(dataRequest.requestedLength), Self.chunkSize) - 1
        var request = URLRequest(url: realURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }
            if let info = loadingRequest.contentInformationRequest {
                if let contentType = http.value(forHTTPHeaderField: "Content-Type"),
                   let mime = contentType.components(separatedBy: ";").first,
                   let ut = UTType(mimeType: mime) {
                    info.contentType = ut.identifier
                }
                info.isByteRangeAccessSupported = true
                if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalStr = contentRange.components(separatedBy: "/").last,
                   let total = Int64(totalStr) {
                    info.contentLength = total
                    setTotalLength(total)
                } else {
                    info.contentLength = http.expectedContentLength
                }
            }
            dataRequest.respond(with: data)
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }

    /// 再生位置から prefetchWindowSeconds より先までバッファ済みなら、再生が近づくまで取得を遅延する。
    /// player/再生時間が不明な間（再生開始直後など）はページングせず即取得する。
    /// バイト⇔時間の線形換算は VBR で破綻し、再生停止 → currentTime 固定 → 窓が前進せず永久停止する
    /// デッドロックを生むため、実バッファ済み秒数（loadedTimeRanges）で判定する。
    private func waitUntilWithinWindow(loadingRequest: AVAssetResourceLoadingRequest) async {
        while !loadingRequest.isCancelled {
            let (player, _) = snapshot()
            guard let player, let item = player.currentItem else { return }
            let current = player.currentTime().seconds
            guard current.isFinite,
                  let range = item.loadedTimeRanges.last?.timeRangeValue else { return }
            let bufferedEnd = (range.start + range.duration).seconds
            guard bufferedEnd.isFinite else { return }
            if bufferedEnd - current < Self.prefetchWindowSeconds { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
