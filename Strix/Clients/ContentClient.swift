//
//  ContentClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import CryptoKit
import YouTubeKit

/// チャンネルタブの種類
enum ChannelTab: String, CaseIterable {
    case home = "ホーム"
    case videos = "動画"
    case live = "ライブ"
    case playlists = "再生リスト"
}

/// チャンネル情報モデル
struct ChannelInfo {
    let channelId: String
    let name: String?
    let handle: String?
    let subscriberCount: String?
    let videoCount: String?
    let avatarURL: URL?
    let bannerURL: URL?
}

/// チャンネルプレイリスト項目
struct ChannelPlaylistItem: Identifiable {
    var id: String { playlistId }
    let playlistId: String
    let title: String
    let thumbnailURL: URL?
    let videoCount: String?
}

/// ホームフィード・検索・関連動画を取得するクライアント。
/// 戻り値は VideoItem に統一している。
struct ContentClient {
    var fetchHome: () async throws -> ([VideoItem], String?)
    var fetchHomePage: (String) async throws -> ([VideoItem], String?)
    var fetchHistoryVideos: () async throws -> [VideoItem]
    var fetchPlaylistVideos: (String) async throws -> [VideoItem]
    var search: (String) async throws -> [VideoItem]
    /// 関連動画・動画オーナーアバター・説明欄データを返す
    var fetchRelated: (String) async throws -> (videos: [VideoItem], ownerAvatarURL: URL?, description: String?, viewCount: String?, publishDate: String?)
    var fetchChannel: (String) async throws -> ChannelInfo
    /// チャンネルタブの動画を取得（初回）
    var fetchChannelTab: (_ channelId: String, _ tab: ChannelTab) async throws -> ([VideoItem], String?)
    /// チャンネルタブのページネーション
    var fetchChannelTabPage: (_ continuation: String) async throws -> ([VideoItem], String?)
    /// チャンネルの再生リスト一覧を取得
    var fetchChannelPlaylists: (_ channelId: String) async throws -> [ChannelPlaylistItem]
}

// MARK: - モック（テスト用）

extension ContentClient {
    static func mock(
        fetchHome: @escaping () async throws -> ([VideoItem], String?) = { ([], nil) },
        fetchHomePage: @escaping (String) async throws -> ([VideoItem], String?) = { _ in ([], nil) },
        fetchHistoryVideos: @escaping () async throws -> [VideoItem] = { [] },
        fetchPlaylistVideos: @escaping (String) async throws -> [VideoItem] = { _ in [] },
        search: @escaping (String) async throws -> [VideoItem] = { _ in [] },
        fetchRelated: @escaping (String) async throws -> (videos: [VideoItem], ownerAvatarURL: URL?, description: String?, viewCount: String?, publishDate: String?) = { _ in ([], nil, nil, nil, nil) },
        fetchChannel: @escaping (String) async throws -> ChannelInfo = { id in ChannelInfo(channelId: id, name: nil, handle: nil, subscriberCount: nil, videoCount: nil, avatarURL: nil, bannerURL: nil) },
        fetchChannelTab: @escaping (String, ChannelTab) async throws -> ([VideoItem], String?) = { _, _ in ([], nil) },
        fetchChannelTabPage: @escaping (String) async throws -> ([VideoItem], String?) = { _ in ([], nil) },
        fetchChannelPlaylists: @escaping (String) async throws -> [ChannelPlaylistItem] = { _ in [] }
    ) -> ContentClient {
        ContentClient(fetchHome: fetchHome, fetchHomePage: fetchHomePage, fetchHistoryVideos: fetchHistoryVideos, fetchPlaylistVideos: fetchPlaylistVideos, search: search, fetchRelated: fetchRelated, fetchChannel: fetchChannel, fetchChannelTab: fetchChannelTab, fetchChannelTabPage: fetchChannelTabPage, fetchChannelPlaylists: fetchChannelPlaylists)
    }
}

// MARK: - 本番クライアント

