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
/// 戻り値は YouTubeKit の YTVideo に依存しない VideoItem に統一している。
struct ContentClient {
    var fetchHome: () async throws -> [VideoItem]
    var search: (String) async throws -> [VideoItem]
    var fetchRelated: (String) async throws -> [VideoItem]
}

// MARK: - モック（テスト用）

extension ContentClient {
    /// テスト時に各クロージャを差し替えて挙動を制御できるモッククライアント
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

                // ログイン済みの場合は Innertube WEB Browse API でパーソナライズドフィードを取得する。
                // SAPISIDHASH 署名を付与することで認証済みレスポンスを得られる。
                if let c = cookies, !c.isEmpty {
                    if let items = try? await ContentClient.browseHome(cookies: c), !items.isEmpty {
                        return items
                    }
                }

                // 未ログイン、または Browse API が空を返した場合は YouTubeKit にフォールバック
                model.cookies = cookies ?? ""
                let (response, _) = await HomeScreenResponse.sendRequest(
                    youtubeModel: model,
                    data: [:]
                )
                let homeVideos = (response?.results ?? [])
                    .compactMap { $0 as? YTVideo }
                    .map { $0.toVideoItem }
                if !homeVideos.isEmpty { return homeVideos }

                // 最終フォールバック: トレンド検索で代替
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

// MARK: - Innertube WEB Browse API（パーソナライズドホームフィード）

extension ContentClient {

    /// SAPISIDHASH 署名ヘッダーを計算する。
    /// 算出式: SAPISIDHASH {timestamp}_{SHA1("{timestamp} {SAPISID} {origin}")}
    private static func sapisidhash(from cookieString: String) -> String? {
        // SAPISID / __Secure-3PAPISID のいずれかを取り出す
        let pairs = cookieString.components(separatedBy: "; ")
        var sapisid: String?
        for name in ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"] {
            if let pair = pairs.first(where: { $0.hasPrefix("\(name)=") }) {
                sapisid = String(pair.dropFirst("\(name)=".count))
                break
            }
        }
        guard let sapisid else { return nil }

        let origin = "https://www.youtube.com"
        let ts = Int(Date().timeIntervalSince1970)
        let payload = "\(ts) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "SAPISIDHASH \(ts)_\(hash)"
    }

    /// Innertube WEB クライアントで /browse を叩いてホームフィードを取得する。
    /// Cookie + Authorization（SAPISIDHASH）ヘッダーにより認証済みレスポンスを受け取る。
    private static func browseHome(cookies: String) async throws -> [VideoItem] {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json",             forHTTPHeaderField: "Content-Type")
        req.setValue("1",                            forHTTPHeaderField: "X-Youtube-Client-Name")
        req.setValue("2.20240101.09.00",             forHTTPHeaderField: "X-Youtube-Client-Version")
        req.setValue("https://www.youtube.com",      forHTTPHeaderField: "X-Origin")
        req.setValue("https://www.youtube.com/",     forHTTPHeaderField: "Referer")
        req.setValue(cookies,                        forHTTPHeaderField: "Cookie")
        if let hash = sapisidhash(from: cookies) {
            req.setValue(hash, forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "browseId": "FEwhat_to_watch",
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20240101.09.00",
                    "hl": "ja",
                    "gl": "JP",
                    "timeZone": "Asia/Tokyo",
                    "utcOffsetMinutes": 540
                ]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parseBrowseVideos(from: json)
    }

    /// browse レスポンスの JSON から VideoItem 配列を抽出する。
    /// パス: contents.twoColumnBrowseResultsRenderer.tabs[0]
    ///       .tabRenderer.content.richGridRenderer.contents[].richItemRenderer.content.videoRenderer
    private static func parseBrowseVideos(from json: [String: Any]) -> [VideoItem] {
        guard
            let contents  = json["contents"] as? [String: Any],
            let twoCol    = contents["twoColumnBrowseResultsRenderer"] as? [String: Any],
            let tabs      = twoCol["tabs"] as? [[String: Any]],
            let firstTab  = tabs.first,
            let tabRdr    = firstTab["tabRenderer"] as? [String: Any],
            let content   = tabRdr["content"] as? [String: Any],
            let richGrid  = content["richGridRenderer"] as? [String: Any],
            let items     = richGrid["contents"] as? [[String: Any]]
        else { return [] }

        return items.compactMap { item -> VideoItem? in
            guard
                let richItem = item["richItemRenderer"] as? [String: Any],
                let content  = richItem["content"] as? [String: Any],
                let vr       = content["videoRenderer"] as? [String: Any]
            else { return nil }
            return parseVideoRenderer(vr)
        }
    }

    /// videoRenderer オブジェクト一件から VideoItem を生成する
    private static func parseVideoRenderer(_ vr: [String: Any]) -> VideoItem? {
        guard let videoId = vr["videoId"] as? String else { return nil }

        // タイトル: title.runs[0].text
        let title = ((vr["title"] as? [String: Any])?["runs"] as? [[String: Any]])?
            .first?["text"] as? String ?? videoId

        // サムネイル: 最後（最高解像度）を使う
        let thumbs = (vr["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = (thumbs?.last?["url"] as? String).flatMap { URL(string: $0) }

        // チャンネル名: ownerText.runs[0].text
        let channelName = ((vr["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]])?
            .first?["text"] as? String

        // チャンネルアバター（ネストが深いため段階的に取り出す）
        let chThumb = vr["channelThumbnailSupportedRenderers"] as? [String: Any]
        let chThumbLink = chThumb?["channelThumbnailWithLinkRenderer"] as? [String: Any]
        let chThumbObj = chThumbLink?["thumbnail"] as? [String: Any]
        let chThumbs = chThumbObj?["thumbnails"] as? [[String: Any]]
        let avatarURL = (chThumbs?.last?["url"] as? String).flatMap { URL(string: $0) }

        // 視聴回数: shortViewCountText.simpleText
        let viewCount = (vr["shortViewCountText"] as? [String: Any])?["simpleText"] as? String

        // 投稿日時: publishedTimeText.simpleText
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
}
