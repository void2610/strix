//
//  PlayerView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import AVFoundation
import UIKit
import SwiftData
import NukeUI

struct PlayerView: View {
    let videoID: String
    /// 外部から注入される PlayerViewModel（PlayerContainerView が所有）
    var vm: PlayerViewModel

    @Environment(PlayerCoordinator.self) private var coordinator
    @AppStorage("disableRecommendations") private var disableRecommendations = false
    @State private var showBotVerify = false
    @State private var showFullDescription = false
    /// 動画の下の領域に開いているパネル（開いている間も動画は操作できる）
    @State private var panel: PlayerPanel?
    @State private var showQueue = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(videoID: String, vm: PlayerViewModel) {
        self.videoID = videoID
        self.vm = vm
    }

    var body: some View {
        VStack(spacing: 0) {
            // 動画プレイヤー（画面上部に固定、スクロールしない）
            // フルスクリーン時は画面全体に広げる
            playerSection
                .frame(maxWidth: .infinity, maxHeight: isFullScreen ? .infinity : nil)

            // 下部コンテンツ（動画の後ろをスクロール）。フルスクリーン中は非表示
            if !isFullScreen {
                ZStack(alignment: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // 再生キューインジケータ（N/M 表示。タップでキュー一覧を開く）
                            if !vm.playlistQueue.isEmpty, !vm.isLoadingStream, vm.streamError == nil {
                                Button {
                                    showQueue = true
                                } label: {
                                    HStack {
                                        Image(systemName: "list.and.film")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("再生キュー  \(vm.playlistIndex + 1)/\(vm.playlistQueue.count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }

                            if vm.isLoadingStream {
                                // ローディング中はタイトルスケルトン
                                skeletonTitle
                            } else if let info = vm.videoInfo {
                                // タイトル・チャンネル情報
                                videoMeta(info: info)
                            }

                            Divider()
                                .padding(.top, 8)

                            // コメント
                            commentsSection

                            Divider()
                                .padding(.top, 8)

                            // 関連動画
                            if disableRecommendations {
                                ContentUnavailableView(
                                    "関連動画はオフです",
                                    systemImage: "eye.slash",
                                    description: Text("おすすめ動画の表示は設定で無効にされています")
                                )
                                .padding(.top, 12)
                            } else {
                                relatedSection
                            }
                        }
                    }

                    if let panel {
                        PlayerPanelContainer(
                            title: panel.title,
                            subtitle: panel == .comments ? vm.commentCountText : nil,
                            edge: .bottom,
                            onClose: closePanel
                        ) {
                            panelContent(panel)
                        }
                        .transition(.move(edge: .bottom))
                        .zIndex(1)
                    }
                }
                .clipped()
            } // if !isFullScreen
        }
        // フルスクリーン中のチャプター一覧は、公式クライアントと同じく動画の右側に重ねる
        .overlay(alignment: .trailing) {
            if isFullScreen, panel == .chapters {
                PlayerPanelContainer(title: PlayerPanel.chapters.title, edge: .trailing, onClose: closePanel) {
                    panelContent(.chapters)
                }
                .frame(width: 360)
                .colorScheme(.dark)
                .transition(.move(edge: .trailing))
            }
        }
        .onChange(of: vm.loadedVideoID) { _, _ in
            closePanel()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                vm.savePlaybackPosition(modelContext: modelContext)
            }
        }
        .sheet(isPresented: $showBotVerify) {
            BotVerifyView {
                // 認証完了後にリトライ
                showBotVerify = false
                Task {
                    await vm.load(videoID: videoID, modelContext: modelContext)
                }
            }
        }
        .sheet(isPresented: $showQueue) {
            QueueSheet()
                .environment(coordinator)
        }
    }

    // MARK: - フルスクリーン切替

    /// プレイヤー内の ⛶ ボタンから呼ばれる。
    /// `coordinator.isFullScreen` を toggle し、PlayerContainerView / RootTabView 側で
    /// タブバー非表示・レイアウト切替を行う（Phase 2 の現段階では Coordinator に状態を持たせるのみ）。
    private func toggleFullScreen() {
        coordinator.isFullScreen.toggle()
        // iOS 16+ の UIWindowScene.requestGeometryUpdate で向きを強制する
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let orientations: UIInterfaceOrientationMask = coordinator.isFullScreen ? .landscape : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
        }
    }

    private var isFullScreen: Bool { coordinator.isFullScreen }

    /// 下へ払ったとみなす速さ（pt/秒）。これより速ければ短く引いただけでも最小化する
    private let minimizeFlickVelocity: CGFloat = 800

