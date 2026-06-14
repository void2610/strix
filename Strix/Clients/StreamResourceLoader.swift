//
//  StreamResourceLoader.swift
//  Strix
//
//  adaptive ストリーム（gir=yes）は open-ended Range だと googlevideo に強くスロットリング
//  （約 32KB/s）されるため、AVPlayer の要求を区切り付き Range に変換して代理取得する。
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers

private var streamLoaderAssociationKey = 0

final class StreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "strixstream"
    /// 1 リクエストあたりの最大バイト数。open-ended を避け区切り付きにすることでスロットリングを回避する。
    private static let chunkSize: Int64 = 2_097_152

    private let realURL: URL
    private let userAgent: String
    private let session = URLSession(configuration: .ephemeral)

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
        // チャンク上限で区切ることで open-ended のスロットリングを避ける
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
}
