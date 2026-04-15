//
//  CommentItem.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/14.
//

import Foundation

/// コメント1件分のデータ
struct CommentItem: Identifiable {
    let id: String
    let authorName: String
    let authorAvatarURL: URL?
    let contentText: String
    let publishedTimeText: String?
    let likeCountText: String?
    let replyCount: Int
}
