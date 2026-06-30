//
//  PlaylistDetailView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import YouTubeKit

@MainActor
@Observable
final class PlaylistDetailViewModel {
    var videos: [VideoItem] = []
    var isLoading = true
    var error: Error?

    private let accountClient: AccountClient

    init(accountClient: AccountClient = .live) {
        self.accountClient = accountClient
    }

    func load(playlistId: String) async {
        do {
            videos = try await accountClient.fetchPlaylistVideos(playlistId)
        } catch {
            self.error = error
        }
        isLoading = false
    }

    /// プレイリストから動画を削除する
    func remove(video: VideoItem, from playlistId: String) async {
        guard let setVideoId = video.setVideoId else { return }
        // プレイリストIDからVLプレフィックスを除去
        let rawPlaylistId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        do {
            try await ContentClient.removeFromPlaylist(
                playlistId: rawPlaylistId,
                videoId: video.videoId,
                setVideoId: setVideoId
            )
            videos.removeAll { $0.videoId == video.videoId && $0.setVideoId == setVideoId }
        } catch {
            strixLog("プレイリスト削除エラー: \(error)")
        }
    }
}

struct PlaylistDetailView: View {
    let playlist: YTPlaylist

    @State private var vm = PlaylistDetailViewModel()
    @Environment(PlayerCoordinator.self) private var playerCoordinator

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.error {
                ContentUnavailableView(
                    "読み込みエラー",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            } else if vm.videos.isEmpty {
                ContentUnavailableView(
                    "動画がありません",
                    systemImage: "play.slash"
                )
            } else {
                List {
                    // 全曲再生ボタン
                    if let first = vm.videos.first {
                        Button {
                            playerCoordinator.play(
                                videoID: first.videoId,
                                playlistQueue: vm.videos,
                                initialIndex: 0
                            )
                        } label: {
                            Label("すべて再生", systemImage: "play.fill")
                        }
                    }

                    ForEach(Array(vm.videos.enumerated()), id: \.element.id) { index, video in
                        VideoRowView(video: video)
                            .videoRowInteraction(
                                video: video,
                                onRemoveFromPlaylist: {
                                    Task {
                                        await vm.remove(video: video, from: playlist.playlistId)
                                    }
                                }
                            ) {
                                playerCoordinator.play(
                                    videoID: video.videoId,
                                    playlistQueue: vm.videos,
                                    initialIndex: index
                                )
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.title ?? "プレイリスト")
        .navigationBarTitleDisplayMode(.large)
        .task { await vm.load(playlistId: playlist.playlistId) }
    }
}
