//
//  PinnedPlaylist.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/11.
//

import Foundation
import SwiftData

/// ホーム画面のクイックアクセスに表示するプレイリストの選択状態を保存するモデル。
/// YouTube アカウントとは独立してアプリローカルに保存される。
@Model
final class PinnedPlaylist {
    @Attribute(.unique) var playlistId: String
    var sortOrder: Int

    init(playlistId: String, sortOrder: Int = 0) {
        self.playlistId = playlistId
        self.sortOrder = sortOrder
    }
}
