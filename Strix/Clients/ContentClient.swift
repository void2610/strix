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
    static let live: ContentClient = {
        let model = YouTubeModel()
        return ContentClient(
            fetchHome: {
                let (response, error) = await HomeScreenResponse.sendRequest(
                    youtubeModel: model,
                    data: [:]
                )
                if let error { throw error }
                return (response?.results ?? []).compactMap { $0 as? YTVideo }
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
