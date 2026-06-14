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
    /// 主ストリーム URL（HLS = 音声込みの完結ストリーム）
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
            // IOS と WEB を並列で発行し、ABR（適応ビットレート）の効く HLS を返す IOS を優先する。
            // 直列フォールバックだと弱い電波で IOS のタイムアウト待ちがそのまま再生開始の遅延になるため、
            // WEB を先に走らせておき、IOS 失敗時は即座にその結果へ切り替える。
            let webTask = Task { try await fetchWithWEB(videoID: videoID) }
            // 成功・失敗・呼び出し側キャンセルのいずれで抜けても並列の WEB リクエストを確実に止める
            defer { webTask.cancel() }

            // IOS は HLS（音声込み・ABR）を返すため最優先。SABR 移行済み動画では HLS が無く失敗する。
            do {
                var info = try await fetchWithIOS(videoID: videoID)
                strixLog("player[IOS] 成功")
                if info.playbackTrackingURLs == nil {
                    // 並列実行中の WEB から視聴履歴トラッキング URL を補完する。
                    // 再生開始を遅らせないよう最大 2 秒で打ち切る
                    strixLog("player[IOS] tracking URL なし、WEB で補完を試みる")
                    let deadline = Task {
                        try? await Task.sleep(for: .seconds(2))
                        webTask.cancel()
                    }
                    info.playbackTrackingURLs = (try? await webTask.value)?.playbackTrackingURLs
                    deadline.cancel()
                }
                return info
            } catch {
                strixLog("player[IOS] 失敗: \(error.localizedDescription)")
                // 呼び出し側のキャンセルならフォールバックせず即終了する
                try Task.checkCancellation()
            }

            // ANDROID_VR は PO Token 不要で、SABR 移行済み動画でも再生可能な直 URL（itag18 muxed）を返す
            do {
                var info = try await fetchWithAndroidVR(videoID: videoID)
                strixLog("player[ANDROID_VR] 成功")
                if info.playbackTrackingURLs == nil {
                    let deadline = Task {
                        try? await Task.sleep(for: .seconds(2))
                        webTask.cancel()
                    }
                    info.playbackTrackingURLs = (try? await webTask.value)?.playbackTrackingURLs
                    deadline.cancel()
                }
                return info
            } catch {
                strixLog("player[ANDROID_VR] 失敗: \(error.localizedDescription)")
                try Task.checkCancellation()
            }

            do {
                let info = try await webTask.value
                strixLog("player[WEB] 成功")
                return info
            } catch {
                strixLog("player[WEB] 失敗: \(error.localizedDescription)")
            }

            do {
                let info = try await fetchWithWebPage(videoID: videoID)
                strixLog("player[WebPage] 成功")
                return info
            } catch {
                strixLog("player[WebPage] 失敗: \(error.localizedDescription)")
                throw error
            }
        }
    )

    // MARK: - IOS クライアント（HLS manifest を返す）

    private static func fetchWithIOS(videoID: String) async throws -> VideoInfo {
        var request = URLRequest(url: YouTubeConstants.playerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(YouTubeConstants.iosUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(YouTubeConstants.iosClientNameValue, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(YouTubeConstants.iosClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")

        // Cookie + SAPISIDHASH 認証（IOS クライアントは X-Origin を付けない）
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
            "context": YouTubeConstants.iosClientContext,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await sendPlayerRequest(request)
        let meta = extractVideoMeta(from: json, videoID: videoID)

        // HLS manifest URL（音声込みの完結ストリーム）。
        // SABR 移行済みで hlsManifestUrl が返らない動画は、ANDROID_VR フォールバックへ回す。
        let streamingData = json["streamingData"] as? [String: Any]
        guard let hlsString = streamingData?["hlsManifestUrl"] as? String,
              let streamURL = URL(string: hlsString) else {
            throw YouTubeClientError.streamNotFound
        }
        return VideoInfo(streamURL: streamURL, audioOnlyURL: meta.audioOnlyURL, title: meta.title, thumbnailURL: meta.thumbnailURL,
                         channelId: meta.channelId, channelName: meta.channelName, channelAvatarURL: meta.channelAvatarURL,
                         playbackTrackingURLs: meta.trackingURLs)
    }

    // MARK: - ANDROID_VR クライアント（PO Token 不要、再生可能な直 URL を返す）

    /// セッションで使い回す visitorData（android_vr は visitorData が無いと LOGIN_REQUIRED になる）
    private static var cachedVisitorData: String?

    /// visitorData を取得する。IOS クライアントのレスポンスに含まれるものを使い、セッション内でキャッシュする。
    private static func fetchVisitorData() async -> String? {
        if let cachedVisitorData { return cachedVisitorData }
        var request = URLRequest(url: YouTubeConstants.playerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(YouTubeConstants.iosUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(YouTubeConstants.iosClientNameValue, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(YouTubeConstants.iosClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        let body: [String: Any] = ["videoId": "dQw4w9WgXcQ", "context": YouTubeConstants.iosClientContext]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await InnertubeRequest.session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vd = (json["responseContext"] as? [String: Any])?["visitorData"] as? String else {
            return nil
        }
        cachedVisitorData = vd
        return vd
    }

    /// ANDROID_VR クライアントで /player を叩く。PO Token 不要で、SABR 移行済み動画でも
    /// itag18（360p muxed、音声込みの単一 progressive URL）を含む再生可能な直 URL を返す。
    private static func fetchWithAndroidVR(videoID: String) async throws -> VideoInfo {
        guard let visitorData = await fetchVisitorData() else {
            throw YouTubeClientError.streamNotFound
        }
        var request = URLRequest(url: YouTubeConstants.playerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(YouTubeConstants.androidVrUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(YouTubeConstants.androidVrClientNameValue, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(YouTubeConstants.androidVrClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")

        let body: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": YouTubeConstants.androidVrClientContext(visitorData: visitorData)
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await sendPlayerRequest(request)
        let meta = extractVideoMeta(from: json, videoID: videoID)

        // itag18（音声込み muxed）を優先。SABR と異なり通常の Range GET で再生できる。
        let streamingData = json["streamingData"] as? [String: Any]
        let formats = (streamingData?["formats"] as? [[String: Any]]) ?? []
        guard let muxed = formats.first(where: { $0["itag"] as? Int == 18 }),
              let urlStr = muxed["url"] as? String,
              let streamURL = URL(string: urlStr) else {
            throw YouTubeClientError.streamNotFound
        }
        return VideoInfo(streamURL: streamURL, audioOnlyURL: meta.audioOnlyURL, title: meta.title, thumbnailURL: meta.thumbnailURL,
                         channelId: meta.channelId, channelName: meta.channelName, channelAvatarURL: meta.channelAvatarURL,
                         playbackTrackingURLs: meta.trackingURLs)
    }

    // MARK: - WEB クライアント（Cookie 認証、combined formats を返す）

    private static func fetchWithWEB(videoID: String) async throws -> VideoInfo {
        let body: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]
        var request = try InnertubeRequest.webRequest(url: YouTubeConstants.playerURL, body: body)
        request.setValue(YouTubeConstants.webClientNameValue, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(YouTubeConstants.webClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")

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
        let pageURL = URL(string: "https://m.youtube.com/watch?v=\(videoID)")!

        let config = WKWebViewConfiguration()
        config.websiteDataStore = AuthState.shared.dataStore ?? .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // googlevideo.com への fetch/XHR をインターセプトするスクリプト（重複排除付き）
        let interceptScript = WKUserScript(source: """
        (function() {
            window.__strix_streams = [];
            window.__strix_seen = {};
            function addStream(url) {
                if (!url || typeof url !== 'string') return;
                if (!url.includes('googlevideo.com/videoplayback')) return;
                // itag で重複排除
                var m = url.match(/[&?]itag=(\\d+)/);
                var key = m ? m[1] : url.substring(0, 100);
                if (!window.__strix_seen[key]) {
                    window.__strix_seen[key] = true;
                    window.__strix_streams.push(url);
                }
            }
            var origFetch = window.fetch;
            window.fetch = function() {
                var url = arguments[0];
                if (typeof url === 'string') addStream(url);
                else if (url && url.url) addStream(url.url);
                return origFetch.apply(this, arguments);
            };
            var origXHR = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function() {
                if (arguments[1]) addStream(arguments[1]);
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
        let data: Data
        do {
            let (d, _) = try await InnertubeRequest.session.data(for: request)
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
            // ステータスが OK でなくても streamingData があればそれを使う
            let sd = json["streamingData"] as? [String: Any]
            let hasStream = sd?["hlsManifestUrl"] != nil
                || (sd?["formats"] as? [[String: Any]])?.isEmpty == false
                || (sd?["adaptiveFormats"] as? [[String: Any]])?.isEmpty == false
            if !hasStream {
                let reason = playability?["reason"] as? String ?? status
                throw YouTubeClientError.notPlayable(reason)
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

        // 音声のみ URL: adaptiveFormats から AVPlayer で再生可能な audio を取得
        var audioOnlyURL: URL? = nil
        if let adaptiveFormats = (json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] {
            audioOnlyURL = selectAudioOnlyURL(from: adaptiveFormats)
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

    /// adaptiveFormats から音声のみモードで使う URL を選ぶ。
    /// AVPlayer は opus (audio/webm) をデコードできないため AAC (audio/mp4) に限定し、
    /// その中で最高ビットレートのものを返す。
    /// url を持たない（signatureCipher のみの）フォーマットは再生できないので除外する。
    static func selectAudioOnlyURL(from adaptiveFormats: [[String: Any]]) -> URL? {
        let playableAudioFormats = adaptiveFormats.filter {
            ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true && $0["url"] is String
        }
        let best = playableAudioFormats.max(by: { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) })
        guard let urlStr = best?["url"] as? String else { return nil }
        return URL(string: urlStr)
    }

    /// googlevideo のストリーム URL 一覧から音声のみモードで使う URL を選ぶ（WebPage フォールバック用）。
    /// selectAudioOnlyURL と同じ基準で、AVPlayer がデコードできない opus (audio/webm) は選ばず
    /// AAC (audio/mp4) に限定する。mime パラメータは URL エンコードされている場合がある。
    static func selectMp4AudioURL(fromStreamURLs streams: [String]) -> URL? {
        let urlStr = streams.first {
            $0.contains("mime=audio%2Fmp4") || $0.contains("mime=audio/mp4")
        }
        return urlStr.flatMap { URL(string: $0) }
    }
}

// MARK: - WKWebView ページ読み込みデリゲート

/// YouTube モバイルページを読み込み、fetch/XHR インターセプトでストリーム URL を取得するデリゲート。
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

        // 再生ボタンをクリックして動画を開始させる（fetch/XHR インターセプトを発火）
        let clickJS = """
        (function() {
            var btn = document.querySelector('.ytp-large-play-button, .ytp-play-button, button[aria-label*="再生"], button[aria-label*="Play"]');
            if (btn) { btn.click(); return; }
            var player = document.querySelector('#movie_player, .html5-video-player');
            if (player) { player.click(); return; }
            var video = document.querySelector('video');
            if (video) { video.play(); }
        })();
        """
        webView.evaluateJavaScript(clickJS) { [weak self] _, _ in
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

                // itag を URL から抽出するヘルパー
                func itag(of url: String) -> String? {
                    URLComponents(string: url)?.queryItems?.first(where: { $0.name == "itag" })?.value
                }

                // combined format（映像+音声一体）を優先: itag=18(360p), 22(720p)
                let combinedItags = ["22", "18"]
                var selectedURL: String?
                for tag in combinedItags {
                    if let url = streams.first(where: { itag(of: $0) == tag }) {
                        selectedURL = url
                        break
                    }
                }

                if let urlStr = selectedURL, let streamURL = URL(string: urlStr) {
                    let audioURL = YouTubeClient.selectMp4AudioURL(fromStreamURLs: streams)
                    self.resolve(with: .success(VideoInfo(
                        streamURL: streamURL, audioOnlyURL: audioURL,
                        title: title, thumbnailURL: thumbnail,
                        channelId: nil, channelName: nil,
                        channelAvatarURL: nil, playbackTrackingURLs: nil
                    )))
                    return
                }

                // combined がない場合は最後の数回で adaptive にフォールバック
                if attempt >= maxAttempts - 2, let firstURL = streams.first, let streamURL = URL(string: firstURL) {
                    let audioURL = YouTubeClient.selectMp4AudioURL(fromStreamURLs: streams)
                    self.resolve(with: .success(VideoInfo(
                        streamURL: streamURL, audioOnlyURL: audioURL,
                        title: title, thumbnailURL: thumbnail,
                        channelId: nil, channelName: nil,
                        channelAvatarURL: nil, playbackTrackingURLs: nil
                    )))
                    return
                }
                // combined が見つかるまでもう少し待つ
            }

            if attempt < maxAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.pollVideoSource(webView: webView, attempt: attempt + 1)
                }
            } else {
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
