//
//  YouTubeClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/07.
//

import Foundation
import YouTubeKit

/// YouTubeKit（Innertube API）を使って動画ストリーム情報を取得するクライアント
struct YouTubeClient {
    /// 動画 ID からストリーム URL とタイトルを取得する
    var fetchVideo: (String) async throws -> VideoInfo
}

/// 動画のストリーム情報
struct VideoInfo {
    let streamURL: URL
    let title: String
    let thumbnailURL: String
}

enum YouTubeClientError: LocalizedError {
    case streamNotFound
    case invalidVideoID

    var errorDescription: String? {
        switch self {
        case .streamNotFound: return "ストリーム URL が見つかりませんでした"
        case .invalidVideoID: return "無効な動画 ID です"
        }
    }
}

extension YouTubeClient {
    static let live = YouTubeClient(
        fetchVideo: { videoID in
            let youtubeModel = YouTubeModel()

            // 動画情報を Innertube API から取得
            let (videoInfos, error) = await VideoInfosResponse.sendRequest(
                youTubeModel: youtubeModel,
                data: [.query: videoID]
            )

            if let error { throw error }
            guard let videoInfos else { throw YouTubeClientError.streamNotFound }

            // 音声付き動画ストリームの中から最高画質を選択
            guard let streamURL = videoInfos.streamingURL else {
                throw YouTubeClientError.streamNotFound
            }

            let title = videoInfos.channel?.name ?? videoID
            let thumbnailURL = videoInfos.thumbnails?.first?.url?.absoluteString ?? ""

            return VideoInfo(streamURL: streamURL, title: title, thumbnailURL: thumbnailURL)
        }
    )
}
