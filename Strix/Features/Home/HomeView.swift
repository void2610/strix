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

@MainActor
@Observable
final class HomeViewModel {
    var videos: [VideoItem] = []
    var quickPlaylists: [YTPlaylist] = []
    /// 編集画面用の全プレイリスト（フィルタリング前）
    var allPlaylists: [YTPlaylist] = []
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

    func load(modelContext: ModelContext) async {
        guard videos.isEmpty, !isLoading else { return }
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        error = nil
        defer { isLoading = false }
        async let feedTask: Void = loadFeed(generation: gen)
        async let playlistTask: Void = loadQuickPlaylists(generation: gen, modelContext: modelContext)
        _ = await (feedTask, playlistTask)
    }

    func reload(modelContext: ModelContext) async {
        loadGeneration += 1
        isLoading = false
        isLoadingMore = false
        videos = []
        quickPlaylists = []
        allPlaylists = []
        continuationToken = nil
        await load(modelContext: modelContext)
    }

    /// PinnedPlaylist の変更後にネットワーク通信なしで再フィルタリングする
    func refilterPlaylists(modelContext: ModelContext) {
        let hasCustomized = UserDefaults.standard.bool(forKey: "hasCustomizedHomePlaylists")
        if hasCustomized {
            let descriptor = FetchDescriptor<PinnedPlaylist>(sortBy: [SortDescriptor(\.sortOrder)])
            let pinned = (try? modelContext.fetch(descriptor)) ?? []
            let pinnedIds = Set(pinned.map(\.playlistId))
            quickPlaylists = allPlaylists.filter { pinnedIds.contains($0.playlistId) }
        } else {
            quickPlaylists = allPlaylists
        }
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
                strixLog("ホームフィード次ページ取得エラー: \(error.localizedDescription)")
                return
            }
        }
    }

    private func loadFeed(generation: Int) async {
        guard !UserDefaults.standard.bool(forKey: "disableRecommendations") else { return }
        strixLog("loadFeed 開始 gen=\(generation) current=\(loadGeneration)")
        do {
            let (result, token) = try await client.fetchHome()
            strixLog("loadFeed 成功 \(result.count)件 gen=\(generation) current=\(loadGeneration)")
            guard generation == loadGeneration else { return }
            videos = result
            continuationToken = token
        } catch {
            strixLog("loadFeed エラー: \(error) gen=\(generation) current=\(loadGeneration) cancelled=\(Task.isCancelled)")
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadQuickPlaylists(generation: Int, modelContext: ModelContext) async {
        guard AuthState.shared.isSignedIn else { return }
        guard let library = try? await accountClient.fetchLibrary() else { return }
        guard generation == loadGeneration else { return }
        var items: [YTPlaylist] = []
        if let wl = library.watchLater { items.append(wl) }
        if let likes = library.likes { items.append(likes) }
        items.append(contentsOf: library.playlists)
        allPlaylists = items
        refilterPlaylists(modelContext: modelContext)
    }

}

// MARK: - View

struct HomeView: View {
    @State private var vm = HomeViewModel()
    @State private var path = NavigationPath()
    @State private var showPlaylistEdit = false
    @AppStorage("disableRecommendations") private var disableRecommendations = false
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerCoordinator.self) private var playerCoordinator

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // プレイリストクイックアクセス（ログイン済みかつデータあり）
                    if !vm.quickPlaylists.isEmpty {
                        playlistQuickAccessSection
                    }

                    Divider()

                    // ホームフィード
                    if disableRecommendations {
                        ContentUnavailableView(
                            "ホームフィードはオフです",
                            systemImage: "eye.slash",
                            description: Text("おすすめ動画の表示は設定で無効にされています")
                        )
                        .padding(.top, 40)
                    } else if vm.isLoading {
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
                        feedSection
                    }
                }
            }
            .navigationTitle("Strix")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                // SwiftUI が refreshable タスクをキャンセルすると URLSession も -999 で失敗するため、
                // 非構造化タスクで reload を実行してキャンセル伝播を切り離す
                let ctx = modelContext
                let task = Task { await vm.reload(modelContext: ctx) }
                await task.value
            }
            .sheet(isPresented: $showPlaylistEdit) {
                HomePlaylistEditView(allPlaylists: vm.allPlaylists) {
                    vm.refilterPlaylists(modelContext: modelContext)
                }
            }
            .navigationDestination(for: ChannelDestination.self) { dest in
                ChannelView(channelId: dest.channelId)
            }
        }
        .onChange(of: playerCoordinator.pendingChannelNavigation) { _, dest in
            guard let dest, playerCoordinator.selectedTab == 0 else { return }
            playerCoordinator.pendingChannelNavigation = nil
            path.append(dest)
        }
        .task(id: AuthState.shared.isSignedIn) {
            await vm.reload(modelContext: modelContext)
        }
    }

    // MARK: - プレイリストクイックアクセス

    private var playlistQuickAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button { showPlaylistEdit = true } label: {
                    Image(systemName: "pencil")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 16)
            }

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
        .padding(.bottom, 4)
    }

    // MARK: - フィード

    private var feedSection: some View {
        LazyVStack(spacing: 0) {
            ForEach(vm.videos) { video in
                Group {
                    if let playlistId = video.playlistId {
                        // ミックスリスト・プレイリストはプレイリスト詳細へ
                        NavigationLink {
                            PlaylistDetailView(
                                playlist: YTPlaylist(playlistId: playlistId, title: video.title)
                            )
                        } label: {
                            VideoCardView(video: video)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            playerCoordinator.play(videoID: video.videoId)
                        } label: {
                            VideoCardView(video: video)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    VideoContextMenu(
                        video: video,
                        onDismiss: {
                            withAnimation {
                                vm.videos.removeAll { $0.videoId == video.videoId }
                            }
                        }
                    )
                }

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
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 72)
        }
    }

    private var circlePlaceholder: some View {
        Circle().fill(Color(.secondarySystemBackground))
    }
}

// MARK: - 視聴履歴サムネイル

private struct HistoryThumbnailView: View {
    let video: VideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LazyImage(url: video.thumbnailURL) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                }
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
