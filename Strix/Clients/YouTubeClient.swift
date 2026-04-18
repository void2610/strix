//
//  YouTubeClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/07.
//

import Foundation
import WebKit

/// Innertube API を呼び出して動画ストリームを取得するクライアント。
/// IOS（認証付き）→ WEB（認証付き）の順にフォールバックする。
struct YouTubeClient {
    var fetchVideo: (String) async throws -> VideoInfo
}

struct VideoInfo {
    let streamURL: URL
    /// 音声のみストリーム URL（adaptive formats から取得、nil なら通常のみ）
    let audioOnlyURL: URL?
    let title: String
    let thumbnailURL: String
    let channelId: String?
    let channelName: String?
    let channelAvatarURL: URL?
    /// 再生トラッキング URL（YouTube に視聴履歴を記録するため）
    var playbackTrackingURLs: PlaybackTrackingURLs? = nil
}

/// YouTube の /player レスポンスに含まれる再生トラッキング URL
struct PlaybackTrackingURLs {
    /// 再生開始時に送信する URL
    let videostatsPlaybackURL: String
    /// 視聴時間を定期的に報告する URL
    let videostatsWatchtimeURL: String
}

enum YouTubeClientError: LocalizedError {
    case streamNotFound
    case notPlayable(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .streamNotFound:       return "再生可能なストリームが見つかりませんでした"
        case .notPlayable(let msg): return "再生不可: \(msg)"
        case .networkError(let e):  return "ネットワークエラー: \(e.localizedDescription)"
        }
    }
}

// MARK: - 本番クライアント

extension YouTubeClient {
    static let live = YouTubeClient(
        fetchVideo: { videoID in
            // IOS → WEB → WebPage(WKWebView) の順にフォールバック
            let strategies: [(String, () async throws -> VideoInfo)] = [
                ("IOS", { try await fetchWithIOS(videoID: videoID) }),
                ("WEB", { try await fetchWithWEB(videoID: videoID) }),
                ("WebPage", { try await fetchWithWebPage(videoID: videoID) })
            ]
            var lastError: Error = YouTubeClientError.streamNotFound

            for (name, fetch) in strategies {
                do {
                    let info = try await fetch()
                    strixLog("player[\(name)] 成功")
                    return info
                } catch {
                    strixLog("player[\(name)] 失敗: \(error.localizedDescription)")
                    lastError = error
                }
            }
            throw lastError
        }
    )

    // MARK: - IOS クライアント（HLS manifest を返す）

    private static func fetchWithIOS(videoID: String) async throws -> VideoInfo {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "com.google.ios.youtube/21.13.6 (iPhone16,2; U; CPU iOS 18_4 like Mac OS X;)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("5", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("21.13.6", forHTTPHeaderField: "X-Youtube-Client-Version")

        // Cookie + SAPISIDHASH 認証
        if let cookies = AuthState.shared.cookieString, !cookies.isEmpty {
            let deduped = ContentClient.deduplicateCookies(cookies)
            request.setValue(deduped, forHTTPHeaderField: "Cookie")
            if let auth = ContentClient.buildSapisidHash(from: deduped) {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }

        let body: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "21.13.6",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iPhone",
                    "osVersion": "18.4.0",
                    "hl": "ja",
                    "gl": "JP"
                ]
            ],
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await sendPlayerRequest(request)
        let meta = extractVideoMeta(from: json, videoID: videoID)

        // HLS manifest URL
        let streamingData = json["streamingData"] as? [String: Any]
        guard let hlsString = streamingData?["hlsManifestUrl"] as? String,
              let streamURL = URL(string: hlsString) else {
            throw YouTubeClientError.streamNotFound
        }