extension ContentClient {
    static let live: ContentClient = {
        let model = YouTubeModel()
        return ContentClient(
            fetchHome: {
                guard AuthState.shared.isSignedIn else { return ([], nil) }
                return try await ContentClient.fetchBrowseViaInnertubeAPI(browseId: "FEwhat_to_watch", cookies: "")
            },
            fetchHomePage: { continuation in
                return try await ContentClient.fetchHomeNextPageViaInnertubeAPI(cookies: "", continuation: continuation)
            },
            fetchHistoryVideos: {
                guard AuthState.shared.isSignedIn else { return [] }
                let (videos, _) = try await ContentClient.fetchBrowseViaInnertubeAPI(browseId: "FEhistory", cookies: "")
                return videos
            },
            fetchPlaylistVideos: { playlistId in

                // ミックスリスト（RD始まり）は /next エンドポイントで取得
                if playlistId.hasPrefix("RD") {
                    return try await ContentClient.fetchMixViaNextAPI(playlistId: playlistId, cookies: "")
                }

                // 通常プレイリスト: VLプレフィックス付き・なし両方を試す
                let candidateBrowseIds: [String] = {
                    if playlistId.hasPrefix("VL"), playlistId.count > 2 {
                        return [playlistId, String(playlistId.dropFirst(2))]
                    } else {
                        return ["VL\(playlistId)", playlistId]
                    }
                }()

                for browseId in candidateBrowseIds {
                    let (initialVideos, initialToken) = try await ContentClient.fetchBrowseViaInnertubeAPI(browseId: browseId, cookies: "")
                    if !initialVideos.isEmpty { return initialVideos }

                    var continuation = initialToken
                    while let token = continuation {
                        let (videos, nextToken) = try await ContentClient.fetchBrowseContinuationViaInnertubeAPI(cookies: "", continuation: token)
                        if !videos.isEmpty { return videos }
                        continuation = nextToken
                    }
                }

                // /browse で取れなかった場合も /next にフォールバック
                return try await ContentClient.fetchMixViaNextAPI(playlistId: playlistId, cookies: "")
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
                let cookies = ""
                let json = try await ContentClient.callNextAPI(params: ["videoId": videoID], cookies: cookies)
                let videos = findVideoRenderers(in: json).compactMap { parseVideoRenderer($0) }.filter { $0.videoId != videoID }
                let ownerAvatarURL = extractOwnerAvatarURL(from: json)
                // 説明欄データを抽出
                let (desc, viewCount, publishDate) = extractVideoDescription(from: json)
                return (videos, ownerAvatarURL, desc, viewCount, publishDate)
            },
            fetchChannel: { channelId in
                let cookies = ""
                return try await ContentClient.fetchChannelViaInnertube(channelId: channelId, cookies: cookies)
            },
            fetchChannelTab: { channelId, tab in
                let cookies = ""
                // タブに対応する params を設定
                let params: String? = switch tab {
                case .home: nil
                case .videos: "EgZ2aWRlb3PyBgQKAjoA"
                case .live: "EgdzdHJlYW1z8gYECgJ6AA%3D%3D"
                case .playlists: "EglwbGF5bGlzdHPyBgQKAkIA"
                }
                return try await ContentClient.fetchChannelTabViaInnertube(
                    channelId: channelId, params: params, cookies: cookies
                )
            },
            fetchChannelTabPage: { continuation in
                let cookies = ""
                return try await ContentClient.fetchBrowseContinuationViaInnertubeAPI(
                    cookies: cookies, continuation: continuation
                )
            },
            fetchChannelPlaylists: { channelId in
                let cookies = ""
                let params = "EglwbGF5bGlzdHPyBgQKAkIA"
                let json = try await ContentClient.callBrowseAPI(browseId: channelId, params: params, cookies: cookies)
                return ContentClient.parsePlaylistLockups(from: json)
            }
        )
    }()
}

// MARK: - チャンネル情報取得

extension ContentClient {

