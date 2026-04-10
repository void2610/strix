//
//  HomeView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import SwiftData
import YouTubeKit
import NukeUI

// MARK: - ViewModel

@Observable
final class HomeViewModel {
    var videos: [VideoItem] = []
    var quickPlaylists: [YTPlaylist] = []
    var isLoading = false
    var isLoadingMore = false
    var error: String?
    var continuationToken: String?

    private let client: ContentClient
    private let accountClient: AccountClient
    /// ロード世代カウンター。reload() のたびにインクリメントし、
    /// 古い世代のタスクが結果を書き込むのを防ぐ。
    private var loadGeneration = 0

    init(client: ContentClient = .live, accountClient: AccountClient = .live) {
        self.client = client
        self.accountClient = accountClient
    }

    func load() async {
        guard videos.isEmpty, !isLoading else { return }
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        error = nil
        defer { isLoading = false }
        async let feedTask: Void = loadFeed(generation: gen)
        async let playlistTask: Void = loadQuickPlaylists(generation: gen)
        _ = await (feedTask, playlistTask)
    }

    func reload() async {
        loadGeneration += 1  // 進行中のロードを世代で無効化
        isLoading = false
        isLoadingMore = false
        videos = []
        quickPlaylists = []
        continuationToken = nil
        await load()
    }

    func loadMore() async {
        guard let token = continuationToken, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // 動画が0件でも continuation token が続く場合があるためループして取得する
        var currentToken: String? = token
        while let t = currentToken {
            do {
                let (newVideos, nextToken) = try await client.fetchHomePage(t)
                strixLog("loadMore 成功 \(newVideos.count)件")
                videos.append(contentsOf: newVideos)
                continuationToken = nextToken
                if !newVideos.isEmpty { return }  // 取得できたので完了
                currentToken = nextToken           // 0件なら次のページを試みる
            } catch {
                strixLog("loadMore エラー: \(error)")
                return
            }
        }
    }

    private func loadFeed(generation: Int) async {
        strixLog("loadFeed 開始 gen=\(generation) current=\(loadGeneration)")
        do {
            let (result, token) = try await client.fetchHome()
            strixLog("loadFeed 成功 \(result.count)件 gen=\(generation) current=\(loadGeneration)")
            guard generation == loadGeneration else {
                strixLog("loadFeed 破棄（世代不一致）")
                return
            }
            videos = result
            continuationToken = token
        } catch {
            strixLog("loadFeed エラー: \(error) gen=\(generation) current=\(loadGeneration) cancelled=\(Task.isCancelled)")
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadQuickPlaylists(generation: Int) async {
        guard AuthState.shared.isSignedIn else { return }
        guard let library = try? await accountClient.fetchLibrary() else { return }
        guard generation == loadGeneration else { return }
        var items: [YTPlaylist] = []
        if let wl = library.watchLater { items.append(wl) }
        if let likes = library.likes { items.append(likes) }
        items.append(contentsOf: library.playlists)
        quickPlaylists = items
    }
}

// MARK: - View

struct HomeView: View {
    @State private var vm = HomeViewModel()
    @State private var path = NavigationPath()
    @Query(sort: \WatchedVideo.watchedAt, order: .reverse) private var history: [WatchedVideo]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // プレイリストクイックアクセス（ログイン済みかつデータあり）
                    if !vm.quickPlaylists.isEmpty {
                        playlistQuickAccessSection
                    }

                    // 視聴履歴（ある場合）
                    if !history.isEmpty {
                        historySection
                    }

                    Divider()
                        .padding(.vertical, 8)

                    // ホームフィード
                    if vm.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let error = vm.error {
                        ContentUnavailableView(
                            "読み込みに失敗しました",
                            systemImage: "wifi.exclamationmark",
                            description: Text(error)
                        )
                        .padding(.top, 40)
                    } else {
                        sectionHeader("おすすめ")
                        feedSection
                    }
                }
            }
            .navigationTitle("Strix")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                // SwiftUI が refreshable タスクをキャンセルすると URLSession も -999 で失敗するため、
                // 非構造化タスクで reload を実行してキャンセル伝播を切り離す
                let task = Task { await vm.reload() }
                await task.value
            }
            .navigationDestination(for: String.self) { videoID in
                PlayerView(videoID: videoID)
            }
        }
        .task(id: AuthState.shared.isSignedIn) {
            await vm.reload()
        }
    }

    // MARK: - プレイリストクイックアクセス

    private var playlistQuickAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("プレイリスト")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(vm.quickPlaylists, id: \.playlistId) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            PlaylistCircleItem(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 視聴履歴

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("最近再生した動画")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(history.prefix(10)) { video in
                        Button { path.append(video.videoID) } label: {
                            HistoryThumbnailView(video: video)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - フィード

    private var feedSection: some View {
        LazyVStack(spacing: 0) {
            ForEach(vm.videos) { video in
                Button {
                    path.append(video.videoId)
                } label: {
                    VideoCardView(video: video)
                }
                .buttonStyle(.plain)

                Divider()
            }

            // 末尾まで来たら次ページを自動読み込み
            if vm.continuationToken != nil || vm.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .onAppear {
                        Task { await vm.loadMore() }
                    }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - プレイリストクイックアクセスアイテム

private struct PlaylistCircleItem: View {
    let playlist: YTPlaylist

    /// プレイリスト ID に対応するシステムアイコン
    private var systemIcon: String? {
        switch playlist.playlistId {
        case "VLWL": return "bookmark.fill"
        case "VLLL": return "hand.thumbsup.fill"
        default:     return nil
        }
    }

    private var thumbnailURL: URL? {
        playlist.thumbnails.last?.url
            ?? playlist.frontVideos.first?.thumbnails.last?.url
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // サムネイル or システムアイコン
                if let url = thumbnailURL {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            circlePlaceholder
                        }
                    }
                } else {
                    circlePlaceholder
                }

                // 後で見る・いいねはアイコンオーバーレイ
                if let icon = systemIcon {
                    Circle()
                        .fill(.black.opacity(0.4))
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(.separator), lineWidth: 0.5))

            Text(playlist.title ?? "プレイリスト")
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 72)
        }
    }

    private var circlePlaceholder: some View {
        Circle().fill(Color(.secondarySystemBackground))
    }
}

// MARK: - 視聴履歴サムネイル

private struct HistoryThumbnailView: View {
    let video: WatchedVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: URL(string: video.thumbnailURL)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.secondarySystemBackground)
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(video.title)
                .font(.caption)
                .lineLimit(2)
                .frame(width: 120, alignment: .leading)
        }
    }
}
