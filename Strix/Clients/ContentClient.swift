//
//  ContentClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import CryptoKit
import YouTubeKit

/// ホームフィード・検索・関連動画を取得するクライアント。
/// 戻り値は VideoItem に統一している。
struct ContentClient {
    var fetchHome: () async throws -> ([VideoItem], String?)
    var fetchHomePage: (String) async throws -> ([VideoItem], String?)
    var fetchHistoryVideos: () async throws -> [VideoItem]
    var fetchPlaylistVideos: (String) async throws -> [VideoItem]
    var search: (String) async throws -> [VideoItem]
    var fetchRelated: (String) async throws -> [VideoItem]
}

// MARK: - モック（テスト用）

extension ContentClient {
    static func mock(
        fetchHome: @escaping () async throws -> ([VideoItem], String?) = { ([], nil) },
        fetchHomePage: @escaping (String) async throws -> ([VideoItem], String?) = { _ in ([], nil) },
        fetchHistoryVideos: @escaping () async throws -> [VideoItem] = { [] },
        fetchPlaylistVideos: @escaping (String) async throws -> [VideoItem] = { _ in [] },
        search: @escaping (String) async throws -> [VideoItem] = { _ in [] },
        fetchRelated: @escaping (String) async throws -> [VideoItem] = { _ in [] }
    ) -> ContentClient {
        ContentClient(fetchHome: fetchHome, fetchHomePage: fetchHomePage, fetchHistoryVideos: fetchHistoryVideos, fetchPlaylistVideos: fetchPlaylistVideos, search: search, fetchRelated: fetchRelated)
    }
}

// MARK: - 本番クライアント