    /// Innertube /browse でチャンネルヘッダー情報を取得する。
    private static func fetchChannelViaInnertube(channelId: String, cookies: String) async throws -> ChannelInfo {
        let json = try await callBrowseAPI(browseId: channelId, params: nil, cookies: cookies)

        // ヘッダー情報をパース（c4TabbedHeaderRenderer または pageHeaderRenderer）
        let header = json["header"] as? [String: Any]
        let c4 = header?["c4TabbedHeaderRenderer"] as? [String: Any]
        let pageHeader = (header?["pageHeaderRenderer"] as? [String: Any])
        let pageHeaderContent = (pageHeader?["content"] as? [String: Any])?["pageHeaderViewModel"] as? [String: Any]

        let name = c4?["title"] as? String
            ?? extractTextFromPageHeader(pageHeaderContent, key: "title")
        let handle = (c4?["channelHandleText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let handleText = handle?.compactMap({ $0["text"] as? String }).joined()
            ?? extractTextFromPageHeader(pageHeaderContent, key: "subtitle")
        let subscriberCount = (c4?["subscriberCountText"] as? [String: Any])?["simpleText"] as? String
            ?? extractMetadataFromPageHeader(pageHeaderContent, index: 0)
        let videoCount = (c4?["videosCountText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let videoCountText = videoCount?.compactMap({ $0["text"] as? String }).joined()
            ?? extractMetadataFromPageHeader(pageHeaderContent, index: 1)

        let avatarThumbs = (c4?["avatar"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let pageAvatarImage = (pageHeaderContent?["image"] as? [String: Any])?["decoratedAvatarViewModel"] as? [String: Any]
        let pageAvatarSources = ((pageAvatarImage?["avatar"] as? [String: Any])?["avatarViewModel"] as? [String: Any])?["image"] as? [String: Any]
        let avatarSources = avatarThumbs ?? (pageAvatarSources?["sources"] as? [[String: Any]])
        let avatarURL = ContentClient.imageURL(from: avatarSources?.last?["url"] as? String)

        let bannerThumbs = (c4?["banner"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let pageBanner = (pageHeaderContent?["banner"] as? [String: Any])?["imageBannerViewModel"] as? [String: Any]
        let pageBannerSources = (pageBanner?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
        let bannerSources = bannerThumbs ?? pageBannerSources
        let bannerURL = ContentClient.imageURL(from: bannerSources?.last?["url"] as? String)

        return ChannelInfo(
            channelId: channelId,
            name: name,
            handle: handleText,
            subscriberCount: subscriberCount,
            videoCount: videoCountText,
            avatarURL: avatarURL,
            bannerURL: bannerURL
        )
    }

    /// チャンネルの特定タブを取得する（params で動画/ライブ/プレイリストを切り替え）。
    private static func fetchChannelTabViaInnertube(channelId: String, params: String?, cookies: String) async throws -> ([VideoItem], String?) {
        let json = try await callBrowseAPI(browseId: channelId, params: params, cookies: cookies)
        let videos = findVideoRenderers(in: json).compactMap { parseVideoRenderer($0) }
        let continuation = extractContinuationToken(in: json)
        return (videos, continuation)
    }

    /// Innertube /browse API を認証付きで呼び出す共通メソッド（params 対応）。
    static func callBrowseAPI(browseId: String, params: String?, cookies: String) async throws -> [String: Any] {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        applyAuth(to: &request)
        var body: [String: Any] = [
            "browseId": browseId,
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20241201.01.00", "hl": "ja", "gl": "JP"]]
        ]
        if let params { body["params"] = params }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: sessionConfig)
        let (data, _) = try await session.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// JSON ツリーから lockupViewModel (PLAYLIST/ALBUM) をパースしてプレイリスト一覧を返す。
    /// /next レスポンスから動画説明欄データ（説明文・視聴回数・投稿日）を抽出する。
    static func extractVideoDescription(from json: Any) -> (description: String?, viewCount: String?, publishDate: String?) {
        var description: String?
        var viewCount: String?
        var publishDate: String?

        guard let dict = json as? [String: Any] else { return (nil, nil, nil) }

        // structuredDescriptionContentRenderer から取得
        func findStructured(in obj: Any) {
            if let d = obj as? [String: Any] {
                if let sdcr = d["structuredDescriptionContentRenderer"] as? [String: Any],
                   let items = sdcr["items"] as? [[String: Any]] {
                    for item in items {
                        // 説明文ヘッダー（視聴回数・投稿日）
                        if let hdr = item["videoDescriptionHeaderRenderer"] as? [String: Any] {
                            let viewRuns = (hdr["views"] as? [String: Any])?["simpleText"] as? String
                            if let v = viewRuns { viewCount = v }
                            let dateText = (hdr["publishDate"] as? [String: Any])?["simpleText"] as? String
                            if let d = dateText { publishDate = d }
                        }
                        // 説明文本文
                        if let body = item["expandableVideoDescriptionBodyRenderer"] as? [String: Any] {
                            let content = (body["attributedDescriptionBodyText"] as? [String: Any])?["content"] as? String
                                ?? (body["descriptionBodyText"] as? [String: Any])?["content"] as? String
                            if let c = content { description = c }
                        }
                    }
                    return
                }
                for (_, v) in d { findStructured(in: v) }
            } else if let a = obj as? [Any] {
                for item in a { findStructured(in: item) }
            }
        }
        findStructured(in: dict)

        // フォールバック: videoPrimaryInfoRenderer / videoSecondaryInfoRenderer
        if viewCount == nil || publishDate == nil {
            func findPrimary(in obj: Any) {
                if let d = obj as? [String: Any] {
                    if let vpir = d["videoPrimaryInfoRenderer"] as? [String: Any] {
                        if viewCount == nil {
                            let vcr = (vpir["viewCount"] as? [String: Any])?["videoViewCountRenderer"] as? [String: Any]
                            viewCount = (vcr?["viewCount"] as? [String: Any])?["simpleText"] as? String
                        }
                        if publishDate == nil {
                            publishDate = (vpir["dateText"] as? [String: Any])?["simpleText"] as? String
                        }
                        return
                    }
                    for (_, v) in d { findPrimary(in: v) }
                } else if let a = obj as? [Any] {
                    for item in a { findPrimary(in: item) }
                }
            }
            findPrimary(in: dict)
        }

        if description == nil {
            func findSecondary(in obj: Any) {
                if let d = obj as? [String: Any] {
                    if let vsir = d["videoSecondaryInfoRenderer"] as? [String: Any] {
                        description = (vsir["attributedDescription"] as? [String: Any])?["content"] as? String
                        return
                    }
                    for (_, v) in d { findSecondary(in: v) }
                } else if let a = obj as? [Any] {
                    for item in a { findSecondary(in: item) }
                }
            }
            findSecondary(in: dict)
        }

        return (description, viewCount, publishDate)
    }

    /// /next レスポンスの videoOwnerRenderer からチャンネルアバター URL を抽出する。
    static func extractOwnerAvatarURL(from json: Any) -> URL? {
        if let dict = json as? [String: Any] {
            if let vor = dict["videoOwnerRenderer"] as? [String: Any] {
                let thumbs = (vor["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                return imageURL(from: thumbs?.last?["url"] as? String)
            }
            for (_, v) in dict {
                if let url = extractOwnerAvatarURL(from: v) { return url }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let url = extractOwnerAvatarURL(from: item) { return url }
            }
        }
        return nil
    }

    /// /next API を共通ヘルパーで呼び出す。
    private static func callNextAPI(params: [String: Any], cookies: String) async throws -> [String: Any] {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/next?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        applyAuth(to: &request)
        var body: [String: Any] = params
        body["context"] = ["client": ["clientName": "WEB", "clientVersion": "2.20241201.01.00", "hl": "ja", "gl": "JP"]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: sessionConfig)
        let (data, _) = try await session.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// /next エンドポイントでミックスリスト・プレイリストの動画一覧を取得する。
    static func fetchMixViaNextAPI(playlistId: String, cookies: String) async throws -> [VideoItem] {
        let json = try await callNextAPI(params: ["playlistId": playlistId], cookies: cookies)
        return parsePlaylistPanelRenderers(from: json)
    }

    /// playlistPanelVideoRenderer から VideoItem の配列をパースする。
    static func parsePlaylistPanelRenderers(from json: Any) -> [VideoItem] {
        var renderers: [[String: Any]] = []
        findPlaylistPanelRenderers(in: json, results: &renderers)
        return renderers.compactMap { renderer -> VideoItem? in
            guard let videoId = renderer["videoId"] as? String else { return nil }
            let title = (renderer["title"] as? [String: Any])?["simpleText"] as? String
                ?? ((renderer["title"] as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap({ $0["text"] as? String }).joined()
                ?? videoId
            let thumbs = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let thumbURL = imageURL(from: thumbs?.last?["url"] as? String)
            let channelName = ((renderer["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String
                ?? ((renderer["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String
            return VideoItem(videoId: videoId, title: title, channelName: channelName, thumbnailURL: thumbURL)
        }
    }

    private static func findPlaylistPanelRenderers(in json: Any, results: inout [[String: Any]]) {
        if let dict = json as? [String: Any] {
            if let r = dict["playlistPanelVideoRenderer"] as? [String: Any] {
                results.append(r)
            } else {
                for (_, v) in dict { findPlaylistPanelRenderers(in: v, results: &results) }
            }
        } else if let array = json as? [Any] {
            for item in array { findPlaylistPanelRenderers(in: item, results: &results) }
        }
    }

    static func parsePlaylistLockups(from json: Any) -> [ChannelPlaylistItem] {
        var items: [ChannelPlaylistItem] = []
        findLockups(in: json, items: &items)
        return items
    }

    private static func findLockups(in json: Any, items: inout [ChannelPlaylistItem]) {
        if let dict = json as? [String: Any] {
            if let lvm = dict["lockupViewModel"] as? [String: Any],
               let contentType = lvm["contentType"] as? String,
               contentType.contains("PLAYLIST") || contentType.contains("ALBUM"),
               let contentId = lvm["contentId"] as? String {
                let meta = (lvm["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
                let title = (meta?["title"] as? [String: Any])?["content"] as? String ?? contentId

                // サムネイル: collectionThumbnailViewModel.primaryThumbnail.thumbnailViewModel.image.sources
                let ci = lvm["contentImage"] as? [String: Any]
                let ctvm = ci?["collectionThumbnailViewModel"] as? [String: Any]
                    ?? ci?["thumbnailViewModel"] as? [String: Any]
                let primaryThumb = (ctvm?["primaryThumbnail"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
                    ?? ctvm
                let thumbSrcs = (primaryThumb?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
                let thumbnailURL = imageURL(from: thumbSrcs?.first?["url"] as? String)

                // 動画数: overlays 内の thumbnailBadgeViewModel.text
                var videoCount: String? = nil
                if let overlays = primaryThumb?["overlays"] as? [[String: Any]] {
                    for overlay in overlays {
                        if let badge = overlay["thumbnailOverlayBadgeViewModel"] as? [String: Any],
                           let badges = badge["thumbnailBadges"] as? [[String: Any]],
                           let first = badges.first,
                           let text = (first["thumbnailBadgeViewModel"] as? [String: Any])?["text"] as? String {
                            videoCount = text
                            break
                        }
                    }
                }

                items.append(ChannelPlaylistItem(
                    playlistId: contentId,
                    title: title,
                    thumbnailURL: thumbnailURL,
                    videoCount: videoCount
                ))
            } else {
                for (_, value) in dict { findLockups(in: value, items: &items) }
            }
        } else if let array = json as? [Any] {
            for item in array { findLockups(in: item, items: &items) }
        }
    }

    /// pageHeaderViewModel からテキストを抽出するヘルパー
    private static func extractTextFromPageHeader(_ pageHeader: [String: Any]?, key: String) -> String? {
        guard let ph = pageHeader else { return nil }
        if let titleVM = (ph[key] as? [String: Any])?["dynamicTextViewModel"] as? [String: Any] {
            return (titleVM["text"] as? [String: Any])?["content"] as? String
        }
        return (ph[key] as? [String: Any])?["content"] as? String
    }

    /// pageHeaderViewModel の metadata からインデックス指定でテキストを取得するヘルパー
    private static func extractMetadataFromPageHeader(_ pageHeader: [String: Any]?, index: Int) -> String? {
        guard let ph = pageHeader,
              let metadata = (ph["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any],
              let rows = metadata["metadataRows"] as? [[String: Any]],
              index < rows.count,
              let parts = rows[index]["metadataParts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = (firstPart["text"] as? [String: Any])?["content"] as? String
        else { return nil }
        return text
    }
}

// MARK: - URL ヘルパー

extension ContentClient {

    /// YouTube のプロトコル相対 URL（`//` 始まり）を `https:` 付きに補正して URL を生成する。
    static func imageURL(from string: String?) -> URL? {
        guard var s = string, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    /// JSON ツリー内から UC 始まりの browseId（チャンネルID）と隣接するテキスト（チャンネル名）を探索する。
    static func extractChannelInfo(from json: Any) -> (name: String?, id: String?) {
        var channelName: String?
        var channelId: String?
        findChannelBrowseEndpoints(in: json, name: &channelName, id: &channelId)
        return (channelName, channelId)
    }

    /// browseEndpoint.browseId が UC 始まりのものを探し、対応するテキストをチャンネル名として返す。
    private static func findChannelBrowseEndpoints(in json: Any, name: inout String?, id: inout String?) {
        guard id == nil else { return }
        if let dict = json as? [String: Any] {
            // "content" + "commandRuns" パターン
            if let content = dict["content"] as? String,
               let cmdRuns = dict["commandRuns"] as? [[String: Any]] {
                for cmdRun in cmdRuns {
                    if let browse = ((cmdRun["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
                       let bid = browse["browseId"] as? String, bid.hasPrefix("UC") {
                        name = content
                        id = bid
                        return
                    }
                }
            }
            // "runs" パターン
            if let runs = dict["runs"] as? [[String: Any]] {
                for run in runs {
                    if let text = run["text"] as? String,
                       let browse = (run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
                       let bid = browse["browseId"] as? String, bid.hasPrefix("UC") {
                        name = text
                        id = bid
                        return
                    }
                }
            }
            // decoratedAvatarViewModel パターン（関連動画の lockupViewModel で使用）
            // a11yLabel からチャンネル名、rendererContext から browseId を取得
            if let dav = dict["decoratedAvatarViewModel"] as? [String: Any] {
                let a11y = dav["a11yLabel"] as? String
                let rc = (dav["rendererContext"] as? [String: Any])?["commandContext"] as? [String: Any]
                let browse = ((rc?["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
                if let bid = browse?["browseId"] as? String, bid.hasPrefix("UC") {
                    id = bid
                    // a11yLabel: 「チャンネル「XXX」に移動します」からチャンネル名を抽出
                    if let a11y, let start = a11y.firstIndex(of: "「"), let end = a11y.lastIndex(of: "」") {
                        let nameStart = a11y.index(after: start)
                        if nameStart < end {
                            name = String(a11y[nameStart..<end])
                        }
                    }
                    return
                }
            }
            // metadataParts パターン（metadataRowViewModel なし、直接 metadataParts がある場合）
            if let parts = dict["metadataParts"] as? [[String: Any]], id == nil {
                // 最初の text.content をチャンネル名候補として保持（後で browseId と合わせて確定）
                if name == nil, let firstText = (parts.first?["text"] as? [String: Any])?["content"] as? String {
                    name = firstText
                }
            }
            for (_, value) in dict {
                findChannelBrowseEndpoints(in: value, name: &name, id: &id)
                if id != nil { return }
            }
        } else if let array = json as? [Any] {
            for item in array {
                findChannelBrowseEndpoints(in: item, name: &name, id: &id)
                if id != nil { return }
            }
        }
    }

    /// JSON ツリー内から yt3.ggpht.com を含むアバター URL を再帰的に探索する。
    static func findAvatarURL(in json: Any) -> URL? {
        if let dict = json as? [String: Any] {
            // "url" キーに yt3.ggpht.com が含まれていればアバター
            if let urlStr = dict["url"] as? String, urlStr.contains("yt3.ggpht.com") {
                return imageURL(from: urlStr)
            }
            for (_, value) in dict {
                if let url = findAvatarURL(in: value) { return url }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let url = findAvatarURL(in: item) { return url }
            }
        }
        return nil
    }
}

// MARK: - Innertube browse API によるホームフィード取得

extension ContentClient {

    /// Cookie 文字列の重複を除去する（後勝ち: 同名が複数あれば最後の値を採用）
    static func deduplicateCookies(_ cookieString: String) -> String {
        var seen: [String: String] = [:]
        var order: [String] = []
        for pair in cookieString.components(separatedBy: "; ") {
            guard let eqIdx = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[pair.startIndex..<eqIdx])
            guard !name.isEmpty else { continue }
            if seen[name] == nil { order.append(name) }
            seen[name] = pair
        }
        return order.compactMap { seen[$0] }.joined(separator: "; ")
    }

    /// リクエストに Cookie + SAPISIDHASH 認証ヘッダーを適用する
    static func applyAuth(to request: inout URLRequest) {
        guard let cookies = AuthState.shared.cookieString, !cookies.isEmpty else { return }
        let deduped = deduplicateCookies(cookies)
        request.setValue(deduped, forHTTPHeaderField: "Cookie")
        if let auth = buildSapisidHash(from: deduped) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
    }

    /// SAPISID ハッシュを生成して Authorization ヘッダー用の文字列を返す。
    /// 形式: SAPISIDHASH <timestamp>_<SHA1(timestamp + " " + sapisid + " " + origin)>
    /// __Secure-3PAPISID が優先（なければ SAPISID にフォールバック）
    static func buildSapisidHash(from cookieString: String) -> String? {
        let pairs = cookieString.components(separatedBy: "; ")
        func cookieValue(for name: String) -> String? {
            pairs.first(where: { $0.hasPrefix("\(name)=") })
                .map { String($0.dropFirst("\(name)=".count)) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let sapisid = cookieValue(for: "__Secure-3PAPISID")
                         ?? cookieValue(for: "SAPISID") else { return nil }

        let origin = "https://www.youtube.com"
        let timestamp = Int(Date().timeIntervalSince1970)
        guard let data = "\(timestamp) \(sapisid) \(origin)".data(using: .utf8) else { return nil }
        let hash = Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hash)"
    }

    /// URLSession で Innertube /browse (WEB client) を叩いて指定 browseId のコンテンツを取得する。
    /// 認証: Cookie ヘッダー直接設定 + SAPISIDHASH + X-Goog-AuthUser: 0
    private static func fetchBrowseViaInnertubeAPI(browseId: String, cookies: String) async throws -> ([VideoItem], String?) {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        applyAuth(to: &request)

        let body: [String: Any] = [
            "browseId": browseId,
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20241201.01.00", "hl": "ja", "gl": "JP"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Cookie ヘッダーをシステムに上書きされないよう httpShouldSetCookies=false に設定
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: sessionConfig)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            strixLog("Innertube browse[\(browseId)] HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            strixLog("Innertube browse[\(browseId)] JSON パース失敗")
            return ([], nil)
        }
        let videos = findVideoRenderers(in: json).compactMap { parseVideoRenderer($0) }
        let nextToken = extractContinuationToken(in: json)
        strixLog("Innertube browse[\(browseId)] \(videos.count)件 continuation=\(nextToken != nil)")
        return (videos, nextToken)
    }

    /// Innertube /browse に continuation token を使って次ページを取得する。
    static func fetchBrowseContinuationViaInnertubeAPI(cookies: String, continuation: String) async throws -> ([VideoItem], String?) {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        applyAuth(to: &request)

        let body: [String: Any] = [
            "continuation": continuation,
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20241201.01.00", "hl": "ja", "gl": "JP"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: sessionConfig)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            strixLog("Innertube browse continuation HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            strixLog("Innertube browse continuation JSON パース失敗")
            return ([], nil)
        }
        let videos = findVideoRenderers(in: json).compactMap { parseVideoRenderer($0) }
        let nextToken = extractContinuationToken(in: json)
        strixLog("Innertube browse continuation \(videos.count)件 continuation=\(nextToken != nil)")
        return (videos, nextToken)
    }

    private static func fetchHomeNextPageViaInnertubeAPI(cookies: String, continuation: String) async throws -> ([VideoItem], String?) {
        try await fetchBrowseContinuationViaInnertubeAPI(cookies: cookies, continuation: continuation)
    }

    /// JSON ツリーを再帰的に探索して continuation token を抽出する。
    /// continuationCommand.token パスを探す。
    static func extractContinuationToken(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let cmd = dict["continuationCommand"] as? [String: Any],
               let token = cmd["token"] as? String {
                return token
            }
            for value in dict.values {
                if let token = extractContinuationToken(in: value) { return token }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let token = extractContinuationToken(in: item) { return token }
            }
        }
        return nil
    }

    /// JSON ツリーを再帰的に探索して動画 Renderer を全て抽出する。
    /// WEB 旧形式 → videoRenderer / compactVideoRenderer / playlistVideoRenderer
    /// WEB 新形式 → lockupViewModel
    /// IOS 旧形式 → compactVideoRenderer / elementRenderer 内の videoWithContextModel
    /// IOS 新形式 → videoWithContextModel
    static func findVideoRenderers(in json: Any) -> [[String: Any]] {
        if let dict = json as? [String: Any] {
            // WEB 旧形式
            if let vr = dict["videoRenderer"] as? [String: Any] { return [vr] }
            if let vr = dict["compactVideoRenderer"] as? [String: Any] { return [vr] }
            if let vr = dict["playlistVideoRenderer"] as? [String: Any] { return [vr] }
            // WEB 新形式 (2024 年以降の主要フォーマット)
            if let vr = dict["lockupViewModel"] as? [String: Any] { return [vr] }
            // IOS 新形式: videoWithContextModel が直接キーとして現れる場合
            if let vr = dict["videoWithContextModel"] as? [String: Any] { return [vr] }
            // IOS 旧形式: elementRenderer 内の決まったパス
            if let el = dict["elementRenderer"] as? [String: Any],
               let item = extractVideoWithContextModel(from: el) { return [item] }
            // その他のキーを再帰的に探索
            return dict.values.flatMap { findVideoRenderers(in: $0) }
        } else if let array = json as? [Any] {
            return array.flatMap { findVideoRenderers(in: $0) }
        }
        return []
    }

    /// elementRenderer から videoWithContextModel を取り出す。
    /// パス: newElement.type.componentType.model.videoWithContextModel
    static func extractVideoWithContextModel(from el: [String: Any]) -> [String: Any]? {
        guard
            let newElement   = el["newElement"]  as? [String: Any],
            let type_        = newElement["type"] as? [String: Any],
            let component    = type_["componentType"] as? [String: Any],
            let model        = component["model"]     as? [String: Any],
            let vcm          = model["videoWithContextModel"] as? [String: Any]
        else { return nil }
        return vcm
    }

    /// videoRenderer / compactVideoRenderer / playlistVideoRenderer / lockupViewModel / videoWithContextModel から VideoItem を生成する。
    static func parseVideoRenderer(_ vr: [String: Any]) -> VideoItem? {
        // ── WEB 新形式: lockupViewModel ────────────────────────────────────
        if vr["contentId"] != nil {
            return parseLockupViewModel(vr)
        }

        // ── IOS 新形式: videoWithContextModel ─────────────────────────────
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
        let thumbURL = ContentClient.imageURL(from: thumbs?.last?["url"] as? String)

        // チャンネル名・チャンネルID: ownerText / longBylineText / shortBylineText
        let ownerRuns = ((vr["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]])
            ?? ((vr["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])
            ?? ((vr["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])
        let channelName = ownerRuns?.first?["text"] as? String
        let channelId = ((ownerRuns?.first?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String

        // チャンネルアバター
        let chThumb = vr["channelThumbnailSupportedRenderers"] as? [String: Any]
        let chThumbLink = chThumb?["channelThumbnailWithLinkRenderer"] as? [String: Any]
        let chThumbObj = chThumbLink?["thumbnail"] as? [String: Any]
        let chThumbs = chThumbObj?["thumbnails"] as? [[String: Any]]
        let avatarURL = ContentClient.imageURL(from: chThumbs?.last?["url"] as? String)

        // 視聴回数・投稿日時
        let videoInfoRuns = (vr["videoInfo"] as? [String: Any])?["runs"] as? [[String: Any]]
        let viewCount = (vr["shortViewCountText"] as? [String: Any])?["simpleText"] as? String
            ?? videoInfoRuns?.first?["text"] as? String
        let timePosted = (vr["publishedTimeText"] as? [String: Any])?["simpleText"] as? String
            ?? videoInfoRuns?.dropFirst().first(where: { ($0["text"] as? String) != " • " })?["text"] as? String

        return VideoItem(
            videoId: videoId,
            title: title,
            channelId: channelId,
            channelName: channelName,
            thumbnailURL: thumbURL,
            channelAvatarURL: avatarURL,
            viewCountText: viewCount,
            timePostedText: timePosted
        )
    }

    /// WEB 新形式 lockupViewModel から VideoItem を生成する。
    ///
    /// 主要パス:
    ///   videoId    : contentId
    ///   title      : metadata.lockupMetadataViewModel.title.content
    ///   thumbnail  : contentImage.thumbnailViewModel.image.sources[last].url
    ///   channelName: metadata.lockupMetadataViewModel.metadata.contentMetadataViewModel.metadataRows[0]
    ///   avatar     : metadata.lockupMetadataViewModel.image.sources[last].url
    static func parseLockupViewModel(_ lvm: [String: Any]) -> VideoItem? {
        guard let contentId = lvm["contentId"] as? String else { return nil }
        let contentType = lvm["contentType"] as? String ?? ""
        let isPlaylist = contentType.contains("PLAYLIST") || contentType.contains("MIX")

        let lmvm = (lvm["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]

        // タイトル
        let title = (lmvm?["title"] as? [String: Any])?["content"] as? String ?? contentId

        // サムネイル: thumbnailViewModel または collectionThumbnailViewModel
        let ci = lvm["contentImage"] as? [String: Any]
        let ciTvm = ci?["thumbnailViewModel"] as? [String: Any]
        let collTvm = (ci?["collectionThumbnailViewModel"] as? [String: Any])?["primaryThumbnail"] as? [String: Any]
        let resolvedTvm = ciTvm ?? (collTvm?["thumbnailViewModel"] as? [String: Any])
        let thumbSrcs = (resolvedTvm?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
        let thumbnailURL = ContentClient.imageURL(from: thumbSrcs?.last?["url"] as? String)

        // チャンネル名・チャンネルID: lockupMetadataViewModel 内を再帰探索
        let (channelName, channelId) = extractChannelInfo(from: lmvm as Any)

        // チャンネルアバター: 複数パスから探索
        // 1. lockupMetadataViewModel.image.sources（直接アバター）
        // 2. metadataRows 内の avatarViewModel.image.sources
        // 3. metadataRows 内の image.sources
        var channelAvatarURL: URL? = nil
        // パス1
        let avatarSrcs = (lmvm?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
        channelAvatarURL = ContentClient.imageURL(from: avatarSrcs?.last?["url"] as? String)
        // パス2: metadataRows 内を深く探索
        if channelAvatarURL == nil, let cmvm = (lmvm?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any],
           let rows = cmvm["metadataRows"] as? [[String: Any]] {
            for row in rows {
                if let rvm = row["metadataRowViewModel"] as? [String: Any] {
                    // avatarViewModel パス
                    if let avatarVM = rvm["image"] as? [String: Any] {
                        let sources = (avatarVM["image"] as? [String: Any])?["sources"] as? [[String: Any]]
                            ?? avatarVM["sources"] as? [[String: Any]]
                        if let url = ContentClient.imageURL(from: sources?.last?["url"] as? String) {
                            channelAvatarURL = url
                            break
                        }
                    }
                }
            }
        }
        // パス3: lockupMetadataViewModel 内を再帰探索（yt3.ggpht.com）
        if channelAvatarURL == nil {
            channelAvatarURL = findAvatarURL(in: lmvm as Any)
        }

        return VideoItem(
            videoId: contentId,
            title: title,
            channelId: channelId,
            channelName: channelName,
            thumbnailURL: thumbnailURL,
            channelAvatarURL: channelAvatarURL,
            viewCountText: nil,
            timePostedText: nil,
            playlistId: isPlaylist ? contentId : nil
        )
    }

    /// IOS 新形式の videoWithContextData オブジェクトから VideoItem を生成する。
    ///
    /// 想定パス:
    ///   videoId   : onTap.innertubeCommand.watchEndpoint.videoId
    ///   title     : videoData.metadata.title
    ///   channel   : videoData.metadata.byline (または channelThumbnail)
    ///   thumbnail : videoData.thumbnail.image.sources[last].url
    static func parseVideoWithContextData(_ data: [String: Any]) -> VideoItem? {
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
        let thumbURL    = ContentClient.imageURL(from: thumbSrcs?.last?["url"] as? String)

        // チャンネルアバター: channelThumbnail.image.sources[last].url
        let chThumbImg  = (data["channelThumbnail"] as? [String: Any])?["image"] as? [String: Any]
        let chThumbSrcs = chThumbImg?["sources"] as? [[String: Any]]
        let avatarURL   = ContentClient.imageURL(from: chThumbSrcs?.last?["url"] as? String)

        // チャンネルID
        let channelId = metadata?["channelId"] as? String
            ?? ((onTap?["innertubeCommand"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["channelId"] as? String

        // 視聴回数・投稿日時
        let viewCount   = metadata?["shortViewCountText"] as? String
        let timePosted  = metadata?["publishedTimeText"]  as? String

        return VideoItem(
            videoId: videoId,
            title: title,
            channelId: channelId,
            channelName: channelName,
            thumbnailURL: thumbURL,
            channelAvatarURL: avatarURL,
            viewCountText: viewCount,
            timePostedText: timePosted
        )
    }
}
