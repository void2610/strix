//
//  HistoryView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import YouTubeKit

@Observable
final class HistoryViewModel {
    var blocks: [HistoryResponse.HistoryBlock] = []
    var isLoading = true
    var error: Error?

    private let accountClient: AccountClient

    init(accountClient: AccountClient = .live) {
        self.accountClient = accountClient
    }

    func load() async {
        do {
            let response = try await accountClient.fetchHistory()
            blocks = response.videosAndTime
        } catch {
            self.error = error
        }
        isLoading = false
    }
}

struct HistoryView: View {
    @State private var vm = HistoryViewModel()

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
            } else if vm.blocks.isEmpty {
                ContentUnavailableView(
                    "視聴履歴がありません",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                List {
                    ForEach(vm.blocks) { block in
                        Section(block.groupTitle) {
                            ForEach(block.videosArray) { entry in
                                NavigationLink(value: entry.video.videoId) {
                                    VideoRowView(video: entry.video.toVideoItem)
                                }
                                .buttonStyle(.plain)
                            }
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
