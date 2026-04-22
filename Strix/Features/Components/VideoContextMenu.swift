//
//  VideoContextMenu.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/22.
//

import SwiftUI

/// 動画行に付ける共通コンテキストメニュー。
/// リンクコピー・共有・後で見る・プレイリストに追加を常設し、
/// 場所固有のアクション（興味なし・プレイリストから削除）はクロージャで注入する。
struct VideoContextMenu: View {
    let video: VideoItem
    /// 「興味なし」実行後の UI 更新（feedbackTokens を持つ動画のみ表示）
    var onDismiss: (() -> Void)? = nil
    /// 「プレイリストから削除」実行アクション（setVideoId を持ち、かつ注入された場合のみ表示）
    var onRemoveFromPlaylist: (() -> Void)? = nil

    var body: some View {
        // 興味なし（HomeView のおすすめ等 feedbackTokens がある動画でのみ表示）
        if let onDismiss, !video.feedbackTokens.isEmpty {
            Button(role: .destructive) {
                Task {
                    try? await ContentClient.sendFeedback(tokens: video.feedbackTokens)
                }
                onDismiss()
            } label: {
                Label("興味なし", systemImage: "hand.thumbsdown")
            }
        }

        if let url = URL(string: "https://youtu.be/\(video.videoId)") {
            Button {
                UIPasteboard.general.url = url
            } label: {
                Label("リンクをコピー", systemImage: "doc.on.doc")
            }

            ShareLink(item: url) {
                Label("共有", systemImage: "square.and.arrow.up")
            }
        }

        Divider()

        Button {
            Task { try? await ContentClient.addToWatchLater(videoId: video.videoId) }
        } label: {
            Label("後で見る", systemImage: "clock")
        }

        AddToPlaylistMenu(videoId: video.videoId)

        // プレイリスト詳細での削除（setVideoId が取れている場合のみ）
        if let onRemoveFromPlaylist, video.setVideoId != nil {
            Divider()
            Button(role: .destructive) {
                onRemoveFromPlaylist()
            } label: {
                Label("プレイリストから削除", systemImage: "trash")
            }
        }
    }
}
