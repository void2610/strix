//
//  ContentClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
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
                    // ログイン済み: Innertube browse API でパーソナライズドフィード取得
                    do {
                        let items = try await ContentClient.fetchHomeViaInnertubeAPI(cookies: c)
                        strixLog(" fetchHomeViaInnertubeAPI: \(items.count) 件取得")
                        if !items.isEmpty { return items }
                        strixLog(" fetchHomeViaInnertubeAPI: 空のため YouTubeKit にフォールバック")
                    } catch {
                        strixLog(" fetchHomeViaInnertubeAPI エラー: \(error)")
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

                    strixLog(" ログイン済みフィード取得失敗: 空を返す")
                    return []
                }

                // 未ログイン: Innertube browse API（Cookie なし）
                do {
                    let items = try await ContentClient.fetchHomeViaInnertubeAPI(cookies: "")
                    strixLog(" 未ログイン fetchHomeViaInnertubeAPI: \(items.count) 件取得")
                    if !items.isEmpty { return items }
                } catch {
                    strixLog(" 未ログイン fetchHomeViaInnertubeAPI エラー: \(error)")
                }

                // 最終フォールバック: トレンド検索
                model.cookies = ""
                let (searchResponse, _) = await SearchResponse.sendRequest(
                    youtubeModel: model,
                    data: [.query: "trending music 2025"]
                )
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

// MARK: - Innertube browse API によるホームフィード取得

extension ContentClient {

    /// URLSession で Innertube /browse API を叩いてホームフィードを取得する。
    /// WEB クライアントを使うことで videoRenderer 形式のレスポンスが得られる。
    /// cookies が空の場合は未ログイン状態でリクエストする。
    private static func fetchHomeViaInnertubeAPI(cookies: String) async throws -> [VideoItem] {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("2.20241201.01.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        let body: [String: Any] = [
            "browseId": "FEwhat_to_watch",
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20241201.01.00",
                    "hl": "ja",
                    "gl": "JP"
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let videos = findVideoRenderers(in: json)
        return videos.compactMap { parseVideoRenderer($0) }
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

