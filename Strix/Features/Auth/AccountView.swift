//
//  AccountView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import YouTubeKit
import NukeUI

// MARK: - ViewModel

@MainActor
@Observable
final class AccountViewModel {
    var accountInfo: AccountInfo?
    var watchLater: YTPlaylist?
    var likes: YTPlaylist?
    var playlists: [YTPlaylist] = []
    var isLoading = false

    private let accountClient: AccountClient

    init(accountClient: AccountClient = .live) {
        self.accountClient = accountClient
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let infoTask: Void = loadInfo()
        async let libraryTask: Void = loadLibrary()
        _ = await (infoTask, libraryTask)
    }

    func reload() async {
        isLoading = false
        accountInfo = nil
        watchLater = nil
        likes = nil
        playlists = []
        await load()
    }

    private func loadInfo() async {
        accountInfo = try? await accountClient.fetchInfo()
    }

    private func loadLibrary() async {
        guard let library = try? await accountClient.fetchLibrary() else { return }
        watchLater = library.watchLater
        likes = library.likes
        playlists = library.playlists
    }

    /// プレイリストを自分のライブラリから削除する（楽観的 UI 更新）。
    /// 失敗時はサーバ側と乖離しないようリロードする。
    func deletePlaylist(_ playlist: YTPlaylist) async {
        let id = playlist.playlistId
        playlists.removeAll { $0.playlistId == id }
        do {
            try await ContentClient.deletePlaylist(playlistId: id)
        } catch {
            strixLog("プレイリスト削除エラー: \(error)")
            await reload()
        }
    }
}

// MARK: - View

/// アカウントタブ。未ログイン時はログイン促進UI、ログイン済み時はアカウント情報を表示する。
struct AccountView: View {
    @State private var vm = AccountViewModel()
    @State private var showLogin = false
    @State private var showLog = false
    @State private var path = NavigationPath()
    @State private var showDeleteAlert = false
    @State private var pendingDeletion: YTPlaylist?
    @Environment(PlayerCoordinator.self) private var playerCoordinator
    private let authState = AuthState.shared

    var body: some View {
        NavigationStack(path: $path) {
            if authState.isSignedIn {
                signedInView
            } else {
                signedOutView
            }
        }
        .onChange(of: playerCoordinator.pendingChannelNavigation) { _, dest in
            guard let dest, playerCoordinator.selectedTab == 2 else { return }
            playerCoordinator.pendingChannelNavigation = nil
            path.append(dest)
        }
    }

    // MARK: - ログイン済み画面

    private var signedInView: some View {
        List {
            accountHeaderSection
            librarySection
            playlistSection
            settingsSection
            signOutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("アカウント")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: ChannelDestination.self) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .refreshable { await vm.reload() }
        .sheet(isPresented: $showLog) { LogView() }
        .alert("プレイリストを削除", isPresented: $showDeleteAlert) {
            Button("削除", role: .destructive) {
                if let playlist = pendingDeletion {
                    Task { await vm.deletePlaylist(playlist) }
                }
                pendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("「\(pendingDeletion?.title ?? "プレイリスト")」を削除しますか？\nこの操作は取り消せません。")
        }
        .task { await vm.load() }
    }

    // MARK: - アカウントヘッダー

    private var accountHeaderSection: some View {
        Section {
            HStack(spacing: 14) {
                // アバター
                if let avatarURL = vm.accountInfo?.avatarURL {
                    LazyImage(url: avatarURL) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            Circle().fill(Color(.secondarySystemBackground))
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let name = vm.accountInfo?.name {
                        Text(name).font(.headline)
                    } else {
                        Text("YouTubeアカウント").font(.headline)
                    }
                    if let handle = vm.accountInfo?.handle {
                        Text(handle).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("ログイン済み").font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if vm.isLoading {
                    Spacer()
                    ProgressView()
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - ライブラリ（履歴・後で見る・いいね）

    private var librarySection: some View {
        Section("ライブラリ") {
            NavigationLink {
                HistoryView()
            } label: {
                Label("視聴履歴", systemImage: "clock.arrow.circlepath")
            }

            NavigationLink {
                PlaylistDetailView(
                    playlist: vm.watchLater
                        ?? YTPlaylist(playlistId: "VLWL", title: "後で見る")
                )
            } label: {
                playlistLabel(
                    title: "後で見る",
                    systemImage: "bookmark.fill",
                    count: vm.watchLater?.videoCount
                )
            }

            NavigationLink {
                PlaylistDetailView(
                    playlist: vm.likes
                        ?? YTPlaylist(playlistId: "VLLL", title: "いいねした動画")
                )
            } label: {
                playlistLabel(
                    title: "いいねした動画",
                    systemImage: "hand.thumbsup.fill",
                    count: vm.likes?.videoCount
                )
            }
        }
    }

    // MARK: - プレイリスト一覧

    private var playlistSection: some View {
        Section("プレイリスト") {
            if vm.playlists.isEmpty {
                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("プレイリストがありません")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(vm.playlists, id: \.playlistId) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        playlistRow(playlist: playlist)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeletion = playlist
                            showDeleteAlert = true
                        } label: {
                            Label("リストから削除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 設定

    @AppStorage("disableRecommendations") private var disableRecommendations = false

    private var settingsSection: some View {
        Section("設定") {
            Toggle(isOn: $disableRecommendations) {
                Label("おすすめを無効化", systemImage: "eye.slash")
            }
        }
    }

    // MARK: - ログアウト・デバッグ

    private var signOutSection: some View {
        Group {
            Section {
                Button(role: .destructive) {
                    authState.signOut()
                } label: {
                    Label("ログアウト", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            Section("デバッグ") {
                Button {
                    showLog = true
                } label: {
                    Label("デバッグログ", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
    }

    // MARK: - サブビュー

    private func playlistLabel(title: String, systemImage: String, count: String?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            if let count {
                Spacer()
                Text(count)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func playlistRow(playlist: YTPlaylist) -> some View {
        HStack(spacing: 12) {
            if let thumbURL = playlist.thumbnails.last?.url {
                LazyImage(url: thumbURL) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                    }
                }
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 56, height: 40)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title ?? "プレイリスト")
                    .font(.subheadline)
                    .lineLimit(2)
                if let count = playlist.videoCount {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 未ログイン画面

    private var signedOutView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("YouTubeにログイン")
                    .font(.title2.bold())
                Text("ログインするとあなたのおすすめ動画や\n視聴履歴に基づいたコンテンツが表示されます")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                showLogin = true
            } label: {
                Label("Googleでログイン", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)

            Spacer()
        }
        .navigationTitle("アカウント")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showLog = true } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $showLogin) { LoginView {} }
        .sheet(isPresented: $showLog) { LogView() }
    }
}
