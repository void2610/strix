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
    var isLoadingMore = false
    var error: Error?
    var continuationToken: String?

    private let contentClient: ContentClient

    init(contentClient: ContentClient = .live) {
        self.contentClient = contentClient
    }

    func load() async {
        do {
            let (items, token) = try await contentClient.fetchHistoryVideos()
            videos = items
            continuationToken = token
        } catch {
            self.error = error
        }
        isLoading = false
    }

    func reload() async {
        isLoading = true
        isLoadingMore = false
        videos = []
        continuationToken = nil
        error = nil
        await load()
    }

    func loadMore() async {
        guard let token = continuationToken, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let (newVideos, nextToken) = try await contentClient.fetchHistoryPage(token)
            videos.append(contentsOf: newVideos)
            continuationToken = nextToken
        } catch {
            strixLog("視聴履歴次ページ取得エラー: \(error.localizedDescription)")
        }
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
                        VideoRowView(video: video)
                            .videoRowInteraction(video: video) {
                                playerCoordinator.play(video)
                            }
                    }

                    // 次ページ自動読み込み
                    if vm.continuationToken != nil || vm.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .onAppear {
                                Task { await vm.loadMore() }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("視聴履歴")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await vm.reload() }
        .task { await vm.load() }
    }
}
