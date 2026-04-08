//
//  ContentClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import WebKit
import YouTubeKit

/// ホームフィード・検索・関連動画を取得するクライアント。
/// 戻り値は VideoItem に統一している。
struct ContentClient {
    var fetchHome: () async throws -> [VideoItem]
    var search: (String) async throws -> [VideoItem]
    var fetchRelated: (String) async throws -> [VideoItem]
}

// MARK: - モック（テスト用）

extension ContentClient {
    static func mock(
        fetchHome: @escaping () async throws -> [VideoItem] = { [] },
        search: @escaping (String) async throws -> [VideoItem] = { _ in [] },
        fetchRelated: @escaping (String) async throws -> [VideoItem] = { _ in [] }
    ) -> ContentClient {
        ContentClient(fetchHome: fetchHome, search: search, fetchRelated: fetchRelated)
    }
}

// MARK: - 本番クライアント

extension ContentClient {
    static let live: ContentClient = {
        let model = YouTubeModel()
        return ContentClient(
            fetchHome: {
                let cookies = AuthState.shared.cookieString
                let isSignedIn = cookies != nil && !cookies!.isEmpty

                if isSignedIn, let c = cookies {
                    // ログイン済み: SAPISIDHASH 付き Innertube /browse でパーソナライズドフィード取得
                    do {
                        let items = try await ContentClient.browseHome(cookies: c)
                        strixLog(" browseHome: \(items.count) 件取得")
                        if !items.isEmpty { return items }
                        strixLog(" browseHome: 空のため YouTubeKit にフォールバック")
                    } catch {
                        strixLog(" browseHome エラー: \(error)")
                    }

                    // ログイン済み YouTubeKit フォールバック
                    model.cookies = c
                    let (response, _) = await HomeScreenResponse.sendRequest(
                        youtubeModel: model, data: [:]
                    )
                    let ytVideos = (response?.results ?? [])
                        .compactMap { $0 as? YTVideo }
                        .map { $0.toVideoItem }
                    strixLog(" YouTubeKit HomeScreen: \(ytVideos.count) 件取得")
                    if !ytVideos.isEmpty { return ytVideos }

                    // ログイン済みで全部失敗 → trending で偽装しない（空を返す）
                    strixLog(" ログイン済みフィード取得失敗: 空を返す")
                    return []
                }

                // 未ログイン: YouTubeKit → trending フォールバック
                model.cookies = ""
                let (response, _) = await HomeScreenResponse.sendRequest(
                    youtubeModel: model, data: [:]
                )
                let homeVideos = (response?.results ?? [])
                    .compactMap { $0 as? YTVideo }
                    .map { $0.toVideoItem }
                if !homeVideos.isEmpty { return homeVideos }

                // 未ログイン最終フォールバック: トレンド検索
                let (searchResponse, searchError) = await SearchResponse.sendRequest(
                    youtubeModel: model,
                    data: [.query: "trending music 2025"]
                )
                if let searchError { throw searchError }
                return (searchResponse?.results ?? [])
                    .compactMap { $0 as? YTVideo }
                    .map { $0.toVideoItem }
            },
            search: { query in
                model.cookies = AuthState.shared.cookieString ?? ""
                let (response, error) = await SearchResponse.sendRequest(
                    youtubeModel: model,
                    data: [.query: query]
                )
                if let error { throw error }
                return (response?.results ?? [])
                    .compactMap { $0 as? YTVideo }
                    .map { $0.toVideoItem }
            },
            fetchRelated: { videoID in
                model.cookies = AuthState.shared.cookieString ?? ""
                let (response, error) = await MoreVideoInfosResponse.sendRequest(
                    youtubeModel: model,
                    data: [.query: videoID]
                )
                if let error { throw error }
                return (response?.recommendedVideos ?? [])
                    .compactMap { $0 as? YTVideo }
                    .map { $0.toVideoItem }
            }
        )
    }()
}

// MARK: - WKWebView ベースのホームフィード取得

extension ContentClient {

