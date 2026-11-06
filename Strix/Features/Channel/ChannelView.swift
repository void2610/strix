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
    var loadingTabs: Set<ChannelTab> = []
    var isLoadingMore = false
    var isTogglingSubscription = false
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
        await loadTab(tab)
    }

    /// タブの中身を、まだ持っていなければ取得する（選択は変えない）
    func loadTab(_ tab: ChannelTab) async {
        guard let channelId = channelInfo?.channelId, !loadingTabs.contains(tab) else { return }

        // 再生リストタブは専用ロジック
        if tab == .playlists {
            if !playlists.isEmpty { return }
            loadingTabs.insert(tab)
            playlists = (try? await contentClient.fetchChannelPlaylists(channelId)) ?? []
            loadingTabs.remove(tab)
            return
        }

        // 既にデータがあればスキップ
        if tabVideos[tab] != nil { return }
        loadingTabs.insert(tab)
        do {
            let (videos, continuation) = try await contentClient.fetchChannelTab(channelId, tab)
            tabVideos[tab] = videos
            tabContinuations[tab] = continuation
        } catch {
            strixLog("チャンネルタブ取得エラー: \(error.localizedDescription)")
            tabVideos[tab] = []
        }
        loadingTabs.remove(tab)
    }

    /// 隣のタブ（offset が正なら右隣）。端の先には無い
    func adjacentTab(_ offset: Int) -> ChannelTab? {
        let tabs = ChannelTab.allCases
        guard let index = tabs.firstIndex(of: selectedTab), tabs.indices.contains(index + offset) else { return nil }
        return tabs[index + offset]
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
            strixLog("チャンネル次ページ取得エラー: \(error.localizedDescription)")
            tabContinuations[selectedTab] = nil
        }
        isLoadingMore = false
    }

    /// チャンネル登録 ↔ 解除を切り替える（楽観的更新、失敗時はロールバック）
    func toggleSubscription() async {
        guard let info = channelInfo, !isTogglingSubscription else { return }
        isTogglingSubscription = true
        defer { isTogglingSubscription = false }
        let newState = !info.subscribed
        channelInfo?.subscribed = newState
        do {
            if newState {
                try await contentClient.subscribe(info.channelId)
            } else {
                try await contentClient.unsubscribe(info.channelId)
            }
        } catch {
            strixLog("チャンネル登録切替エラー: \(error.localizedDescription)")
            channelInfo?.subscribed = !newState
        }
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
    /// タブの中身を指に合わせて横にずらす量
    @State private var pageOffset: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    /// 選択中のタブの中身の高さ（隣のタブはこの高さで切り、スクロール量を変えない）
    @State private var currentPageHeight: CGFloat = 0
    /// タブ列の中での各タブの位置（下線の位置合わせに使う）
    @State private var tabFrames: [ChannelTab: CGRect] = [:]
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
                    description: Text(error)
                )
            } else if let info = vm.channelInfo {
                channelContent(info: info)
            }
        }
        // 公式アプリと同じく、ヘッダーが流れたあともどのチャンネルかをナビゲーションバーで示す
        .navigationTitle(vm.channelInfo?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        // 上端に残したタブ列の上へ中身が透けないようにする
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await vm.load(channelId: channelId) }
    }

    // MARK: - チャンネルコンテンツ

    private func channelContent(info: ChannelInfo) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // バナー
                bannerSection(info: info)

                // チャンネルヘッダー
                channelHeader(info: info)

                // タブ列はスクロールしても上端に残す
                Section {
                    // タブコンテンツ（左右の隣のタブも並べ、引いたときに続けて見せる）
                    pagedTabContent
                } header: {
                    tabPicker
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { pageWidth = $0 }
        .gesture(
            DirectionalPanGesture(
                direction: .horizontal,
                leadingEdgeInset: 24,
                onChange: { translation, _ in
                    if let next = vm.adjacentTab(translation < 0 ? 1 : -1) {
                        Task { await vm.loadTab(next) }
                    }
                    var t = Transaction()
                    t.disablesAnimations = true
                    // 隣のタブが無い向きには重く動かして、端であることを伝える
                    let hasNext = vm.adjacentTab(translation < 0 ? 1 : -1) != nil
                    withTransaction(t) { pageOffset = hasNext ? translation : translation / 3 }
                },
                onEnd: { translation, velocity in
                    let offset = translation < 0 ? 1 : -1
                    let flicked = abs(velocity) > 500 && (velocity < 0) == (translation < 0)
                    guard abs(translation) > pageWidth * 0.25 || flicked, let next = vm.adjacentTab(offset) else {
                        withAnimation(.spring(duration: 0.3)) { pageOffset = 0 }
                        return
                    }
                    switchPage(to: next, direction: CGFloat(offset))
                }
            )
        )
    }

    /// 並べてある隣のタブまで送り、送り終えたら選択を移して位置を戻す（見た目は変わらない）
    private func switchPage(to tab: ChannelTab, direction: CGFloat) {
        withAnimation(.easeOut(duration: 0.25)) {
            pageOffset = -direction * pageWidth
        } completion: {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                vm.selectedTab = tab
                pageOffset = 0
            }
        }
    }

    private var pagedTabContent: some View {
        let tabs = [vm.adjacentTab(-1), vm.selectedTab, vm.adjacentTab(1)]
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                if let tab {
                    let isCurrent = index == 1
                    LazyVStack(spacing: 0) { tabContent(tab, isCurrent: isCurrent) }
                        .frame(width: pageWidth)
                        .frame(height: isCurrent ? nil : currentPageHeight, alignment: .top)
                        .clipped()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                            if isCurrent { currentPageHeight = height }
                        }
                        .id(tab)
                } else {
                    Color.clear.frame(width: pageWidth, height: 1)
                }
            }
        }
        // 3 枚の真ん中を画面に合わせる
        .frame(width: pageWidth)
        .offset(x: pageOffset)
    }

    // MARK: - タブ切り替え

    private var tabPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(ChannelTab.allCases, id: \.self) { tab in
                        Button {
                            tapTab(tab)
                        } label: {
                            Text(tab.rawValue)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(tab == highlightedTab ? Color.primary : Color.secondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(tabBarSpace)) }) { tabFrames[tab] = $0 }
                        .id(tab)
                    }
                }
                .padding(.horizontal, 2)
                .coordinateSpace(.named(tabBarSpace))
                .overlay(alignment: .bottomLeading) { tabIndicator }
            }
            // スワイプで画面外のタブへ移ったときも選択中のタブを見せる
            .onChange(of: vm.selectedTab) { _, tab in
                withAnimation { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        // 下線を区切り線の上に重ねる
        .background(alignment: .bottom) { Divider() }
        .background(Color(.systemBackground))
    }

    private let tabBarSpace = "channelTabBar"

    /// 隣のタブは払ったときと同じく横に送り、離れたタブは下線だけ動かして中身を切り替える
    private func tapTab(_ tab: ChannelTab) {
        guard tab != vm.selectedTab else { return }
        Task { await vm.loadTab(tab) }
        if tab == vm.adjacentTab(1) {
            switchPage(to: tab, direction: 1)
        } else if tab == vm.adjacentTab(-1) {
            switchPage(to: tab, direction: -1)
        } else {
            withAnimation(.easeOut(duration: 0.25)) { vm.selectedTab = tab }
        }
    }

    /// 引いている量の割合（左へ引くと正）
    private var pageProgress: CGFloat {
        guard pageWidth > 0 else { return 0 }
        return -pageOffset / pageWidth
    }

    /// 下線が半分以上かかっているタブを、文字の強調にも使う
    private var highlightedTab: ChannelTab {
        guard abs(pageProgress) >= 0.5, let next = vm.adjacentTab(pageProgress > 0 ? 1 : -1) else { return vm.selectedTab }
        return next
    }

    /// 選択中のタブの下線。引いている間は隣のタブへ指に合わせて移る
    @ViewBuilder
    private var tabIndicator: some View {
        if let from = tabFrames[vm.selectedTab] {
            let to = vm.adjacentTab(pageProgress > 0 ? 1 : -1).flatMap { tabFrames[$0] } ?? from
            let t = min(abs(pageProgress), 1)
            let x = from.minX + (to.minX - from.minX) * t
            let width = from.width + (to.width - from.width) * t
            // 公式アプリと同じく、角のない線をタブの幅いっぱいに引く
            Rectangle()
                .fill(Color.primary)
                .frame(width: max(0, width), height: 2)
                .offset(x: x)
        }
    }

    // MARK: - タブコンテンツ

    @ViewBuilder
    private func tabContent(_ tab: ChannelTab, isCurrent: Bool) -> some View {
        let videos = vm.tabVideos[tab] ?? []
        if vm.loadingTabs.contains(tab) || (tab != .playlists && vm.tabVideos[tab] == nil) {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if tab == .playlists {
            playlistsContent
        } else if videos.isEmpty {
            ContentUnavailableView(
                "コンテンツがありません",
                systemImage: "play.slash"
            )
            .padding(.top, 40)
        } else {
            ForEach(videos) { video in
                if let playlistId = video.playlistId {
                    // プレイリストはプレイリスト詳細へ
                    NavigationLink {
                        PlaylistDetailView(
                            playlist: YTPlaylist(playlistId: playlistId, title: video.title)
                        )
                    } label: {
                        VideoCardView(video: video, showChannelLink: false)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let url = URL(string: "https://www.youtube.com/playlist?list=\(playlistId)") {
                            Button {
                                UIPasteboard.general.url = url
                            } label: {
                                Label("リンクをコピー", systemImage: "doc.on.doc")
                            }

                            ShareLink(item: url) {
                                Label("共有", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                } else {
                    VideoCardView(video: video, showChannelLink: false)
                        .videoRowInteraction(video: video) {
                            playerCoordinator.play(video)
                        }
                }

                Divider()
            }

            // ページネーション
            if isCurrent, vm.hasMore || vm.isLoadingMore {
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

                subscribeButton(info: info)
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func subscribeButton(info: ChannelInfo) -> some View {
        Button {
            Task { await vm.toggleSubscription() }
        } label: {
            Text(info.subscribed ? "登録済み" : "登録")
                .font(.subheadline.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .foregroundStyle(info.subscribed ? Color.primary : Color.white)
                .background(info.subscribed ? Color(.secondarySystemBackground) : Color.red, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isTogglingSubscription)
    }
}