extension ContentClient {
    static let live: ContentClient = {
        let model = YouTubeModel()
        return ContentClient(
            fetchHome: {
                let cookies = AuthState.shared.cookieString ?? ""
                guard !cookies.isEmpty else { return ([], nil) }
                return try await ContentClient.fetchBrowseViaInnertubeAPI(browseId: "FEwhat_to_watch", cookies: cookies)
            },
            fetchHomePage: { continuation in
                let cookies = AuthState.shared.cookieString ?? ""
                guard !cookies.isEmpty else { return ([], nil) }
                return try await ContentClient.fetchHomeNextPageViaInnertubeAPI(cookies: cookies, continuation: continuation)
            },
            fetchHistoryVideos: {
                let cookies = AuthState.shared.cookieString ?? ""
                guard !cookies.isEmpty else { return [] }
                let (videos, _) = try await ContentClient.fetchBrowseViaInnertubeAPI(browseId: "FEhistory", cookies: cookies)
                return videos
            },
            fetchPlaylistVideos: { playlistId in
                let cookies = AuthState.shared.cookieString ?? ""
                guard !cookies.isEmpty else { return [] }
                let candidateBrowseIds: [String] = {
                    if playlistId.hasPrefix("VL"), playlistId.count > 2 {
                        return [playlistId, String(playlistId.dropFirst(2))]
                    } else {
                        return [playlistId]
                    }
                }()

                for browseId in candidateBrowseIds {
                    let (initialVideos, initialToken) = try await ContentClient.fetchBrowseViaInnertubeAPI(browseId: browseId, cookies: cookies)
                    if !initialVideos.isEmpty { return initialVideos }

                    var continuation = initialToken
                    while let token = continuation {
                        let (videos, nextToken) = try await ContentClient.fetchBrowseContinuationViaInnertubeAPI(cookies: cookies, continuation: token)
                        if !videos.isEmpty { return videos }
                        continuation = nextToken
                    }
                }
                return []
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
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("2.20241201.01.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        if !cookies.isEmpty {
            let deduped = deduplicateCookies(cookies)
            request.setValue(deduped, forHTTPHeaderField: "Cookie")
            if let auth = buildSapisidHash(from: deduped) {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
            // YouTube 認証に必須のヘッダー（これがないと logged_in:0 になる）
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
        }

        // VISITOR_INFO1_LIVE から visitorData を取得してコンテキストに含める
        let visitorData = deduplicateCookies(cookies)
            .components(separatedBy: "; ")
            .first(where: { $0.hasPrefix("VISITOR_INFO1_LIVE=") })
            .map { String($0.dropFirst("VISITOR_INFO1_LIVE=".count)) }

        var clientContext: [String: Any] = [
            "clientName": "WEB",
            "clientVersion": "2.20241201.01.00",
            "hl": "ja",
            "gl": "JP"
        ]
        if let vd = visitorData, !vd.isEmpty {
            clientContext["visitorData"] = vd
        }

        let body: [String: Any] = [
            "browseId": browseId,
            "context": ["client": clientContext]
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
    private static func fetchBrowseContinuationViaInnertubeAPI(cookies: String, continuation: String) async throws -> ([VideoItem], String?) {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
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
        if !cookies.isEmpty {
            let deduped = deduplicateCookies(cookies)
            request.setValue(deduped, forHTTPHeaderField: "Cookie")
            if let auth = buildSapisidHash(from: deduped) {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
}
        let visitorData = deduplicateCookies(cookies)
            .components(separatedBy: "; ")
            .first(where: { $0.hasPrefix("VISITOR_INFO1_LIVE=") })
            .map { String($0.dropFirst("VISITOR_INFO1_LIVE=".count)) }

        var clientContext: [String: Any] = [
            "clientName": "WEB",
            "clientVersion": "2.20241201.01.00",
            "hl": "ja",
            "gl": "JP"
        ]
        if let vd = visitorData, !vd.isEmpty {
            clientContext["visitorData"] = vd
        }

        let body: [String: Any] = [
            "continuation": continuation,
            "context": ["client": clientContext]
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
        let videoInfoRuns = (vr["videoInfo"] as? [String: Any])?["runs"] as? [[String: Any]]
        let viewCount = (vr["shortViewCountText"] as? [String: Any])?["simpleText"] as? String
            ?? videoInfoRuns?.first?["text"] as? String
        let timePosted = (vr["publishedTimeText"] as? [String: Any])?["simpleText"] as? String
            ?? videoInfoRuns?.dropFirst().first(where: { ($0["text"] as? String) != " • " })?["text"] as? String

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

    /// WEB 新形式 lockupViewModel から VideoItem を生成する。
    ///
    /// 主要パス:
    ///   videoId    : contentId
    ///   title      : metadata.lockupMetadataViewModel.title.content
    ///   thumbnail  : contentImage.thumbnailViewModel.image.sources[last].url
    ///   channelName: metadata.lockupMetadataViewModel.metadata.contentMetadataViewModel.metadataRows[0]
    ///   avatar     : metadata.lockupMetadataViewModel.image.sources[last].url
    static func parseLockupViewModel(_ lvm: [String: Any]) -> VideoItem? {
        guard let videoId = lvm["contentId"] as? String else { return nil }

        let lmvm = (lvm["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]

        // タイトル
        let title = (lmvm?["title"] as? [String: Any])?["content"] as? String ?? videoId

        // サムネイル: contentImage.thumbnailViewModel.image.sources[last].url
        let ciTvm = (lvm["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
        let thumbSrcs = (ciTvm?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
        let thumbnailURL = (thumbSrcs?.last?["url"] as? String).flatMap { URL(string: $0) }

        // チャンネル名: contentMetadataViewModel.metadataRows の先頭 title
        var channelName: String?
        if let cmvm = (lmvm?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any],
           let rows = cmvm["metadataRows"] as? [[String: Any]],
           let firstRow = rows.first,
           let rvm = firstRow["metadataRowViewModel"] as? [String: Any] {
            channelName = (rvm["title"] as? [String: Any])?["content"] as? String
                ?? (rvm["subTitle"] as? [String: Any])?["content"] as? String
        }

        // チャンネルアバター: metadata.lockupMetadataViewModel.image.sources[last].url
        let avatarSrcs = (lmvm?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
        let channelAvatarURL = (avatarSrcs?.last?["url"] as? String).flatMap { URL(string: $0) }

        return VideoItem(
            videoId: videoId,
            title: title,
            channelName: channelName,
            thumbnailURL: thumbnailURL,
            channelAvatarURL: channelAvatarURL,
            viewCountText: nil,
            timePostedText: nil
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
