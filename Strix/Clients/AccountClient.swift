//
//  AccountClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import CryptoKit
import YouTubeKit

// MARK: - アカウント情報モデル

/// Innertube account_menu から取得するシンプルなアカウント情報。
struct AccountInfo {
    let name: String?
    let handle: String?
    let avatarURL: URL?
}

/// ライブラリ API レスポンス（後で見る・いいね・カスタムプレイリスト）
struct LibraryResponse {
    var watchLater: YTPlaylist?
    var likes: YTPlaylist?
    var playlists: [YTPlaylist] = []
}

// MARK: - クライアント定義

/// アカウント情報・ライブラリ・視聴履歴・プレイリスト動画を取得するクライアント。
struct AccountClient {
    var fetchInfo: () async throws -> AccountInfo
    var fetchLibrary: () async throws -> LibraryResponse
    var fetchHistory: () async throws -> HistoryResponse
    var fetchPlaylistVideos: (_ playlistId: String) async throws -> [VideoItem]
}

// MARK: - モック（テスト用）

extension AccountClient {
    static func mock(
        fetchInfo: @escaping () async throws -> AccountInfo = { AccountInfo(name: nil, handle: nil, avatarURL: nil) },
        fetchLibrary: @escaping () async throws -> LibraryResponse = { LibraryResponse() },
        fetchHistory: @escaping () async throws -> HistoryResponse = { HistoryResponse.decodeData(data: Data()) },
        fetchPlaylistVideos: @escaping (String) async throws -> [VideoItem] = { _ in [] }
    ) -> AccountClient {
        AccountClient(
            fetchInfo: fetchInfo,
            fetchLibrary: fetchLibrary,
            fetchHistory: fetchHistory,
            fetchPlaylistVideos: fetchPlaylistVideos
        )
    }
}

// MARK: - 本番クライアント

extension AccountClient {
    static let live: AccountClient = {
        let model = YouTubeModel()

        return AccountClient(
            fetchInfo: {
                let cookies = AuthState.shared.cookieString ?? ""
                return try await AccountClient.fetchInfoViaInnertube(cookies: cookies)
            },
            fetchLibrary: {
                let cookies = AuthState.shared.cookieString ?? ""
                return try await AccountClient.fetchLibraryViaInnertube(cookies: cookies)
            },
            fetchHistory: {
                let cookies = ContentClient.deduplicateCookies(AuthState.shared.cookieString ?? "")
                model.cookies = cookies
                let (response, error) = await HistoryResponse.sendRequest(
                    youtubeModel: model, data: [:]
                )
                if let error { throw error }
                return response ?? HistoryResponse.decodeData(data: Data())
            },
            fetchPlaylistVideos: { playlistId in
                // VLプレフィックス付きIDを確保（YouTubeKit が要求する形式）
                let vlId = playlistId.hasPrefix("VL") ? playlistId : "VL\(playlistId)"
                let cookies = ContentClient.deduplicateCookies(AuthState.shared.cookieString ?? "")
                model.cookies = cookies
                let (response, error) = await PlaylistInfosResponse.sendRequest(
                    youtubeModel: model,
                    data: [.browseId: vlId]
                )
                if error == nil, var response {
                    while response.continuationToken != nil {
                        let (continuation, continuationError) = await response.fetchContinuation(youtubeModel: model)
                        if continuationError != nil { break }
                        guard let continuation else { break }
                        response.mergeWithContinuation(continuation)
                    }
                    let setVideoIds = response.videoIdsInPlaylist ?? []
                    let videos = response.results
                        .enumerated()
                        .compactMap { (i, result) -> VideoItem? in
                            guard let ytVideo = result as? YTVideo else { return nil }
                            var item = ytVideo.toVideoItem
                            // setVideoId をプレイリストレスポンスから注入
                            if i < setVideoIds.count, let svid = setVideoIds[i] {
                                item = VideoItem(
                                    videoId: item.videoId, title: item.title,
                                    channelId: item.channelId, channelName: item.channelName,
                                    thumbnailURL: item.thumbnailURL, channelAvatarURL: item.channelAvatarURL,
                                    viewCountText: item.viewCountText, timePostedText: item.timePostedText,
                                    feedbackTokens: item.feedbackTokens, setVideoId: svid
                                )
                            }
                            return item
                        }
                    if !videos.isEmpty { return videos }
                }
                // YouTubeKit で取れなかった場合は Innertube 直接呼び出しにフォールバック
                return try await ContentClient.live.fetchPlaylistVideos(playlistId)
            }
        )
    }()
}

