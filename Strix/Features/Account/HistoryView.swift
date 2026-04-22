//
//  HistoryView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI

@MainActor
@Observable
final class HistoryViewModel {
    var videos: [VideoItem] = []
    var isLoading = true
    var error: Error?

    private let contentClient: ContentClient

    init(contentClient: ContentClient = .live) {
        self.contentClient = contentClient
    }

    func load() async {
        do {
            videos = try await contentClient.fetchHistoryVideos()
        } catch {
            self.error = error
        }
        isLoading = false
    }
}

struct HistoryView: View {
    @State private var vm = HistoryViewModel()
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
                    "視聴履歴がありません",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                List {
                    ForEach(vm.videos) { video in
                        // List 内で Button + .contextMenu だと長押しが Button に吸われて効かないため、
                        // contentShape + onTapGesture でタップ領域を確保する
                        VideoRowView(video: video)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playerCoordinator.play(videoID: video.videoId)
                            }
                            .contextMenu {
                                VideoContextMenu(video: video)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("視聴履歴")
        .navigationBarTitleDisplayMode(.large)
        .task { await vm.load() }
    }
}
