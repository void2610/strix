//
//  ContentClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import YouTubeKit

/// YouTubeKit 経由でホームフィード・検索・関連動画を取得するクライアント
struct ContentClient {
    var fetchHome: () async throws -> [YTVideo]
    var search: (String) async throws -> [YTVideo]
    var fetchRelated: (String) async throws -> [YTVideo]
}

extension ContentClient {
    /// テスト用モッククライアント。各クロージャを差し替えて挙動を制御できる。
    static func mock(
        fetchHome: @escaping () async throws -> [YTVideo] = { [] },
        search: @escaping (String) async throws -> [YTVideo] = { _ in [] },
        fetchRelated: @escaping (String) async throws -> [YTVideo] = { _ in [] }
    ) -> ContentClient {
        ContentClient(fetchHome: fetchHome, search: search, fetchRelated: fetchRelated)
    }

    static let live: ContentClient = {
        let model = YouTubeModel()
        return ContentClient(
            fetchHome: {
                // ログインなしではホームフィードが空になるため、
                // 動画が取れた場合はそれを使い、空の場合はトレンド検索にフォールバック
                let (response, _) = await HomeScreenResponse.sendRequest(
                    youtubeModel: model,
                    data: [:]
                )
                let homeVideos = (response?.results ?? []).compactMap { $0 as? YTVideo }
                if !homeVideos.isEmpty { return homeVideos }

                // フォールバック: 人気動画を検索で代替
                let (searchResponse, searchError) = await SearchResponse.sendRequest(
                    youtubeModel: model,
                    data: [.query: "trending music 2025"]
                )
                if let searchError { throw searchError }
                return (searchResponse?.results ?? []).compactMap { $0 as? YTVideo }
            },
            search: { query in
                let (response, error) = await SearchResponse.sendRequest(
                    youtubeModel: model,
                    data: [.query: query]
                )
                if let error { throw error }
                return (response?.results ?? []).compactMap { $0 as? YTVideo }
            },
            fetchRelated: { videoID in
                let (response, error) = await MoreVideoInfosResponse.sendRequest(
                    youtubeModel: model,
                    data: [.query: videoID]
                )
                if let error { throw error }
                return (response?.recommendedVideos ?? []).compactMap { $0 as? YTVideo }
            }
        )
    }()
}
