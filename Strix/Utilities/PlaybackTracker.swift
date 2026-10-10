//
//  PlaybackTracker.swift
//  Strix
//
//  YouTube に再生状況を報告して視聴履歴をアカウントに記録するトラッカー。
//  /player レスポンスの playbackTracking URL に対して定期的にリクエストを送信する。
//

import Foundation
import AVFoundation

/// YouTube の視聴トラッキングを管理する。
/// 再生開始時に videostatsPlaybackUrl を送信し、
/// 以降 30 秒間隔で videostatsWatchtimeUrl を送信する。
final class PlaybackTracker {
    /// リクエストを送り、HTTP ステータスを返す（通信できなければ nil）
    typealias Send = (URLRequest) async -> Int?

    private let send: Send
    private let retryDelays: [Duration]
    private var session: Session?
    private var timer: Timer?

    init(send: @escaping Send = PlaybackTracker.sendWithURLSession, retryDelays: [Duration] = [.seconds(2), .seconds(5)]) {
        self.send = send
        self.retryDelays = retryDelays
    }

    /// 1 本の動画の再生ごとの報告状態
    private final class Session {
        /// CPN（Client Playback Nonce）— YouTube が再生セッションを識別する 16 文字のランダム文字列
        let cpn = PlaybackTracker.generateCPN()
        /// 再生トラッキング開始時刻（ping の rt=経過実時間 算出用）
        let startDate = Date()
        weak var player: AVPlayer?
        var trackingURLs: PlaybackTrackingURLs?
        var lastReportedTime: Double = 0
        var isActive = true

        init(player: AVPlayer) {
            self.player = player
        }
    }

    /// 新しい動画の再生トラッキングを開始する。送信先の URL は取得に時間がかかるため、届いてから報告を始める
    @discardableResult
    func start(player: AVPlayer, trackingURLs: @escaping () async -> PlaybackTrackingURLs?) -> Task<Void, Never> {
        stop()
        let session = Session(player: player)
        self.session = session
        let startTime = max(0, player.currentTime().seconds)
        return Task {
            guard let urls = await trackingURLs() else {
                strixLog("tracking: URL なし、スキップ")
                return
            }
            session.trackingURLs = urls
            // 履歴への登録はこの送信で決まるため、すぐに別の動画へ移った場合も取り消さない
            await sendPlaybackStart(urls: urls, cpn: session.cpn, currentTime: startTime)
            guard session.isActive else { return }
            // 公式クライアントに倣い開始直後にも watchtime を送る（視聴確定のため）
            try? await Task.sleep(for: .seconds(5))
            guard session.isActive else { return }
            sendWatchtime(session)
            // 30 秒ごとに watchtime を報告
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self, weak session] _ in
                MainActor.assumeIsolated {
                    guard let self, let session, session.isActive else { return }
                    self.sendWatchtime(session)
                }
            }
        }
    }

    /// トラッキングを停止する（動画切り替え・画面離脱時）
    func stop() {
        timer?.invalidate()
        timer = nil
        guard let session else { return }
        // 停止前に最後の watchtime を送信
        sendWatchtime(session)
        session.isActive = false
        self.session = nil
    }

    // MARK: - Private

    /// 再生開始を報告する（videostatsPlaybackUrl）。履歴に残るかがこれで決まるため、失敗したら間隔を空けて送り直す
    private func sendPlaybackStart(urls: PlaybackTrackingURLs, cpn: String, currentTime: Double) async {
        guard let url = Self.trackingURL(urls.videostatsPlaybackURL, [
            "ver": "2", "cpn": cpn, "cmt": String(format: "%.3f", currentTime),
        ]) else { return }
        for delay in [Duration.zero] + retryDelays {
            if delay > .zero { try? await Task.sleep(for: delay) }
            let status = await send(Self.request(for: url))
            strixLog("tracking[playback] \(status.map { "HTTP \($0)" } ?? "通信エラー")")
            if let status, (200..<300).contains(status) { return }
        }
    }

    /// 視聴時間を報告する（videostatsWatchtimeUrl）
    private func sendWatchtime(_ session: Session) {
        guard let urls = session.trackingURLs, let player = session.player else { return }
        let currentTime = player.currentTime().seconds
        guard currentTime > 0 else { return }

        let rt = max(0, Date().timeIntervalSince(session.startDate))
        guard let url = Self.trackingURL(urls.videostatsWatchtimeURL, [
            "ver": "2",
            "cpn": session.cpn,
            "st": String(format: "%.3f", session.lastReportedTime),
            "et": String(format: "%.3f", currentTime),
            "cmt": String(format: "%.3f", currentTime),
            "rt": String(format: "%.0f", rt),
            "state": "playing",
        ]) else { return }
        session.lastReportedTime = currentTime
        let request = Self.request(for: url)
        Task {
            let status = await send(request)
            strixLog("tracking[watchtime] \(status.map { "HTTP \($0)" } ?? "通信エラー")")
        }
    }

    /// URL のクエリに値を付け足す。同名のキーは上書きし、YouTube が付けた他の値はエンコードごと残す
    static func trackingURL(_ base: String, _ params: KeyValuePairs<String, String>) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        let keys = Set(params.map(\.key))
        var pairs = (components.percentEncodedQuery ?? "").split(separator: "&").map(String.init)
        pairs.removeAll { keys.contains(String($0.prefix { $0 != "=" })) }
        pairs += params.map { "\($0.key)=\($0.value)" }
        components.percentEncodedQuery = pairs.joined(separator: "&")
        return components.url
    }

    private static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(YouTubeConstants.webUserAgent, forHTTPHeaderField: "User-Agent")
        // Cookie + SAPISIDHASH + X-Origin/X-Goog-AuthUser を付与
        ContentClient.applyAuth(to: &request)
        // SAPISIDHASH は origin を含めて計算されるため、サーバ検証用に Origin も必須
        request.setValue(YouTubeConstants.origin, forHTTPHeaderField: "Origin")
        return request
    }

    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    static func sendWithURLSession(_ request: URLRequest) async -> Int? {
        guard let (_, response) = try? await urlSession.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// CPN（Client Playback Nonce）を生成する — YouTube 公式と同じ 16 文字のランダム文字列
    static func generateCPN() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        // chars は空でないため randomElement() は必ず値を返す
        return String((0..<16).compactMap { _ in chars.randomElement() })
    }
}