// MARK: - Innertube API 共通ヘルパー

extension AccountClient {

    /// Innertube /browse (WEB client) を認証付きで呼び出す共通メソッド。
    private static func callBrowseAPI(browseId: String, cookies: String) async throws -> [String: Any] {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w&prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("2.20241201.01.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        ContentClient.applyAuth(to: &request)

        let body: [String: Any] = [
            "browseId": browseId,
            "context": ["client": [
                "clientName": "WEB",
                "clientVersion": "2.20241201.01.00",
                "hl": "ja",
                "gl": "JP"
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: sessionConfig)
        let (data, _) = try await session.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    // MARK: - ライブラリ取得（FElibrary）

    /// Innertube /browse (WEB client) で FElibrary を取得し、プレイリスト情報をパースする。
    /// レスポンス構造: contents.twoColumnBrowseResultsRenderer.tabs[0].tabRenderer.content
    ///   .richGridRenderer.contents[] → richSectionRenderer.content.richShelfRenderer
    private static func fetchLibraryViaInnertube(cookies: String) async throws -> LibraryResponse {
        let json = try await callBrowseAPI(browseId: "FElibrary", cookies: cookies)
        var result = LibraryResponse()

        // richShelfRenderer を全セクションから収集
        let shelves = extractRichShelves(from: json)

        for shelf in shelves {
            let title = extractShelfTitle(from: shelf)
            let browseId = extractShelfBrowseId(from: shelf)

            switch title {
            case "後で見る":
                result.watchLater = makePlaylist(from: shelf, fallbackId: browseId ?? "VLWL", fallbackTitle: "後で見る")
            case "高く評価した動画":
                result.likes = makePlaylist(from: shelf, fallbackId: browseId ?? "VLLL", fallbackTitle: "いいねした動画")
            case "再生リスト":
                result.playlists = parsePlaylistItems(from: shelf)
            default:
                break
            }
        }

        return result
    }

    /// JSON から richShelfRenderer を全て抽出する。
    /// パス: contents.twoColumnBrowseResultsRenderer.tabs[].tabRenderer.content
    ///       .richGridRenderer.contents[].richSectionRenderer.content.richShelfRenderer
    private static func extractRichShelves(from json: [String: Any]) -> [[String: Any]] {
        guard let contents = json["contents"] as? [String: Any],
              let browseResults = contents["twoColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = browseResults["tabs"] as? [[String: Any]] else { return [] }

        var shelves: [[String: Any]] = []
        for tab in tabs {
            guard let tabRenderer = tab["tabRenderer"] as? [String: Any],
                  let tabContent = tabRenderer["content"] as? [String: Any],
                  let richGrid = tabContent["richGridRenderer"] as? [String: Any],
                  let gridContents = richGrid["contents"] as? [[String: Any]] else { continue }

            for item in gridContents {
                if let richSection = item["richSectionRenderer"] as? [String: Any],
                   let sectionContent = richSection["content"] as? [String: Any],
                   let richShelf = sectionContent["richShelfRenderer"] as? [String: Any] {
                    shelves.append(richShelf)
                }
            }
        }
        return shelves
    }

    /// richShelfRenderer からタイトルを取得する。
    private static func extractShelfTitle(from shelf: [String: Any]) -> String? {
        guard let title = shelf["title"] as? [String: Any] else { return nil }
        return (title["runs"] as? [[String: Any]])?.compactMap({ $0["text"] as? String }).joined()
            ?? title["simpleText"] as? String
    }

    /// richShelfRenderer から browseId を取得する。
    private static func extractShelfBrowseId(from shelf: [String: Any]) -> String? {
        let endpoint = shelf["endpoint"] as? [String: Any]
        return (endpoint?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
    }

    /// richShelfRenderer からプレイリスト情報を作成する（後で見る・いいね用）。
    private static func makePlaylist(from shelf: [String: Any], fallbackId: String, fallbackTitle: String) -> YTPlaylist {
        let browseId = extractShelfBrowseId(from: shelf) ?? fallbackId
        var playlist = YTPlaylist(playlistId: browseId)
        playlist.title = extractShelfTitle(from: shelf) ?? fallbackTitle
        // subtitle から動画数を取得
        if let subtitle = shelf["subtitle"] as? [String: Any] {
            playlist.videoCount = (subtitle["runs"] as? [[String: Any]])?.compactMap({ $0["text"] as? String }).joined()
                ?? subtitle["simpleText"] as? String
        }
        return playlist
    }

    /// 「再生リスト」棚から個別のプレイリストをパースする。
    /// contents[] → richItemRenderer.content に lockupViewModel または gridPlaylistRenderer がある。
    private static func parsePlaylistItems(from shelf: [String: Any]) -> [YTPlaylist] {
        guard let items = shelf["contents"] as? [[String: Any]] else { return [] }
        var playlists: [YTPlaylist] = []

        for item in items {
            guard let richItem = item["richItemRenderer"] as? [String: Any],
                  let content = richItem["content"] as? [String: Any] else { continue }

            // lockupViewModel 形式（新UI）
            if let lockup = content["lockupViewModel"] as? [String: Any],
               let contentId = lockup["contentId"] as? String {
                var playlist = YTPlaylist(playlistId: contentId)
                let metadata = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
                playlist.title = (metadata?["title"] as? [String: Any])?["content"] as? String
                // サムネイル
                let contentImage = (lockup["contentImage"] as? [String: Any])?["collectionThumbnailViewModel"] as? [String: Any]
                    ?? (lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
                let sources = ((contentImage?["primaryThumbnail"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any])?["image"] as? [String: Any]
                    ?? (contentImage?["image"] as? [String: Any])
                if let thumbSources = sources?["sources"] as? [[String: Any]] {
                    for s in thumbSources {
                        if let urlStr = s["url"] as? String, let url = URL(string: urlStr) {
                            let w = s["width"] as? Int ?? 0
                            let h = s["height"] as? Int ?? 0
                            playlist.thumbnails.append(.init(width: w, height: h, url: url))
                        }
                    }
                }
                playlists.append(playlist)
            }

            // gridPlaylistRenderer 形式（旧UI）
            if let gridPlaylist = content["gridPlaylistRenderer"] as? [String: Any],
               let playlistId = gridPlaylist["playlistId"] as? String {
                var playlist = YTPlaylist(playlistId: playlistId)
                let titleRuns = (gridPlaylist["title"] as? [String: Any])?["runs"] as? [[String: Any]]
                playlist.title = titleRuns?.compactMap({ $0["text"] as? String }).joined()
                    ?? (gridPlaylist["title"] as? [String: Any])?["simpleText"] as? String
                playlist.videoCount = (gridPlaylist["videoCountShortText"] as? [String: Any])?["simpleText"] as? String
                if let thumbs = (gridPlaylist["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] {
                    for t in thumbs {
                        if let urlStr = t["url"] as? String, let url = URL(string: urlStr) {
                            let w = t["width"] as? Int ?? 0
                            let h = t["height"] as? Int ?? 0
                            playlist.thumbnails.append(.init(width: w, height: h, url: url))
                        }
                    }
                }
                playlists.append(playlist)
            }
        }
        return playlists
    }
}

// MARK: - Innertube account_menu によるアカウント情報取得

extension AccountClient {

    /// Innertube /account/account_menu (WEB client) でアカウント名・ハンドル・アバターを取得する。
    private static func fetchInfoViaInnertube(cookies: String) async throws -> AccountInfo {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/account/account_menu?key=AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w&prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("2.20241201.01.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        ContentClient.applyAuth(to: &request)

        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB",
                "clientVersion": "2.20241201.01.00",
                "hl": "ja",
                "gl": "JP"
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: sessionConfig)
        let (data, _) = try await session.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AccountInfo(name: nil, handle: nil, avatarURL: nil)
        }

        let actions = json["actions"] as? [[String: Any]]
        let popup = (actions?.first?["openPopupAction"] as? [String: Any])?["popup"] as? [String: Any]
        let menuHeader = (popup?["multiPageMenuRenderer"] as? [String: Any])?["header"] as? [String: Any]
        let renderer = menuHeader?["activeAccountHeaderRenderer"] as? [String: Any]

        let name = (renderer?["accountName"] as? [String: Any])?["simpleText"] as? String
        let handle = (renderer?["channelHandle"] as? [String: Any])?["simpleText"] as? String
        let photos = (renderer?["accountPhoto"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let avatarURL = (photos?.last?["url"] as? String).flatMap { URL(string: $0) }

        return AccountInfo(name: name, handle: handle, avatarURL: avatarURL)
    }
}