        return VideoInfo(streamURL: streamURL, audioOnlyURL: meta.audioOnlyURL, title: meta.title, thumbnailURL: meta.thumbnailURL,
                         channelId: meta.channelId, channelName: meta.channelName, channelAvatarURL: meta.channelAvatarURL,
                         playbackTrackingURLs: meta.trackingURLs)
    }

    // MARK: - WEB クライアント（Cookie 認証、combined formats を返す）

    private static func fetchWithWEB(videoID: String) async throws -> VideoInfo {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("2.20250415.01.00", forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")

        // Cookie + SAPISIDHASH 認証
        ContentClient.applyAuth(to: &request)

        let body: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20250415.01.00",
                    "hl": "ja",
                    "gl": "JP"
                ]
            ],
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await sendPlayerRequest(request)
        let meta = extractVideoMeta(from: json, videoID: videoID)

        // ストリーム URL: HLS → combined formats → adaptive formats
        let streamingData = json["streamingData"] as? [String: Any]

        // HLS（稀に WEB でも返る場合がある）
        if let hlsString = streamingData?["hlsManifestUrl"] as? String,
           let streamURL = URL(string: hlsString) {
            return VideoInfo(streamURL: streamURL, audioOnlyURL: meta.audioOnlyURL, title: meta.title, thumbnailURL: meta.thumbnailURL,
                             channelId: meta.channelId, channelName: meta.channelName, channelAvatarURL: meta.channelAvatarURL,
                             playbackTrackingURLs: meta.trackingURLs)
        }

        // combined formats（audio+video 一体型、最も再生しやすい）
        if let formats = streamingData?["formats"] as? [[String: Any]] {
            if let best = formats.last, let urlStr = best["url"] as? String, let streamURL = URL(string: urlStr) {
                return VideoInfo(streamURL: streamURL, audioOnlyURL: meta.audioOnlyURL, title: meta.title, thumbnailURL: meta.thumbnailURL,
                                 channelId: meta.channelId, channelName: meta.channelName, channelAvatarURL: meta.channelAvatarURL,
                                 playbackTrackingURLs: meta.trackingURLs)
            }
        }

        throw YouTubeClientError.streamNotFound
    }

    // MARK: - WebPage 方式（WKWebView でページを読み込んでストリーム URL を取得）

    @MainActor
    private static func fetchWithWebPage(videoID: String) async throws -> VideoInfo {
        strixLog("player[WebPage] 開始: \(videoID)")
        let pageURL = URL(string: "https://m.youtube.com/watch?v=\(videoID)")!

        let config = WKWebViewConfiguration()
        config.websiteDataStore = AuthState.shared.dataStore ?? .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // googlevideo.com への fetch/XHR をインターセプトするスクリプト
        let interceptScript = WKUserScript(source: """
        (function() {
            window.__strix_streams = [];
            var origFetch = window.fetch;
            window.fetch = function() {
                var url = arguments[0];
                if (typeof url === 'string' && url.includes('googlevideo.com/videoplayback')) {
                    window.__strix_streams.push(url);
                } else if (url && url.url && url.url.includes('googlevideo.com/videoplayback')) {
                    window.__strix_streams.push(url.url);
                }
                return origFetch.apply(this, arguments);
            };
            var origXHR = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function() {
                if (arguments[1] && typeof arguments[1] === 'string' && arguments[1].includes('googlevideo.com/videoplayback')) {
                    window.__strix_streams.push(arguments[1]);
                }
                return origXHR.apply(this, arguments);
            };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(interceptScript)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1"

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = WebPagePlayerDelegate(videoID: videoID, continuation: continuation)
            webView.navigationDelegate = delegate
            objc_setAssociatedObject(webView, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.load(URLRequest(url: pageURL))
        }
    }

    // MARK: - 共通ヘルパー

    /// /player リクエストを送信し、レスポンス JSON を返す。再生不可ならエラーを投げる。
    private static func sendPlayerRequest(_ request: URLRequest) async throws -> [String: Any] {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: sessionConfig)

        let data: Data
        let response: URLResponse
        do {
            let (d, r) = try await session.data(for: request)
            data = d
            response = r
        } catch {
            strixLog("player HTTP エラー: \(error.localizedDescription)")
            throw YouTubeClientError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            strixLog("player HTTP \(http.statusCode) size=\(data.count)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let rawStr = String(data: data.prefix(1000), encoding: .utf8) ?? "nil"
            strixLog("player JSON パース失敗 raw=\(rawStr)")
            throw YouTubeClientError.streamNotFound
        }
        // エラー時はレスポンスの一部をログに出す
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let rawStr = String(data: data.prefix(500), encoding: .utf8) ?? "nil"
            strixLog("player エラーレスポンス: \(rawStr)")
        }

        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? ""
        let reason = playability?["reason"] as? String
        strixLog("player playability status=\(status) reason=\(reason ?? "none")")

        // ストリーミングデータの有無をログ
        let sd = json["streamingData"] as? [String: Any]
        let hasHLS = sd?["hlsManifestUrl"] != nil
        let hasFormats = (sd?["formats"] as? [[String: Any]])?.isEmpty == false
        let hasAdaptive = (sd?["adaptiveFormats"] as? [[String: Any]])?.isEmpty == false
        strixLog("player streamingData: hls=\(hasHLS) formats=\(hasFormats) adaptive=\(hasAdaptive)")

        if status != "OK" {
            // ステータスが OK でなくても streamingData があればそれを使う
            if sd != nil, (hasHLS || hasFormats || hasAdaptive) {
                strixLog("player status=\(status) だが streamingData あり、続行")
            } else {
                throw YouTubeClientError.notPlayable(reason ?? status)
            }
        }

        return json
    }

    /// レスポンスからタイトル・サムネイル・チャンネル情報・音声 URL・トラッキング URL を抽出する
    private static func extractVideoMeta(from json: [String: Any], videoID: String)
        -> (title: String, thumbnailURL: String, channelId: String?, channelName: String?, channelAvatarURL: URL?, audioOnlyURL: URL?, trackingURLs: PlaybackTrackingURLs?) {
        let videoDetails = json["videoDetails"] as? [String: Any]
        let title = videoDetails?["title"] as? String ?? videoID
        let thumbnails = (videoDetails?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnails?.last?["url"] as? String ?? ""
        let channelId = videoDetails?["channelId"] as? String
        let channelName = videoDetails?["author"] as? String

        // チャンネルアバター
        var channelAvatarURL: URL? = nil
        if let endscreen = (json["endscreen"] as? [String: Any])?["endscreenRenderer"] as? [String: Any],
           let elements = endscreen["elements"] as? [[String: Any]] {
            for element in elements {
                if let renderer = element["endscreenElementRenderer"] as? [String: Any],
                   renderer["style"] as? String == "CHANNEL",
                   let thumbs = (renderer["image"] as? [String: Any])?["thumbnails"] as? [[String: Any]] {
                    channelAvatarURL = ContentClient.imageURL(from: thumbs.last?["url"] as? String)
                    break
                }
            }
        }
        if channelAvatarURL == nil {
            channelAvatarURL = ContentClient.findAvatarURL(in: json)
        }

        // 音声のみ URL: adaptiveFormats から最高品質の audio を取得
        var audioOnlyURL: URL? = nil
        if let adaptiveFormats = (json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] {
            let audioFormats = adaptiveFormats.filter { ($0["mimeType"] as? String)?.hasPrefix("audio/") == true }
            // ビットレートが最も高いものを選択
            let best = audioFormats.max(by: { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) })
            if let urlStr = best?["url"] as? String {
                audioOnlyURL = URL(string: urlStr)
            }
        }

        // 再生トラッキング URL を抽出
        var trackingURLs: PlaybackTrackingURLs? = nil
        if let tracking = json["playbackTracking"] as? [String: Any],
           let playbackURL = (tracking["videostatsPlaybackUrl"] as? [String: Any])?["baseUrl"] as? String,
           let watchtimeURL = (tracking["videostatsWatchtimeUrl"] as? [String: Any])?["baseUrl"] as? String {
            trackingURLs = PlaybackTrackingURLs(
                videostatsPlaybackURL: playbackURL,
                videostatsWatchtimeURL: watchtimeURL
            )
        }

        return (title, thumbnailURL, channelId, channelName, channelAvatarURL, audioOnlyURL, trackingURLs)
    }
}

// MARK: - WKWebView ページ読み込みデリゲート

/// YouTube ページを読み込んで ytInitialPlayerResponse から動画情報を抽出するデリゲート。
private final class WebPagePlayerDelegate: NSObject, WKNavigationDelegate {
    let videoID: String
    private var continuation: CheckedContinuation<VideoInfo, Error>?
    private var hasResolved = false

    init(videoID: String, continuation: CheckedContinuation<VideoInfo, Error>) {
        self.videoID = videoID
        self.continuation = continuation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasResolved else { return }
        strixLog("player[WebPage] ページ読み込み完了")

        // 再生ボタンをクリックして動画を開始させる
        let clickJS = """
        (function() {
            // プレイヤーのクリックを試行
            var btn = document.querySelector('.ytp-large-play-button, .ytp-play-button, button[aria-label*="再生"], button[aria-label*="Play"]');
            if (btn) { btn.click(); return 'clicked button'; }
            var player = document.querySelector('#movie_player, .html5-video-player');
            if (player) { player.click(); return 'clicked player'; }
            var video = document.querySelector('video');
            if (video) { video.play(); return 'called play()'; }
            return 'no target';
        })();
        """
        webView.evaluateJavaScript(clickJS) { [weak self] result, _ in
            strixLog("player[WebPage] 再生トリガー: \(result ?? "nil")")
            // 少し待ってから video.src をポーリング
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.pollVideoSource(webView: webView, attempt: 1)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resolve(with: .failure(YouTubeClientError.networkError(error)))
    }

    /// fetch/XHR インターセプトで取得した googlevideo.com URL をポーリングで取得する。
    private func pollVideoSource(webView: WKWebView, attempt: Int) {
        guard !hasResolved else { return }
        let maxAttempts = 15

        let js = """
        (function() {
            var v = document.querySelector('video');
            if (v && v.paused) { try { v.play(); } catch(e) {} }
            var streams = window.__strix_streams || [];
            var title = '';
            var thumb = '';
            try {
                var meta = document.querySelector('meta[property="og:title"]');
                if (meta) title = meta.content;
                var thumbMeta = document.querySelector('meta[property="og:image"]');
                if (thumbMeta) thumb = thumbMeta.content;
                if (!title) title = document.title.replace(' - YouTube', '');
            } catch(e) {}
            return JSON.stringify({streams: streams, title: title, thumbnail: thumb});
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, !self.hasResolved else { return }

            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let streams = info["streams"] as? [String], !streams.isEmpty {

                let title = info["title"] as? String ?? self.videoID
                let thumbnail = info["thumbnail"] as? String ?? ""

                // video/mp4 の URL を優先、なければ最初の URL
                let videoURL = streams.first(where: { $0.contains("mime=video") }) ?? streams.first!
                strixLog("player[WebPage] ストリーム取得成功 (attempt \(attempt), \(streams.count)本)")

                if let streamURL = URL(string: videoURL) {
                    // 音声 URL も探す
                    let audioURLStr = streams.first(where: { $0.contains("mime=audio") })
                    let audioURL = audioURLStr.flatMap { URL(string: $0) }
                    self.resolve(with: .success(VideoInfo(
                        streamURL: streamURL, audioOnlyURL: audioURL,
                        title: title, thumbnailURL: thumbnail,
                        channelId: nil, channelName: nil,
                        channelAvatarURL: nil, playbackTrackingURLs: nil
                    )))
                    return
                }
            }

            let count = (try? JSONSerialization.jsonObject(
                with: (result as? String)?.data(using: .utf8) ?? Data()
            ) as? [String: Any])?["streams"] as? [String]
            strixLog("player[WebPage] poll \(attempt): streams=\(count?.count ?? 0)")

            if attempt < maxAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.pollVideoSource(webView: webView, attempt: attempt + 1)
                }
            } else {
                strixLog("player[WebPage] \(maxAttempts)回ポーリング後もストリーム取得失敗")
                self.resolve(with: .failure(YouTubeClientError.streamNotFound))
            }
        }
    }

    private func resolve(with result: Result<VideoInfo, Error>) {
        guard !hasResolved else { return }
        hasResolved = true
        switch result {
        case .success(let info): continuation?.resume(returning: info)
        case .failure(let error): continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
