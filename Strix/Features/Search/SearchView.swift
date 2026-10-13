//
//  SearchView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import SwiftData

@Observable
final class SearchViewModel {
    var results: [VideoItem] = []
    var suggestions: [String] = []
    var isLoading = false
    var isLoadingMore = false
    var error: String?
    var lastQuery = ""
    var continuationToken: String?

    /// ショートだけのページが続くことがあるため、1 回の追加読み込みで試すページ数の上限
    static let maxEmptyPagesPerLoad = 5

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
        suggestions = []
        continuationToken = nil
        do {
            (results, continuationToken) = try await client.search(q)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// 検索結果の次ページを読み込む。動画が 0 件のページは上限まで飛ばして次を試す。
    func loadMore() async {
        guard let token = continuationToken, !isLoadingMore, !isLoading else { return }
        let query = lastQuery
        isLoadingMore = true
        defer { isLoadingMore = false }
        var currentToken: String? = token
        for _ in 0..<Self.maxEmptyPagesPerLoad {
            guard let t = currentToken else { break }
            do {
                let (videos, nextToken) = try await client.searchPage(t)
                // 読み込み中に別の検索が始まったら結果を捨てる
                guard query == lastQuery else { return }
                let known = Set(results.map(\.videoId))
                let newVideos = videos.filter { !known.contains($0.videoId) }
                results.append(contentsOf: newVideos)
                continuationToken = nextToken
                if !newVideos.isEmpty { return }
                currentToken = nextToken
            } catch {
                strixLog("検索結果の次ページ取得エラー: \(error.localizedDescription)")
                return
            }
        }
    }

    /// 入力に応じてサジェストを更新する。`.task(id:)` から呼ばれ、入力変更で自動キャンセルされる。
    /// 先頭の sleep がデバウンスを兼ねる（連続入力中はキャンセルされ通信が走らない）。
    func loadSuggestions(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { suggestions = []; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let list = (try? await client.searchSuggestions(q)) ?? []
        guard !Task.isCancelled else { return }
        suggestions = list
    }

    func reset() {
        results = []
        suggestions = []
        lastQuery = ""
        continuationToken = nil
        error = nil
    }
}

struct SearchView: View {
    @State private var vm = SearchViewModel()
    @State private var query = ""
    @State private var path = NavigationPath()
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerCoordinator.self) private var playerCoordinator
    @Query(sort: \SearchHistory.searchedAt, order: .reverse)
    private var searchHistory: [SearchHistory]

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
                } else if !vm.results.isEmpty {
                    resultsList
                } else if !searchHistory.isEmpty {
                    historyList
                } else {
                    ContentUnavailableView(
                        "動画を検索",
                        systemImage: "magnifyingglass",
                        description: Text("キーワードを入力してください")
                    )
                }
            }
            .navigationTitle("検索")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "動画を検索")
            .searchSuggestions {
                ForEach(vm.suggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "magnifyingglass")
                        .searchCompletion(suggestion)
                }
            }
            .onSubmit(of: .search) {
                Task {
                    await vm.search(query)
                    saveSearchHistory(query)
                }
            }
            .task(id: query) {
                await vm.loadSuggestions(query)
            }
            .onChange(of: query) { _, new in
                if new.isEmpty { vm.reset() }
            }
            .navigationDestination(for: ChannelDestination.self) { dest in
                ChannelView(channelId: dest.channelId)
            }
        }
        .onChange(of: playerCoordinator.pendingChannelNavigation) { _, dest in
            guard let dest, playerCoordinator.selectedTab == 1 else { return }
            playerCoordinator.pendingChannelNavigation = nil
            path.append(dest)
        }
    }

    // MARK: - 検索履歴リスト

    private var historyList: some View {
        List {
            Section {
                ForEach(searchHistory) { entry in
                    Button {
                        query = entry.query
                        Task { await vm.search(entry.query) }
                        saveSearchHistory(entry.query)
                    } label: {
                        Label(entry.query, systemImage: "clock.arrow.circlepath")
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete(perform: deleteHistory)
            } header: {
                HStack {
                    Text("検索履歴")
                    Spacer()
                    if searchHistory.count > 1 {
                        Button("すべて削除") {
                            clearAllHistory()
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 検索結果リスト

    private var resultsList: some View {
        List {
            ForEach(vm.results) { video in
                VideoRowView(video: video)
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .videoRowInteraction(video: video) {
                        playerCoordinator.play(video)
                    }
                    .onAppear {
                        if video.videoId == vm.results.last?.videoId {
                            Task { await vm.loadMore() }
                        }
                    }
            }
            if vm.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 検索履歴の永続化

    /// 検索クエリを履歴に保存する（重複時は日時を更新）
    private func saveSearchHistory(_ rawQuery: String) {
        let q = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }

        let targetQuery = q
        var descriptor = FetchDescriptor<SearchHistory>(
            predicate: #Predicate { $0.query == targetQuery }
        )
        descriptor.fetchLimit = 1

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.searchedAt = .now
        } else {
            modelContext.insert(SearchHistory(query: q))
        }
    }

    /// 指定されたインデックスの履歴を削除する
    private func deleteHistory(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(searchHistory[index])
        }
    }

    /// すべての検索履歴を削除する
    private func clearAllHistory() {
        for entry in searchHistory {
            modelContext.delete(entry)
        }
    }
}
