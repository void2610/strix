//
//  VideoItem.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import YouTubeKit

// VideoItem.swift - YTVideo.title は String? (YouTubeKit 1.3.0)

/// ホーム・検索・関連動画で共通して使う軽量動画モデル。
/// YTVideo（YouTubeKit）と Innertube 直叩きレスポンスの両方をここに統一する。
struct VideoItem: Identifiable, Equatable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let channelId: String?
    let channelName: String?
    let thumbnailURL: URL?
    let channelAvatarURL: URL?
    let viewCountText: String?
    let timePostedText: String?
    /// ミックスリスト・プレイリストの場合のプレイリストID
    let playlistId: String?
    /// 「興味なし」等のフィードバック用トークン（ホームフィードで付与される）
    let feedbackTokens: [String]
    /// プレイリスト内エントリ固有ID（プレイリストからの削除に必要）
    let setVideoId: String?

    init(videoId: String, title: String, channelId: String? = nil, channelName: String? = nil,
         thumbnailURL: URL? = nil, channelAvatarURL: URL? = nil,
         viewCountText: String? = nil, timePostedText: String? = nil, playlistId: String? = nil,
         feedbackTokens: [String] = [], setVideoId: String? = nil) {
        self.videoId = videoId
        self.title = title
        self.channelId = channelId
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.channelAvatarURL = channelAvatarURL
        self.viewCountText = viewCountText
        self.timePostedText = timePostedText
        self.playlistId = playlistId
        self.feedbackTokens = feedbackTokens
        self.setVideoId = setVideoId
    }
}

// MARK: - YTVideo → VideoItem 変換

extension YTVideo {
    /// YouTubeKit の YTVideo を VideoItem に変換する。
    /// title は AttributedString? のため NSAttributedString 経由で平文に変換する。
    var toVideoItem: VideoItem {
        return VideoItem(
            videoId: videoId,
            title: title ?? videoId,
            channelId: channel?.channelId,
            channelName: channel?.name,
            thumbnailURL: thumbnails.last?.url,
            channelAvatarURL: channel?.thumbnails.last?.url,
            viewCountText: viewCount,
            timePostedText: timePosted
        )
    }
}