    /// WKWebView を使って YouTube ホームフィードを取得する。
    /// ログイン時の WKWebsiteDataStore を再利用するため Cookie 認証が確実に機能する。
    /// アプリ再起動後（dataStore が nil）はクッキーを新しい dataStore に注入してフォールバックする。
    private static func browseHome(cookies: String) async throws -> [VideoItem] {
        let cookieKeys = cookies.components(separatedBy: "; ")
            .compactMap { $0.components(separatedBy: "=").first }
        strixLog(" クッキーキー(\(cookieKeys.count)): \(cookieKeys.joined(separator: ", "))")

        // ログイン時の dataStore を優先使用（同一セッション）、なければ Cookie 注入版を作成
        let dataStore: WKWebsiteDataStore
        if let saved = await MainActor.run(body: { AuthState.shared.dataStore }) {
            strixLog(" browseHome: 保存済み dataStore を使用")
            dataStore = saved
        } else {
            strixLog(" browseHome: dataStore なし → Cookie 注入版を作成")
            dataStore = await Self.makeDataStore(from: cookies)
        }

        guard let json = await YouTubeWebLoader.load(dataStore: dataStore) else {
            strixLog(" browseHome: ytInitialData 取得失敗")
            return []
        }

        let vrCount = countKeys("videoRenderer", in: json)
        strixLog(" browseHome: videoRenderer \(vrCount) 件")
        let videos = findVideoRenderers(in: json)
        let parsed = videos.compactMap { parseVideoRenderer($0) }
        strixLog(" browseHome: パース成功 \(parsed.count) 件 / 抽出 \(videos.count) 件")
        return parsed
    }

    /// クッキー文字列から WKWebsiteDataStore を作成してクッキーを注入する（アプリ再起動時フォールバック用）
    @MainActor
    private static func makeDataStore(from cookieString: String) async -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        let pairs = cookieString.components(separatedBy: "; ")

