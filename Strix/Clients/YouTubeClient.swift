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
    let title: String
    let thumbnailURL: String
    let channelId: String?
    let channelName: String?
    let channelAvatarURL: URL?
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
            "com.google.ios.youtube/21.13.6 (iPhone16,2; U; CPU iOS 18_1 like Mac OS X;)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("5", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("21.13.6", forHTTPHeaderField: "X-Youtube-Client-Version")

        // IOS クライアントは Cookie のみ（SAPISIDHASH を送ると WEB 偽装と判定される）
        if let cookies = AuthState.shared.cookieString, !cookies.isEmpty {
            request.setValue(ContentClient.deduplicateCookies(cookies), forHTTPHeaderField: "Cookie")
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
                    "osVersion": "18.1.23B74",
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

        return VideoInfo(streamURL: streamURL, title: meta.title, thumbnailURL: meta.thumbnailURL,
                         channelId: meta.channelId, channelName: meta.channelName, channelAvatarURL: meta.channelAvatarURL)
    }

    // MARK: - WEB クライアント（adaptive/combined formats を返す）

    private static func fetchWithWEB(videoID: String) async throws -> VideoInfo {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("2.20241201.01.00", forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")

        // 認証ヘッダー（WEB は Cookie + SAPISIDHASH が必須）
        applyAuth(to: &request)

        let body: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20241201.01.00",
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
            return VideoInfo(streamURL: streamURL, title: meta.title, thumbnailURL: meta.thumbnailURL,
                             channelId: meta.channelId, channelName: meta.channelName, channelAvatarURL: meta.channelAvatarURL)
        }

        // combined formats（audio+video 一体型、最も再生しやすい）
        if let formats = streamingData?["formats"] as? [[String: Any]] {
            // 最高画質を選択
            if let best = formats.last, let urlStr = best["url"] as? String, let streamURL = URL(string: urlStr) {
                return VideoInfo(streamURL: streamURL, title: meta.title, thumbnailURL: meta.thumbnailURL,
                                 channelId: meta.channelId, channelName: meta.channelName, channelAvatarURL: meta.channelAvatarURL)
            }
        }

        throw YouTubeClientError.streamNotFound
    }

    // MARK: - WebPage 方式（WKWebView でページを読み込んでストリーム URL を取得）

    @MainActor
    private static func fetchWithWebPage(videoID: String) async throws -> VideoInfo {
        strixLog("player[WebPage] 開始: \(videoID)")
        let pageURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!

        // ログイン済みの DataStore を使って認証済み WKWebView を作成
        let config = WKWebViewConfiguration()
        if let dataStore = AuthState.shared.dataStore {
            config.websiteDataStore = dataStore
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)

        // ページ読み込み
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = WebPagePlayerDelegate(videoID: videoID, continuation: continuation)
            webView.navigationDelegate = delegate
            // delegate の参照を保持
            objc_setAssociatedObject(webView, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.load(URLRequest(url: pageURL))
        }
    }

    // MARK: - 共通ヘルパー

    /// 認証ヘッダーをリクエストに付与する
    private static func applyAuth(to request: inout URLRequest) {
        guard let cookies = AuthState.shared.cookieString, !cookies.isEmpty else { return }
        let deduped = ContentClient.deduplicateCookies(cookies)
        request.setValue(deduped, forHTTPHeaderField: "Cookie")
        if let auth = ContentClient.buildSapisidHash(from: deduped) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
    }

    /// /player リクエストを送信し、レスポンス JSON を返す。再生不可ならエラーを投げる。
    private static func sendPlayerRequest(_ request: URLRequest) async throws -> [String: Any] {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: sessionConfig)

        let data: Data
        do {
            let (d, _) = try await session.data(for: request)
            data = d
        } catch {
            throw YouTubeClientError.networkError(error)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeClientError.streamNotFound
        }

        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? ""
        if status != "OK" {
            let reason = playability?["reason"] as? String ?? status
            throw YouTubeClientError.notPlayable(reason)
        }

        return json
    }

    /// レスポンスからタイトル・サムネイル・チャンネル情報を抽出する
    private static func extractVideoMeta(from json: [String: Any], videoID: String)
        -> (title: String, thumbnailURL: String, channelId: String?, channelName: String?, channelAvatarURL: URL?) {
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

        return (title, thumbnailURL, channelId, channelName, channelAvatarURL)
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

        // JavaScript でページから ytInitialPlayerResponse を抽出
        let js = """
        (function() {
            try {
                if (typeof ytInitialPlayerResponse !== 'undefined') {
                    return JSON.stringify(ytInitialPlayerResponse);
                }
                var scripts = document.querySelectorAll('script');
                for (var i = 0; i < scripts.length; i++) {
                    var text = scripts[i].textContent;
                    var match = text.match(/var ytInitialPlayerResponse\\s*=\\s*(\\{.+?\\});/);
                    if (match) return match[1];
                    match = text.match(/ytInitialPlayerResponse\\s*=\\s*(\\{.+?\\});/);
                    if (match) return match[1];
                }
                return null;
            } catch(e) { return null; }
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self, !self.hasResolved else { return }

            guard let jsonString = result as? String,
                  let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                // ページ読み込み完了時にまだ取得できない場合は少し待って再試行
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.retryExtraction(webView: webView)
                }
                return
            }

            self.resolveWithJSON(json)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resolve(with: .failure(YouTubeClientError.networkError(error)))
    }

    private func retryExtraction(webView: WKWebView) {
        guard !hasResolved else { return }

        let js = """
        (function() {
            try {
                if (typeof ytInitialPlayerResponse !== 'undefined') {
                    return JSON.stringify(ytInitialPlayerResponse);
                }
                return null;
            } catch(e) { return null; }
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, !self.hasResolved else { return }
            guard let jsonString = result as? String,
                  let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                self.resolve(with: .failure(YouTubeClientError.streamNotFound))
                return
            }
            self.resolveWithJSON(json)
        }
    }

    private func resolveWithJSON(_ json: [String: Any]) {
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? ""
        if status != "OK" {
            let reason = playability?["reason"] as? String ?? status
            resolve(with: .failure(YouTubeClientError.notPlayable(reason)))
            return
        }

        let videoDetails = json["videoDetails"] as? [String: Any]
        let title = videoDetails?["title"] as? String ?? videoID
        let thumbnails = (videoDetails?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnails?.last?["url"] as? String ?? ""
        let channelId = videoDetails?["channelId"] as? String
        let channelName = videoDetails?["author"] as? String

        let streamingData = json["streamingData"] as? [String: Any]

        // HLS
        if let hlsString = streamingData?["hlsManifestUrl"] as? String,
           let streamURL = URL(string: hlsString) {
            resolve(with: .success(VideoInfo(streamURL: streamURL, title: title, thumbnailURL: thumbnailURL, channelId: channelId, channelName: channelName, channelAvatarURL: nil)))
            return
        }

        // combined formats
        if let formats = streamingData?["formats"] as? [[String: Any]],
           let best = formats.last, let urlStr = best["url"] as? String, let streamURL = URL(string: urlStr) {
            resolve(with: .success(VideoInfo(streamURL: streamURL, title: title, thumbnailURL: thumbnailURL, channelId: channelId, channelName: channelName, channelAvatarURL: nil)))
            return
        }

        resolve(with: .failure(YouTubeClientError.streamNotFound))
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
