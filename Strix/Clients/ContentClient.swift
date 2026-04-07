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

// MARK: - Innertube WEB Browse API（パーソナライズドホームフィード）

extension ContentClient {

    /// SAPISIDHASH 署名ヘッダーを計算する
    private static func sapisidhash(from cookieString: String) -> String? {
        let pairs = cookieString.components(separatedBy: "; ")
        var sapisid: String?
        for name in ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"] {
            if let pair = pairs.first(where: { $0.hasPrefix("\(name)=") }) {
                sapisid = String(pair.dropFirst("\(name)=".count))
                break
            }
        }
        guard let sapisid else {
            strixLog(" SAPISID が見つかりません。クッキーキー: \(cookieString.components(separatedBy: "; ").map { $0.components(separatedBy: "=").first ?? "" }.joined(separator: ", "))")
            return nil
        }
        let origin = "https://www.youtube.com"
        let ts = Int(Date().timeIntervalSince1970)
        let payload = "\(ts) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "SAPISIDHASH \(ts)_\(hash)"
    }

    /// Innertube IOS クライアントで /browse を叩いてホームフィードを取得する。
    /// WEB クライアントは SAPISIDHASH が効かず空フィードになるため、
    /// プレイヤーと同じ IOS クライアントを使用する。
    private static func browseHome(cookies: String) async throws -> [VideoItem] {
        // クッキーキー一覧をログ（値は出さない）
        let cookieKeys = cookies.components(separatedBy: "; ")
            .compactMap { $0.components(separatedBy: "=").first }
        strixLog(" クッキーキー(\(cookieKeys.count)): \(cookieKeys.joined(separator: ", "))")

        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // プレイヤーエンドポイントと同じ IOS クライアントヘッダーを使う
        req.setValue(
            "com.google.ios.youtube/21.13.6 (iPhone16,2; U; CPU iOS 26_4 like Mac OS X;)",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("5",       forHTTPHeaderField: "X-Youtube-Client-Name")
        req.setValue("21.13.6", forHTTPHeaderField: "X-Youtube-Client-Version")
        req.setValue(cookies,   forHTTPHeaderField: "Cookie")

        let body: [String: Any] = [
            "browseId": "FEwhat_to_watch",
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "21.13.6",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iPhone",
                    "osVersion": "26.4.23E246",
                    "hl": "ja",
                    "gl": "JP"
                ]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        strixLog(" browseHome HTTP \(statusCode), レスポンスサイズ: \(data.count) bytes")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            strixLog(" browseHome: JSON パース失敗")
            return []
        }

        // エラーレスポンスチェック
        if let error = json["error"] as? [String: Any] {
            strixLog(" browseHome API エラー: \(error["message"] ?? error)")
        }

        // 構造診断: トップレベルキーと実際に存在する Renderer 種類をログ出力する
        strixLog(" browseHome トップレベルキー: \(json.keys.sorted().joined(separator: ", "))")
        let rendererTypes = findAllRendererKeys(in: json)
        strixLog(" browseHome Renderer 種類(\(rendererTypes.count)): \(rendererTypes.sorted().prefix(30).joined(separator: ", "))")

        // alerts があれば表示（ログイン要求など）
        if let alerts = json["alerts"] as? [[String: Any]] {
            strixLog(" browseHome alerts: \(alerts.first ?? [:])")
        }

        // レスポンス内の全 videoRenderer を再帰的に抽出する
        let videos = findVideoRenderers(in: json)
        strixLog(" browseHome: videoRenderer \(videos.count) 件発見")
        return videos.compactMap { parseVideoRenderer($0) }
    }

    /// JSON ツリーを再帰的に探索して "Renderer" で終わるキーを全て収集する（構造診断用）
    private static func findAllRendererKeys(in json: Any) -> Set<String> {
        var result = Set<String>()
        if let dict = json as? [String: Any] {
            for key in dict.keys where key.hasSuffix("Renderer") {
                result.insert(key)
            }
            for value in dict.values {
                result.formUnion(findAllRendererKeys(in: value))
            }
        } else if let array = json as? [Any] {
            for element in array {
                result.formUnion(findAllRendererKeys(in: element))
            }
        }
        return result
    }

    /// JSON ツリーを再帰的に探索して動画 Renderer を全て抽出する。
    /// WEB → videoRenderer / IOS → compactVideoRenderer の両方を対象にする。
    private static func findVideoRenderers(in json: Any) -> [[String: Any]] {
        if let dict = json as? [String: Any] {
            if let vr = dict["videoRenderer"] as? [String: Any] {
                return [vr]
            }
            if let vr = dict["compactVideoRenderer"] as? [String: Any] {
                return [vr]
            }
            return dict.values.flatMap { findVideoRenderers(in: $0) }
        } else if let array = json as? [Any] {
            return array.flatMap { findVideoRenderers(in: $0) }
        }
        return []
    }

    /// videoRenderer / compactVideoRenderer オブジェクト一件から VideoItem を生成する
    private static func parseVideoRenderer(_ vr: [String: Any]) -> VideoItem? {
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
}
