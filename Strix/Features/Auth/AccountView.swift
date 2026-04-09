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

@Observable
final class AccountViewModel {
    var accountInfo: AccountInfo?
    var library: AccountLibraryResponse?
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
        library = nil
        await load()
    }

    private func loadInfo() async {
        accountInfo = try? await accountClient.fetchInfo()
    }

    private func loadLibrary() async {
        library = try? await accountClient.fetchLibrary()
    }
}

// MARK: - View

/// アカウントタブ。未ログイン時はログイン促進UI、ログイン済み時はアカウント情報を表示する。
struct AccountView: View {
    @State private var vm = AccountViewModel()
    @State private var showLogin = false
    @State private var showLog = false
    private let authState = AuthState.shared

    var body: some View {
        NavigationStack {
            if authState.isSignedIn {
                signedInView
            } else {
                signedOutView
            }
        }
    }

    // MARK: - ログイン済み画面

    private var signedInView: some View {
        List {
            accountHeaderSection
            librarySection
            playlistSection
            signOutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("アカウント")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: String.self) { videoID in
            PlayerView(videoID: videoID)
        }
        .refreshable { await vm.reload() }
        .sheet(isPresented: $showLog) { LogView() }
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
                    playlist: vm.library?.watchLater
                        ?? YTPlaylist(playlistId: "VLWL", title: "後で見る")
                )
            } label: {
                playlistLabel(
                    title: "後で見る",
                    systemImage: "bookmark.fill",
                    count: vm.library?.watchLater?.videoCount
                )
            }

            NavigationLink {
                PlaylistDetailView(
                    playlist: vm.library?.likes
                        ?? YTPlaylist(playlistId: "VLLL", title: "いいねした動画")
                )
            } label: {
                playlistLabel(
                    title: "いいねした動画",
                    systemImage: "hand.thumbsup.fill",
                    count: vm.library?.likes?.videoCount
                )
            }
        }
    }

    // MARK: - プレイリスト一覧

    @ViewBuilder
    private var playlistSection: some View {
        let playlists = vm.library?.playlists ?? []
        if !playlists.isEmpty {
            Section("プレイリスト") {
                ForEach(playlists, id: \.playlistId) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        playlistRow(playlist: playlist)
                    }
                }
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
