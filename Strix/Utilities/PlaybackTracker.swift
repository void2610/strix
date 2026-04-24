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

    private var trackingURLs: PlaybackTrackingURLs?
    private var player: AVPlayer?
    private var timer: Timer?
    /// CPN（Client Playback Nonce）— YouTube が再生セッションを識別する 16 文字のランダム文字列
    private var cpn: String = ""
    private var lastReportedTime: Double = 0
    private var hasSentPlayback = false

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    /// 新しい動画の再生トラッキングを開始する
    func start(player: AVPlayer, trackingURLs: PlaybackTrackingURLs?) {
        stop()
        self.player = player
        self.trackingURLs = trackingURLs
        self.cpn = Self.generateCPN()
        self.lastReportedTime = 0
        self.hasSentPlayback = false

        guard trackingURLs != nil else {
            strixLog("tracking: URL なし、スキップ")
            return
        }

        // 再生開始レポート
        sendPlaybackStart()

        // 30 秒ごとに watchtime を報告
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendWatchtime()
        }
    }

    /// トラッキングを停止する（動画切り替え・画面離脱時）
    func stop() {
        // 停止前に最後の watchtime を送信
        if hasSentPlayback {
            sendWatchtime()
        }
        timer?.invalidate()
        timer = nil
        player = nil
        trackingURLs = nil
        hasSentPlayback = false
    }

    // MARK: - Private

    /// 再生開始を報告する（videostatsPlaybackUrl）
    private func sendPlaybackStart() {
        guard let urls = trackingURLs,
              let player, let item = player.currentItem else { return }

        let currentTime = player.currentTime().seconds
        let duration = item.duration.isNumeric ? item.duration.seconds : 0

        var urlString = urls.videostatsPlaybackURL
        urlString = Self.appendParam(urlString, "cpn", cpn)
        urlString = Self.appendParam(urlString, "cmt", String(format: "%.3f", currentTime))
        urlString = Self.appendParam(urlString, "len", String(format: "%.0f", duration))

        sendRequest(urlString: urlString, label: "playback")
        hasSentPlayback = true
    }

    /// 視聴時間を報告する（videostatsWatchtimeUrl）
    private func sendWatchtime() {
        guard let urls = trackingURLs,
              let player, let item = player.currentItem else { return }

        let currentTime = player.currentTime().seconds
        let duration = item.duration.isNumeric ? item.duration.seconds : 0
        guard currentTime > 0 else { return }

        var urlString = urls.videostatsWatchtimeURL
        urlString = Self.appendParam(urlString, "cpn", cpn)
        urlString = Self.appendParam(urlString, "st", String(format: "%.3f", lastReportedTime))
        urlString = Self.appendParam(urlString, "et", String(format: "%.3f", currentTime))
        urlString = Self.appendParam(urlString, "cmt", String(format: "%.3f", currentTime))
        urlString = Self.appendParam(urlString, "len", String(format: "%.0f", duration))

        sendRequest(urlString: urlString, label: "watchtime")
        lastReportedTime = currentTime
    }

    /// URL にクエリパラメータを追加する
    static func appendParam(_ urlString: String, _ key: String, _ value: String) -> String {
        let separator = urlString.contains("?") ? "&" : "?"
        return "\(urlString)\(separator)\(key)=\(value)"
    }

    /// GET リクエストを送信する
    private func sendRequest(urlString: String, label: String) {
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        // Cookie 認証を付与
        if let cookies = AuthState.shared.cookieString, !cookies.isEmpty {
            let deduped = ContentClient.deduplicateCookies(cookies)
            request.setValue(deduped, forHTTPHeaderField: "Cookie")
            if let auth = ContentClient.buildSapisidHash(from: deduped) {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        }

        Task {
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    strixLog("tracking[\(label)] HTTP \(http.statusCode)")
                }
            } catch {
                strixLog("tracking[\(label)] エラー: \(error.localizedDescription)")
            }
        }
    }

    /// CPN（Client Playback Nonce）を生成する — YouTube 公式と同じ 16 文字のランダム文字列
    static func generateCPN() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        // chars は空でないため randomElement() は必ず値を返す
        return String((0..<16).compactMap { _ in chars.randomElement() })
    }
}
