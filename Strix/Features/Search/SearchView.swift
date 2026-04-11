//
//  SearchView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI

@Observable
final class SearchViewModel {
    var results: [VideoItem] = []
    var isLoading = false
    var error: String?
    var lastQuery = ""

    private let client: ContentClient

    init(client: ContentClient = .live) {
        self.client = client
    }

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q != lastQuery else { return }
        lastQuery = q
        isLoading = true
        error = nil
        results = []
        do {
            results = try await client.search(q)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func reset() {
        results = []
        lastQuery = ""
        error = nil
    }
}

struct SearchView: View {
    @State private var vm = SearchViewModel()
    @State private var query = ""
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if vm.isLoading {
                    ProgressView("検索中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = vm.error {
                    ContentUnavailableView(
                        "検索に失敗しました",
                        systemImage: "wifi.exclamationmark",
                        description: Text(error)
                    )
                } else if vm.results.isEmpty && !vm.lastQuery.isEmpty {
                    ContentUnavailableView.search(text: vm.lastQuery)
                } else if vm.results.isEmpty {
                    // 検索前の初期状態
                    ContentUnavailableView(
                        "動画を検索",
                        systemImage: "magnifyingglass",
                        description: Text("キーワードを入力してください")
                    )
                } else {
                    resultsList
                }
            }
            .navigationTitle("検索")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "動画を検索")
            .onSubmit(of: .search) {
                Task { await vm.search(query) }
            }
            .onChange(of: query) { _, new in
                if new.isEmpty { vm.reset() }
            }
            .navigationDestination(for: String.self) { videoID in
                PlayerView(videoID: videoID)
            }
            .navigationDestination(for: ChannelDestination.self) { dest in
                ChannelView(channelId: dest.channelId)
            }
        }
    }

    private var resultsList: some View {
        List(vm.results) { video in
            Button {
                path.append(video.videoId)
            } label: {
                VideoRowView(video: video)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
        .listStyle(.plain)
    }
}
