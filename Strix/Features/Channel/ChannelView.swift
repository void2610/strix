//
//  ChannelView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/11.
//

import SwiftUI
import NukeUI
import YouTubeKit

// MARK: - ViewModel

@MainActor
@Observable
final class ChannelViewModel {
    var channelInfo: ChannelInfo?
    var selectedTab: ChannelTab = .home
    var tabVideos: [ChannelTab: [VideoItem]] = [:]
    var tabContinuations: [ChannelTab: String?] = [:]
    var playlists: [ChannelPlaylistItem] = []
    var isLoading = true
    var isLoadingTab = false
    var isLoadingMore = false
    var error: String?

    private let contentClient: ContentClient

    init(contentClient: ContentClient = .live) {
        self.contentClient = contentClient
    }

    /// チャンネルヘッダー + 初期タブ（ホーム）を読み込む
    func load(channelId: String) async {
        do {
            async let infoTask = contentClient.fetchChannel(channelId)
            async let homeTask = contentClient.fetchChannelTab(channelId, .home)
            let info = try await infoTask
            let (homeVideos, homeContinuation) = try await homeTask
            channelInfo = info
            tabVideos[.home] = homeVideos
            tabContinuations[.home] = homeContinuation
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// タブ切り替え時にコンテンツを取得
    func selectTab(_ tab: ChannelTab) async {
        selectedTab = tab
        guard let channelId = channelInfo?.channelId else { return }

        // 再生リストタブは専用ロジック
        if tab == .playlists {
            if !playlists.isEmpty { return }
            isLoadingTab = true
            playlists = (try? await contentClient.fetchChannelPlaylists(channelId)) ?? []
            isLoadingTab = false
            return
        }

        // 既にデータがあればスキップ
        if tabVideos[tab] != nil { return }
        isLoadingTab = true
        do {
            let (videos, continuation) = try await contentClient.fetchChannelTab(channelId, tab)
            tabVideos[tab] = videos
            tabContinuations[tab] = continuation
        } catch {
            tabVideos[tab] = []
        }
        isLoadingTab = false
    }

    /// 現在のタブの次ページを読み込む
    func loadMore() async {
        guard let continuation = tabContinuations[selectedTab] as? String,
              !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let (newVideos, nextToken) = try await contentClient.fetchChannelTabPage(continuation)
            tabVideos[selectedTab, default: []].append(contentsOf: newVideos)
            tabContinuations[selectedTab] = nextToken
        } catch {
            tabContinuations[selectedTab] = nil
        }
        isLoadingMore = false
    }

    /// 現在のタブの動画リスト
    var currentVideos: [VideoItem] {
        tabVideos[selectedTab] ?? []
    }

    /// 現在のタブに次ページがあるか
    var hasMore: Bool {
        if let token = tabContinuations[selectedTab] {
            return token != nil
        }
        return false
    }
}

// MARK: - ナビゲーション用の型

struct ChannelDestination: Hashable {
    let channelId: String
}

// MARK: - View

struct ChannelView: View {
    let channelId: String

    @State private var vm = ChannelViewModel()

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.error {
                ContentUnavailableView(
                    "読み込みエラー",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let info = vm.channelInfo {
                channelContent(info: info)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(channelId: channelId) }
    }

    // MARK: - チャンネルコンテンツ

    private func channelContent(info: ChannelInfo) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // バナー
                bannerSection(info: info)

                // チャンネルヘッダー
                channelHeader(info: info)

                // タブ切り替え
                tabPicker

                Divider()

                // タブコンテンツ
                tabContent
            }
        }
    }

    // MARK: - タブ切り替え

    private var tabPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ChannelTab.allCases, id: \.self) { tab in
                    Button {
                        Task { await vm.selectTab(tab) }
                    } label: {
                        Text(tab.rawValue)
                            .font(.subheadline)
                            .fontWeight(vm.selectedTab == tab ? .semibold : .regular)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                vm.selectedTab == tab
                                    ? Color.primary.opacity(0.1)
                                    : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - タブコンテンツ

    @ViewBuilder
    private var tabContent: some View {
        if vm.isLoadingTab {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if vm.selectedTab == .playlists {
            playlistsContent
        } else if vm.currentVideos.isEmpty {
            ContentUnavailableView(
                "コンテンツがありません",
                systemImage: "play.slash"
            )
            .padding(.top, 40)
        } else {
            ForEach(vm.currentVideos) { video in
                NavigationLink(value: video.videoId) {
                    VideoCardView(video: video)
                }
                .buttonStyle(.plain)

                Divider()
            }

            // ページネーション
            if vm.hasMore || vm.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .onAppear {
                        Task { await vm.loadMore() }
                    }
            }
        }
    }

    // MARK: - 再生リスト一覧

    @ViewBuilder
    private var playlistsContent: some View {
        if vm.playlists.isEmpty {
            ContentUnavailableView(
                "再生リストがありません",
                systemImage: "list.and.film"
            )
            .padding(.top, 40)
        } else {
            ForEach(vm.playlists) { playlist in
                NavigationLink {
                    PlaylistDetailView(
                        playlist: YTPlaylist(playlistId: playlist.playlistId, title: playlist.title)
                    )
                } label: {
                    playlistRow(playlist: playlist)
                }
                .buttonStyle(.plain)

                Divider()
            }
        }
    }

    private func playlistRow(playlist: ChannelPlaylistItem) -> some View {
        HStack(spacing: 12) {
            // サムネイル
            if let url = playlist.thumbnailURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.secondarySystemBackground))
                    }
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 160, height: 90)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                if let count = playlist.videoCount {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - バナー

    @ViewBuilder
    private func bannerSection(info: ChannelInfo) -> some View {
        if let bannerURL = info.bannerURL {
            LazyImage(url: bannerURL) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .aspectRatio(6.2, contentMode: .fit)
            .clipped()
        }
    }

    // MARK: - チャンネルヘッダー

    private func channelHeader(info: ChannelInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let avatarURL = info.avatarURL {
                LazyImage(url: avatarURL) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Circle().fill(Color(.secondarySystemBackground))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(info.name ?? "チャンネル")
                    .font(.title3.bold())
                    .lineLimit(2)

                let meta = [info.handle, info.subscriberCount, info.videoCount]
                    .compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
