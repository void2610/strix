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
    var fetchHistoryVideos: () async throws -> ([VideoItem], String?)
    /// 視聴履歴の次ページを取得
    var fetchHistoryPage: (String) async throws -> ([VideoItem], String?)
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
    /// コメントを取得（初回は videoID、ページネーションは continuation token）
    var fetchComments: (_ videoID: String) async throws -> (comments: [CommentItem], continuation: String?)
    /// コメントの次ページを取得
    var fetchCommentsPage: (_ continuation: String) async throws -> (comments: [CommentItem], continuation: String?)
}

// MARK: - モック（テスト用）

extension ContentClient {
    static func mock(
        fetchHome: @escaping () async throws -> ([VideoItem], String?) = { ([], nil) },
        fetchHomePage: @escaping (String) async throws -> ([VideoItem], String?) = { _ in ([], nil) },
        fetchHistoryVideos: @escaping () async throws -> ([VideoItem], String?) = { ([], nil) },
        fetchHistoryPage: @escaping (String) async throws -> ([VideoItem], String?) = { _ in ([], nil) },
        fetchPlaylistVideos: @escaping (String) async throws -> [VideoItem] = { _ in [] },
        search: @escaping (String) async throws -> [VideoItem] = { _ in [] },
        fetchRelated: @escaping (String) async throws -> (videos: [VideoItem], ownerAvatarURL: URL?, description: String?, viewCount: String?, publishDate: String?) = { _ in ([], nil, nil, nil, nil) },
        fetchChannel: @escaping (String) async throws -> ChannelInfo = { id in ChannelInfo(channelId: id, name: nil, handle: nil, subscriberCount: nil, videoCount: nil, avatarURL: nil, bannerURL: nil) },
        fetchChannelTab: @escaping (String, ChannelTab) async throws -> ([VideoItem], String?) = { _, _ in ([], nil) },
        fetchChannelTabPage: @escaping (String) async throws -> ([VideoItem], String?) = { _ in ([], nil) },
        fetchChannelPlaylists: @escaping (String) async throws -> [ChannelPlaylistItem] = { _ in [] },
        fetchComments: @escaping (String) async throws -> (comments: [CommentItem], continuation: String?) = { _ in ([], nil) },
        fetchCommentsPage: @escaping (String) async throws -> (comments: [CommentItem], continuation: String?) = { _ in ([], nil) }
    ) -> ContentClient {
        ContentClient(fetchHome: fetchHome, fetchHomePage: fetchHomePage, fetchHistoryVideos: fetchHistoryVideos, fetchHistoryPage: fetchHistoryPage, fetchPlaylistVideos: fetchPlaylistVideos, search: search, fetchRelated: fetchRelated, fetchChannel: fetchChannel, fetchChannelTab: fetchChannelTab, fetchChannelTabPage: fetchChannelTabPage, fetchChannelPlaylists: fetchChannelPlaylists, fetchComments: fetchComments, fetchCommentsPage: fetchCommentsPage)
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
                guard AuthState.shared.isSignedIn else { return ([], nil) }
                return try await ContentClient.fetchBrowseViaInnertubeAPI(browseId: "FEhistory", cookies: "")
            },
            fetchHistoryPage: { continuation in
                return try await ContentClient.fetchBrowseContinuationViaInnertubeAPI(cookies: "", continuation: continuation)
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
            },
            fetchComments: { videoID in
                let cookies = ""
                let json = try await ContentClient.callNextAPI(params: ["videoId": videoID], cookies: cookies)
                // /next レスポンスからコメントの continuation token を取得
                guard let token = extractCommentContinuation(from: json) else { return ([], nil) }
                // continuation token でコメント本体を取得
                let commentsJSON = try await ContentClient.callNextAPI(params: ["continuation": token], cookies: cookies)
                return parseComments(from: commentsJSON)
            },
            fetchCommentsPage: { continuation in
                let cookies = ""
                let json = try await ContentClient.callNextAPI(params: ["continuation": continuation], cookies: cookies)
                return parseComments(from: json)
            }
        )
    }()
}

// MARK: - Innertube API 共通メソッド

extension ContentClient {

    /// Innertube /browse API を認証付きで呼び出す共通メソッド（params 対応）。
    static func callBrowseAPI(browseId: String, params: String?, cookies: String) async throws -> [String: Any] {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await InnertubeRequest.fetchWeb(url: YouTubeConstants.browseURL, body: body)
    }

    /// /next API を共通ヘルパーで呼び出す。
    static func callNextAPI(params: [String: Any], cookies: String) async throws -> [String: Any] {
        return try await InnertubeRequest.fetchWeb(url: YouTubeConstants.nextURL, body: params)
    }

    /// Innertube /browse (WEB client) で指定 browseId のコンテンツを取得する。
    static func fetchBrowseViaInnertubeAPI(browseId: String, cookies: String) async throws -> ([VideoItem], String?) {
        let json = try await InnertubeRequest.fetchWeb(
            url: YouTubeConstants.browseURL,
            body: ["browseId": browseId]
        )
        let videos = findVideoRenderers(in: json).compactMap { parseVideoRenderer($0) }
        let nextToken = extractContinuationToken(in: json)
        strixLog("Innertube browse[\(browseId)] \(videos.count)件 continuation=\(nextToken != nil)")
        return (videos, nextToken)
    }

    /// Innertube /browse に continuation token を使って次ページを取得する。
    static func fetchBrowseContinuationViaInnertubeAPI(cookies: String, continuation: String) async throws -> ([VideoItem], String?) {
        let json = try await InnertubeRequest.fetchWeb(
            url: YouTubeConstants.browseURL,
            body: ["continuation": continuation]
        )
        let videos = findVideoRenderers(in: json).compactMap { parseVideoRenderer($0) }
        let nextToken = extractContinuationToken(in: json)
        strixLog("Innertube browse continuation \(videos.count)件 continuation=\(nextToken != nil)")
        return (videos, nextToken)
    }

    private static func fetchHomeNextPageViaInnertubeAPI(cookies: String, continuation: String) async throws -> ([VideoItem], String?) {
        try await fetchBrowseContinuationViaInnertubeAPI(cookies: cookies, continuation: continuation)
    }
}

// MARK: - 認証ヘルパー

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
        request.setValue(YouTubeConstants.origin, forHTTPHeaderField: "X-Origin")
    }

    /// SAPISID ハッシュを生成して Authorization ヘッダー用の文字列を返す。
    static func buildSapisidHash(from cookieString: String) -> String? {
        let pairs = cookieString.components(separatedBy: "; ")
        func cookieValue(for name: String) -> String? {
            pairs.first(where: { $0.hasPrefix("\(name)=") })
                .map { String($0.dropFirst("\(name)=".count)) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let sapisid = cookieValue(for: "__Secure-3PAPISID")
                         ?? cookieValue(for: "SAPISID") else { return nil }

        let origin = YouTubeConstants.origin
        let timestamp = Int(Date().timeIntervalSince1970)
        guard let data = "\(timestamp) \(sapisid) \(origin)".data(using: .utf8) else { return nil }
        let hash = Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hash)"
    }
}