        for pair in pairs {
            let eqIdx = pair.firstIndex(of: "=") ?? pair.endIndex
            let name  = String(pair[pair.startIndex..<eqIdx])
            let value = eqIdx < pair.endIndex
                ? String(pair[pair.index(after: eqIdx)...])
                : ""
            guard !name.isEmpty else { continue }

            // __Host- プレフィックスはドメインなし・secure 必須
            let isHostPrefixed = name.hasPrefix("__Host-")
            let isSecure       = isHostPrefixed || name.hasPrefix("__Secure-")
            let domain         = isHostPrefixed ? "youtube.com" : ".youtube.com"

            var props: [HTTPCookiePropertyKey: Any] = [
                .name:   name,
                .value:  value,
                .domain: domain,
                .path:   "/",
            ]
            if isSecure { props[.secure] = "TRUE" }

            if let cookie = HTTPCookie(properties: props) {
                await store.httpCookieStore.setCookie(cookie)
            }
        }
        return store
    }

    /// JSON ツリーを再帰的に探索して特定キーの出現回数を返す（件数診断用）
    private static func countKeys(_ key: String, in json: Any) -> Int {
        if let dict = json as? [String: Any] {
            let found = dict[key] != nil ? 1 : 0
            return found + dict.values.reduce(0) { $0 + countKeys(key, in: $1) }
        } else if let array = json as? [Any] {
            return array.reduce(0) { $0 + countKeys(key, in: $1) }
        }
        return 0
    }

    /// JSON ツリーを再帰的に探索して動画 Renderer を全て抽出する。
    /// WEB → videoRenderer / IOS 旧形式 → compactVideoRenderer
    /// IOS 新形式 → elementRenderer 内の videoWithContextModel
    private static func findVideoRenderers(in json: Any) -> [[String: Any]] {
        if let dict = json as? [String: Any] {
            if let vr = dict["videoRenderer"] as? [String: Any] {
                return [vr]
            }
            if let vr = dict["compactVideoRenderer"] as? [String: Any] {
                return [vr]
            }
            // IOS 新形式: elementRenderer.newElement.type.componentType.model.videoWithContextModel
            if let el = dict["elementRenderer"] as? [String: Any],
               let item = extractVideoWithContextModel(from: el) {
                return [item]
            }
            return dict.values.flatMap { findVideoRenderers(in: $0) }
        } else if let array = json as? [Any] {
            return array.flatMap { findVideoRenderers(in: $0) }
        }
        return []
    }

    /// elementRenderer から videoWithContextModel を取り出す。
    /// パス: newElement.type.componentType.model.videoWithContextModel
    private static func extractVideoWithContextModel(from el: [String: Any]) -> [String: Any]? {
        guard
            let newElement   = el["newElement"]  as? [String: Any],
            let type_        = newElement["type"] as? [String: Any],
            let component    = type_["componentType"] as? [String: Any],
            let model        = component["model"]     as? [String: Any],
            let vcm          = model["videoWithContextModel"] as? [String: Any]
        else { return nil }
        return vcm
    }

    /// videoRenderer / compactVideoRenderer / videoWithContextModel 一件から VideoItem を生成する。
    /// videoWithContextModel は videoWithContextData キーを持つ新 IOS 形式。
    private static func parseVideoRenderer(_ vr: [String: Any]) -> VideoItem? {
        // ── 新 IOS 形式: videoWithContextModel ─────────────────────────────
        if let vcData = vr["videoWithContextData"] as? [String: Any] {
            return parseVideoWithContextData(vcData)
        }

        // ── 旧形式: videoRenderer / compactVideoRenderer ───────────────────
        guard let videoId = vr["videoId"] as? String else { return nil }

        // タイトル: videoRenderer → title.runs[0].text
        //           compactVideoRenderer → title.simpleText
        let titleObj = vr["title"] as? [String: Any]
        let title = (titleObj?["simpleText"] as? String)
            ?? ((titleObj?["runs"] as? [[String: Any]])?.first?["text"] as? String)
            ?? videoId

        // サムネイル
        let thumbs = (vr["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = (thumbs?.last?["url"] as? String).flatMap { URL(string: $0) }

        // チャンネル名: videoRenderer → ownerText / compactVideoRenderer → longBylineText
        let channelName =
            ((vr["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]])?
                .first?["text"] as? String
            ?? ((vr["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?
                .first?["text"] as? String
            ?? ((vr["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?
                .first?["text"] as? String

        // チャンネルアバター
        let chThumb = vr["channelThumbnailSupportedRenderers"] as? [String: Any]
        let chThumbLink = chThumb?["channelThumbnailWithLinkRenderer"] as? [String: Any]
        let chThumbObj = chThumbLink?["thumbnail"] as? [String: Any]
        let chThumbs = chThumbObj?["thumbnails"] as? [[String: Any]]
        let avatarURL = (chThumbs?.last?["url"] as? String).flatMap { URL(string: $0) }

        // 視聴回数・投稿日時
        let viewCount = (vr["shortViewCountText"] as? [String: Any])?["simpleText"] as? String
        let timePosted = (vr["publishedTimeText"] as? [String: Any])?["simpleText"] as? String

        return VideoItem(
            videoId: videoId,
            title: title,
            channelName: channelName,
            thumbnailURL: thumbURL,
            channelAvatarURL: avatarURL,
            viewCountText: viewCount,
            timePostedText: timePosted
        )
    }

    /// IOS 新形式の videoWithContextData オブジェクトから VideoItem を生成する。
    ///
    /// 想定パス:
    ///   videoId   : onTap.innertubeCommand.watchEndpoint.videoId
    ///   title     : videoData.metadata.title
    ///   channel   : videoData.metadata.byline (または channelThumbnail)
    ///   thumbnail : videoData.thumbnail.image.sources[last].url
    private static func parseVideoWithContextData(_ data: [String: Any]) -> VideoItem? {
        // videoId
        let onTap       = data["onTap"]             as? [String: Any]
        let itCmd       = onTap?["innertubeCommand"] as? [String: Any]
        let watchEP     = itCmd?["watchEndpoint"]   as? [String: Any]
        guard let videoId = watchEP?["videoId"] as? String else { return nil }

        // metadata
        let videoData   = data["videoData"]         as? [String: Any]
        let metadata    = videoData?["metadata"]    as? [String: Any]

        // タイトル
        let title = (metadata?["title"] as? String) ?? videoId

        // チャンネル名: byline または channelName
        let channelName = (metadata?["byline"] as? String)
            ?? (metadata?["channelName"] as? String)

        // サムネイル: videoData.thumbnail.image.sources[last].url
        let thumbImage  = (videoData?["thumbnail"] as? [String: Any])?["image"] as? [String: Any]
        let thumbSrcs   = thumbImage?["sources"] as? [[String: Any]]
        let thumbURL    = (thumbSrcs?.last?["url"] as? String).flatMap { URL(string: $0) }

        // チャンネルアバター: channelThumbnail.image.sources[last].url
        let chThumbImg  = (data["channelThumbnail"] as? [String: Any])?["image"] as? [String: Any]
        let chThumbSrcs = chThumbImg?["sources"] as? [[String: Any]]
        let avatarURL   = (chThumbSrcs?.last?["url"] as? String).flatMap { URL(string: $0) }

        // 視聴回数・投稿日時
        let viewCount   = metadata?["shortViewCountText"] as? String
        let timePosted  = metadata?["publishedTimeText"]  as? String

        return VideoItem(
            videoId: videoId,
            title: title,
            channelName: channelName,
            thumbnailURL: thumbURL,
            channelAvatarURL: avatarURL,
            viewCountText: viewCount,
            timePostedText: timePosted
        )
    }
}

// MARK: - WKWebView による YouTube ホームページローダー

/// WKWebView で YouTube ホームページを読み込み、window.ytInitialData を JavaScript で取得する。
/// URLSession では Cookie 認証が機能しないため WKWebView の完全なブラウザセッションを使用する。
@MainActor
final class YouTubeWebLoader: NSObject, WKNavigationDelegate {
    /// 並列ロードを防ぐためのシングルトン参照（完了後に nil に戻す）
    private static var current: YouTubeWebLoader?

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[String: Any]?, Never>?

    static func load(dataStore: WKWebsiteDataStore) async -> [String: Any]? {
        let loader = YouTubeWebLoader()
        Self.current = loader
        defer { Self.current = nil }
        return await loader.fetch(dataStore: dataStore)
    }

    private func fetch(dataStore: WKWebsiteDataStore) async -> [String: Any]? {
        return await withCheckedContinuation { cont in
            self.continuation = cont

            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = dataStore
            // JavaScript を有効化（ytInitialData 取得に必要）
            cfg.preferences.javaScriptEnabled = true

            let wv = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                configuration: cfg
            )
            wv.navigationDelegate = self
            self.webView = wv

            strixLog(" YouTubeWebLoader: ロード開始")
            wv.load(URLRequest(url: URL(string: "https://www.youtube.com/?hl=ja&gl=JP")!))

            // 30秒タイムアウト
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.continuation != nil else { return }
                strixLog(" YouTubeWebLoader: タイムアウト")
                self.continuation?.resume(returning: nil)
                self.continuation = nil
                self.webView = nil
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        strixLog(" YouTubeWebLoader: ページロード完了 URL=\(webView.url?.host ?? "不明")")
        // JavaScript で ytInitialData を取得する
        webView.evaluateJavaScript("JSON.stringify(window.ytInitialData || null)") { [weak self] result, error in
            guard let self else { return }
            var json: [String: Any]?
            if let s = result as? String,
               let d = s.data(using: .utf8) {
                json = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            }
            if let e = error {
                strixLog(" YouTubeWebLoader: JS エラー: \(e)")
            }
            strixLog(" YouTubeWebLoader: ytInitialData \(json != nil ? "取得成功" : "nil")")
            self.continuation?.resume(returning: json)
            self.continuation = nil
            self.webView = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        strixLog(" YouTubeWebLoader: ナビゲーション失敗: \(error)")
        continuation?.resume(returning: nil)
        continuation = nil
        self.webView = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        strixLog(" YouTubeWebLoader: プロビジョナルナビゲーション失敗: \(error)")
        continuation?.resume(returning: nil)
        continuation = nil
        self.webView = nil
    }
}
