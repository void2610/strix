//
//  WatchedVideo.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/07.
//

import Foundation
import SwiftData

/// 最近再生した動画の履歴を保存するモデル
@Model
final class WatchedVideo {
    var videoID: String
    var title: String
    var thumbnailURL: String
    var watchedAt: Date
    /// 再生位置（秒）。レジューム再生に使用
    var playbackPosition: Double = 0
    /// 動画の総再生時間（秒）。レジューム判定に使用
    var videoDuration: Double = 0

    init(videoID: String, title: String, thumbnailURL: String, watchedAt: Date = .now,
         playbackPosition: Double = 0, videoDuration: Double = 0) {
        self.videoID = videoID
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.watchedAt = watchedAt
        self.playbackPosition = playbackPosition
        self.videoDuration = videoDuration
    }
}
