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

    @Environment(PlayerCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext

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

        // 再生リスト（プレイリスト）行はキュー操作の対象外
        if video.playlistId == nil {
            Button {
                coordinator.playNext(video)
            } label: {
                Label("次に再生", systemImage: "text.insert")
            }

            Button {
                coordinator.enqueue(video)
            } label: {
                Label("キューに追加", systemImage: "text.append")
            }
        }

        Button {
            Task { try? await ContentClient.addToWatchLater(videoId: video.videoId) }
        } label: {
            Label("後で見る", systemImage: "clock")
        }

        // ダウンロード（プレイリスト行は対象外）
        if video.playlistId == nil {
            downloadButton
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

    /// ダウンロード状態に応じてラベルを出し分けるボタン
    @ViewBuilder
    private var downloadButton: some View {
        let record = DownloadManager.record(for: video.videoId, in: modelContext)
        if record?.state == .completed {
            Button {} label: {
                Label("ダウンロード済み", systemImage: "arrow.down.circle.fill")
            }
            .disabled(true)
        } else if DownloadManager.shared.isDownloading(video.videoId) || record?.state == .downloading {
            Button {} label: {
                Label("ダウンロード中…", systemImage: "arrow.down.circle.dotted")
            }
            .disabled(true)
        } else {
            Button {
                DownloadManager.shared.startDownload(video: video, modelContext: modelContext)
            } label: {
                Label("ダウンロード", systemImage: "arrow.down.circle")
            }
        }
    }
}