    // MARK: - プレイヤー

    private var playerSection: some View {
        Group {
            if vm.isLoadingStream {
                Color.black
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { ProgressView().tint(.white) }
            } else if vm.streamError != nil {
                Color.black
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 12) {
                            ContentUnavailableView(
                                "再生できません",
                                systemImage: "exclamationmark.triangle",
                                description: Text(vm.streamError?.localizedDescription ?? "")
                            )
                            if vm.isBotDetected {
                                Button {
                                    showBotVerify = true
                                } label: {
                                    Label("YouTubeで認証する", systemImage: "globe")
                                        .font(.subheadline.bold())
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(.white.opacity(0.2), in: Capsule())
                                }
                            }
                        }
                        .colorScheme(.dark)
                    }
            } else if vm.player != nil {
                CustomPlayerView(
                    videoID: videoID,
                    vm: vm,
                    onToggleFullScreen: { toggleFullScreen() },
                    isFullScreen: isFullScreen,
                    onShowChapters: { openPanel(.chapters) }
                )
                .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        // ボタンの上から引き始めても追従させ、全画面時は縦の操作を音量・明るさの調整に譲る
        .gesture(
            DirectionalPanGesture(
                direction: .down,
                isEnabled: !isFullScreen,
                onChange: { ty, _ in
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        coordinator.dragOffset = max(0, ty)
                    }
                },
                onEnd: { ty, vy in
                    let screenHeight = UIScreen.main.bounds.height
                    if ty > screenHeight * 0.15 || vy > minimizeFlickVelocity {
                        withAnimation(.easeOut(duration: 0.2)) {
                            coordinator.dragOffset = screenHeight
                        } completion: {
                            coordinator.dragOffset = 0
                            coordinator.minimize()
                        }
                    } else {
                        withAnimation(.snappy(duration: 0.25)) {
                            coordinator.dragOffset = 0
                        }
                    }
                }
            )
        )
    }

    // MARK: - タイトル・メタ情報

    private func videoMeta(info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // タイトル・視聴回数・説明文（タップで展開/折りたたみ）
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFullDescription.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    // タイトル
                    Text(info.title)
                        .font(.headline)
                        .lineLimit(showFullDescription ? nil : 2)
                        .multilineTextAlignment(.leading)

                    // 視聴回数・投稿日
                    if vm.viewCountText != nil || vm.publishDateText != nil {
                        let parts = [vm.viewCountText, vm.publishDateText].compactMap { $0 }
                        HStack(spacing: 4) {
                            Text(parts.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !showFullDescription {
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // 説明文（展開時のみ）
                    if showFullDescription, let desc = vm.videoDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        HStack {
                            Spacer()
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(showFullDescription ? Color(.secondarySystemBackground).opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, showFullDescription ? 8 : 0)
            }
            .buttonStyle(.plain)

            // 公式クライアントと同じく、チャプター一覧は説明欄を開いたときだけ出す
            if showFullDescription, !vm.chapters.isEmpty {
                chaptersSection
            }

            // チャンネル行（アバター + チャンネル名）
            if let channelName = info.channelName {
                channelRow(name: channelName, channelId: info.channelId)
            }

            actionRow
        }
    }

    // MARK: - 操作ボタン列（公式クライアントと同じく、評価・共有・保存・ダウンロードを横に並べる）

    private var actionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let like = vm.likeState {
                    ratingPill(like)
                }
                if let url = URL(string: "https://youtu.be/\(videoID)") {
                    ShareLink(item: url) {
                        actionChip("共有", systemImage: "arrowshape.turn.up.right")
                    }
                    .buttonStyle(.plain)
                }
                AddToPlaylistMenu(videoId: videoID) {
                    actionChip("保存", systemImage: "bookmark")
                }
                .buttonStyle(.plain)
                downloadChip
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 4)
    }

    /// 高評価（件数付き）と低評価を縦線で区切った 1 つのボタン
    private func ratingPill(_ like: LikeState) -> some View {
        HStack(spacing: 0) {
            Button {
                Task { await vm.toggleRating(.like) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: like.rating == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                    if let count = like.displayCountText {
                        Text(count)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }

            Rectangle()
                .fill(Color.primary.opacity(0.2))
                .frame(width: 1, height: 20)

            Button {
                Task { await vm.toggleRating(.dislike) }
            } label: {
                Image(systemName: like.rating == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .padding(.leading, 12)
                    .padding(.trailing, 14)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.medium))
        .frame(height: 36)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }

    @ViewBuilder
    private var downloadChip: some View {
        if let video = vm.currentVideoItem {
            let record = DownloadManager.record(for: video.videoId, in: modelContext)
            if let record, DownloadManager.isPlayableOffline(record) {
                actionChip("ダウンロード済み", systemImage: "checkmark.circle")
            } else if DownloadManager.shared.isDownloading(video.videoId) || record?.state == .downloading {
                actionChip("ダウンロード中", systemImage: "arrow.down.circle.dotted")
            } else {
                Button {
                    DownloadManager.shared.startDownload(video: video, modelContext: modelContext)
                } label: {
                    actionChip("ダウンロード", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actionChip(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }

    // MARK: - チャプター

    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("チャプター")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(vm.chapters) { chapter in
                        Button {
                            vm.seek(to: chapter.startSeconds)
                        } label: {
                            chapterCard(chapter)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
    }

    private func chapterCard(_ chapter: VideoChapter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ChapterThumbnail(url: chapter.thumbnailURL)
                .frame(width: 128, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    Text(PlaybackTimeFormatter.string(from: chapter.startSeconds))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            Text(chapter.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 128, alignment: .leading)
        }
    }

    /// 公式 YouTube 風のチャンネル行（アバター + 名前、タップでチャンネルページへ）
    private func channelRow(name: String, channelId: String?) -> some View {
        // アバターURL: /next の videoOwnerRenderer → /player の endscreen → 関連動画の同一チャンネル
        let avatarURL = vm.ownerAvatarURL
            ?? vm.videoInfo?.channelAvatarURL
            ?? vm.relatedVideos.first(where: { $0.channelId == channelId })?.channelAvatarURL
        let content = HStack(spacing: 10) {
            Group {
                if let url = avatarURL {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            channelAvatarPlaceholder
                        }
                    }
                } else {
                    channelAvatarPlaceholder
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            Text(name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)

        return Group {
            if let channelId {
                Button {
                    coordinator.navigateToChannel(ChannelDestination(channelId: channelId))
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var channelAvatarPlaceholder: some View {
        Circle()
            .fill(Color(.tertiarySystemBackground))
            .overlay {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
    }

    private var skeletonTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.secondarySystemBackground))
                .frame(height: 18)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 160, height: 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - コメント

    /// コメント展開バー（公式クライアント風）。タップでシートを開く。
    private var commentsSection: some View {
        Group {
            if vm.isLoadingComments {
                // ローディング中は薄いプレースホルダー
                HStack {
                    Text("コメント")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else if !vm.comments.isEmpty {
                Button { openPanel(.comments) } label: {
                    VStack(spacing: 0) {
                        // ヘッダー行
                        HStack {
                            Text("コメント")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            if let count = vm.commentCountText {
                                Text(count)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                        // 先頭コメントのプレビュー
                        if let first = vm.comments.first {
                            HStack(alignment: .top, spacing: 8) {
                                // アバター
                                Group {
                                    if let url = first.authorAvatarURL {
                                        LazyImage(url: url) { state in
                                            if let image = state.image {
                                                image.resizable().scaledToFill()
                                            } else {
                                                commentAvatarPlaceholder
                                            }
                                        }
                                    } else {
                                        commentAvatarPlaceholder
                                    }
                                }
                                .frame(width: 24, height: 24)
                                .clipShape(Circle())

                                Text(first.contentText)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// コメント全件表示シート
    // MARK: - パネル（チャプター・コメント）

    private func openPanel(_ panel: PlayerPanel) {
        withAnimation(.snappy(duration: 0.3)) { self.panel = panel }
    }

    private func closePanel() {
        withAnimation(.snappy(duration: 0.3)) { panel = nil }
    }

    @ViewBuilder
    private func panelContent(_ panel: PlayerPanel) -> some View {
        switch panel {
        case .chapters:
            ChaptersList(chapters: vm.chapters, player: vm.player) { chapter in
                vm.seek(to: chapter.startSeconds)
            }
        case .comments:
            commentsList
        }
    }

    private var commentsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(vm.comments) { comment in
                    commentRow(comment)

                    // 返信展開ボタン
                    if comment.replyCount > 0 && comment.repliesContinuation != nil {
                        repliesToggle(for: comment)
                    }

                    // 返信スレッド
                    if vm.expandedReplies.contains(comment.id) {
                        repliesSection(for: comment)
                    }

                    Divider()
                        .padding(.leading, 56)
                }

                // ページネーション
                if vm.commentsContinuation != nil {
                    if vm.isLoadingMoreComments {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .onAppear {
                                Task { await vm.loadMoreComments() }
                            }
                    }
                }
            }
        }
        .panelPullToDismiss()
    }

    /// 返信展開/折りたたみボタン
    private func repliesToggle(for comment: CommentItem) -> some View {
        Button {
            Task { await vm.toggleReplies(for: comment) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: vm.expandedReplies.contains(comment.id) ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                Text(vm.expandedReplies.contains(comment.id) ? "返信を非表示" : "\(comment.replyCount)件の返信")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.tint)
            .padding(.leading, 56)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 返信スレッドの表示
    private func repliesSection(for comment: CommentItem) -> some View {
        VStack(spacing: 0) {
            if vm.loadingRepliesFor.contains(comment.id) && vm.replies[comment.id] == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }

            if let replyList = vm.replies[comment.id] {
                ForEach(replyList) { reply in
                    replyRow(reply)
                }

                // 返信の次ページ読み込み
                if vm.repliesContinuation[comment.id] != nil {
                    if vm.loadingRepliesFor.contains(comment.id) {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } else {
                        Button {
                            Task { await vm.loadMoreReplies(for: comment.id) }
                        } label: {
                            Text("さらに返信を表示")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.tint)
                                .padding(.leading, 56)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func commentRow(_ comment: CommentItem) -> some View {
        commentRowContent(comment, avatarSize: 32, isReply: false)
    }

    private func replyRow(_ comment: CommentItem) -> some View {
        commentRowContent(comment, avatarSize: 24, isReply: true)
    }

    private func commentRowContent(_ comment: CommentItem, avatarSize: CGFloat, isReply: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // アバター
            Group {
                if let url = comment.authorAvatarURL {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            commentAvatarPlaceholder
                        }
                    }
                } else {
                    commentAvatarPlaceholder
                }
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                // 著者名・投稿日時
                HStack(spacing: 4) {
                    Text(comment.authorName)
                        .font(.caption)
                        .fontWeight(.medium)
                    if let time = comment.publishedTimeText {
                        Text(time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // コメント本文（タップで全文展開）
                ExpandableCommentText(text: comment.contentText,
                                      font: isReply ? .caption : .subheadline)

                // 高評価数
                if let likes = comment.likeCountText, !likes.isEmpty {
                    Label(likes, systemImage: "hand.thumbsup")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.leading, isReply ? 56 : 14)
        .padding(.trailing, 14)
        .padding(.vertical, isReply ? 6 : 10)
        // 全幅・左寄せにしないと LazyVStack(.center) で短い行が中央寄せされインデントして見える
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var commentAvatarPlaceholder: some View {
        Circle()
            .fill(Color(.tertiarySystemBackground))
            .overlay {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
    }

    // MARK: - 関連動画

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !vm.relatedVideos.isEmpty {
                Text("関連動画")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                LazyVStack(spacing: 0) {
                    ForEach(vm.relatedVideos) { video in
                        Button {
                            coordinator.play(video)
                        } label: {
                            VideoRowView(video: video)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            VideoContextMenu(video: video)
                        }

                        Divider()
                            .padding(.leading, 12)
                    }
                }
            } else if vm.isLoadingRelated {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            }
        }
    }
}

// MARK: - コメント本文（展開可能）

/// コメント本文。既定は4行で折りたたみ、切り詰めが起きる場合のみタップで全文展開できる。
private struct ExpandableCommentText: View {
    let text: String
    let font: Font
    private let collapsedLimit = 4

    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(font)
                .lineLimit(expanded ? nil : collapsedLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    ZStack {
                        heightProbe(lineLimit: collapsedLimit, isFull: false)
                        heightProbe(lineLimit: nil, isFull: true)
                    }
                    .hidden()
                }
                .onPreferenceChange(CommentHeightKey.self) { heights in
                    truncated = (heights[true] ?? 0) > (heights[false] ?? 0) + 1
                }

            if truncated {
                Text(expanded ? "閉じる" : "続きを読む")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard truncated else { return }
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
    }

    private func heightProbe(lineLimit: Int?, isFull: Bool) -> some View {
        Text(text)
            .font(font)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
                Color.clear.preference(key: CommentHeightKey.self, value: [isFull: geo.size.height])
            })
    }
}

private struct CommentHeightKey: PreferenceKey {
    static let defaultValue: [Bool: CGFloat] = [:]
    static func reduce(value: inout [Bool: CGFloat], nextValue: () -> [Bool: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 共有シート

/// UIActivityViewController の SwiftUI ラッパー
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 動画の下の領域に開くパネルの種類
enum PlayerPanel {
    case chapters, comments

    var title: String {
        switch self {
        case .chapters: "チャプター"
        case .comments: "コメント"
        }
    }
}
