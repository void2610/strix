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

    init(videoID: String, title: String, thumbnailURL: String, watchedAt: Date = .now) {
        self.videoID = videoID
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.watchedAt = watchedAt
    }
}
