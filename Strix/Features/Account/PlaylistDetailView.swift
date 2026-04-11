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
}

struct PlaylistDetailView: View {
    let playlist: YTPlaylist

    @State private var vm = PlaylistDetailViewModel()

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
                        NavigationLink {
                            PlayerView(
                                videoID: first.videoId,
                                playlistQueue: vm.videos,
                                initialIndex: 0
                            )
                        } label: {
                            Label("すべて再生", systemImage: "play.fill")
                        }
                    }

                    ForEach(Array(vm.videos.enumerated()), id: \.element.id) { index, video in
                        NavigationLink {
                            PlayerView(
                                videoID: video.videoId,
                                playlistQueue: vm.videos,
                                initialIndex: index
                            )
                        } label: {
                            VideoRowView(video: video)
                        }
                        .buttonStyle(.plain)
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
