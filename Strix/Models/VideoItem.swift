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
struct VideoItem: Identifiable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let channelName: String?
    let thumbnailURL: URL?
    let channelAvatarURL: URL?
    let viewCountText: String?
    let timePostedText: String?
}

// MARK: - YTVideo → VideoItem 変換

extension YTVideo {
    /// YouTubeKit の YTVideo を VideoItem に変換する。
    /// title は AttributedString? のため NSAttributedString 経由で平文に変換する。
    var toVideoItem: VideoItem {
        return VideoItem(
            videoId: videoId,
            title: title ?? videoId,
            channelName: channel?.name,
            thumbnailURL: thumbnails.last?.url,
            channelAvatarURL: channel?.thumbnails.last?.url,
            viewCountText: viewCount,
            timePostedText: timePosted
        )
    }
}
