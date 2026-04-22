//
//  PlayerView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import AVFoundation
import AVKit
import UIKit
import SwiftData
import NukeUI

@Observable
final class PlayerViewModel {
    var player: AVPlayer?
    var videoInfo: VideoInfo?
    var relatedVideos: [VideoItem] = []
    var isLoadingStream = true
    var isLoadingRelated = true
    var streamError: Error?
    /// YouTube のボット検出エラーかどうか
    var isBotDetected = false
    /// 現在の再生速度（1.0 または 2.0）。UserDefaults に永続化してアプリ全体で維持する。
    var playbackRate: Float = {
        let v = UserDefaults.standard.float(forKey: "playbackRate")
        return v.isZero ? 1.0 : v
    }() {
        didSet { UserDefaults.standard.set(playbackRate, forKey: "playbackRate") }
    }
    /// 音声のみモード（UserDefaults に永続化）
    var isAudioOnly: Bool = UserDefaults.standard.bool(forKey: "isAudioOnly") {
        didSet { UserDefaults.standard.set(isAudioOnly, forKey: "isAudioOnly") }
    }
    /// ループ再生が有効かどうか
    var isLooping = false
    /// 次動画を自動再生するかどうか
    var autoPlayNext = true
    /// auto-next 時に View がセットした次動画 ID（View の onChange で消費される）
    var autoNextVideoID: String?
    /// /next API から取得したチャンネルオーナーのアバター URL
    var ownerAvatarURL: URL?
    /// 動画の説明欄データ
    var videoDescription: String?
    var viewCountText: String?
    var publishDateText: String?
    /// コメント一覧
    var comments: [CommentItem] = []
    var isLoadingComments = true
    var commentsContinuation: String?
    var isLoadingMoreComments = false
    /// 現在ロード済みの動画 ID（View の .task(id:) による二重ロードを防ぐ）
    private(set) var loadedVideoID: String?

    // MARK: - プレイリスト再生モード
    /// プレイリストの動画リスト（セット済みなら関連動画ではなくこのリスト順に再生する）
    var playlistQueue: [VideoItem] = []
    /// 現在再生中のプレイリスト内インデックス
    var playlistIndex: Int = 0

    private let youtubeClient: YouTubeClient
    private let contentClient: ContentClient
    /// rate 変更監視トークン（再生再開時に playbackRate を復元するため）
    private var rateObserver: Any?
    /// 動画終端監視トークン（ループ・自動再生で使用）
    private var endObserver: Any?
    /// 再生位置の定期監視トークン（バックアップの終端検出用）
    private var timeObserver: Any?
    /// YouTube に視聴履歴を報告するトラッカー
    private let playbackTracker = PlaybackTracker()

    init(youtubeClient: YouTubeClient = .live, contentClient: ContentClient = .live) {
        self.youtubeClient = youtubeClient
        self.contentClient = contentClient
    }

    func load(videoID: String, modelContext: ModelContext) async {
        // 前の動画の再生位置を保存してから切り替える
        savePlaybackPosition(modelContext: modelContext)
        // 再ロード時: 前のプレイヤーを停止して状態をリセットする
        // これにより player = nil で AVPlayerLayerView が一度ツリーから外れ、
        // 新しいプレイヤーで再生成されるため同時再生が発生しない
        loadedVideoID = videoID
        if let obs = rateObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = timeObserver, let p = player { p.removeTimeObserver(obs) }
        rateObserver = nil
        endObserver = nil
        timeObserver = nil
        autoNextVideoID = nil
        playbackTracker.stop()
        player?.pause()
        player = nil
        videoInfo = nil
        relatedVideos = []
        ownerAvatarURL = nil
        videoDescription = nil
        viewCountText = nil
        publishDateText = nil
        comments = []
        isLoadingComments = true
        commentsContinuation = nil
        isLoadingMoreComments = false
        isLoadingStream = true
        isLoadingRelated = true
        streamError = nil
        isBotDetected = false
        // playbackRate はリセットしない（ユーザーの倍速設定を維持）

        // ストリームと関連動画とコメントを並列取得
        async let streamTask: Void = loadStream(videoID: videoID, modelContext: modelContext)
        async let relatedTask: Void = loadRelated(videoID: videoID)
        async let commentsTask: Void = loadComments(videoID: videoID)
        _ = await (streamTask, relatedTask, commentsTask)
    }

    private func loadStream(videoID: String, modelContext: ModelContext) async {
        do {
            let info = try await youtubeClient.fetchVideo(videoID)
            videoInfo = info
            // 音声のみモードなら音声 URL を使用、なければ通常ストリーム
            let playURL = (isAudioOnly && info.audioOnlyURL != nil) ? info.audioOnlyURL! : info.streamURL
            let avPlayer = AVPlayer(url: playURL)
            player = avPlayer
            // PiP コントロールで再生再開すると rate が 1.0 に戻るため、
            // rateDidChangeNotification で監視して playbackRate を復元する
            rateObserver = NotificationCenter.default.addObserver(
                forName: AVPlayer.rateDidChangeNotification,
                object: avPlayer,
                queue: .main
            ) { [weak self] _ in
                guard let self, let p = self.player, p.rate > 0 else { return }
                if p.rate != self.playbackRate {
                    p.rate = self.playbackRate
                }
            }
            // 動画終端: ループ or 次動画自動再生（通知ベース）
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.handlePlaybackEnded()
            }
            // バックアップ: 再生位置の定期監視で終端を検出（通知が来ない場合の保険）
            let interval = CMTime(seconds: 1, preferredTimescale: 1)
            timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self, let item = self.player?.currentItem else { return }
                let duration = item.duration
                guard duration.isNumeric, duration.seconds > 0 else { return }
                let remaining = duration.seconds - time.seconds
                // 残り0.5秒以内 かつ 再生停止していたら終端扱い
                if remaining < 0.5, self.player?.rate == 0, self.player?.currentItem?.status == .readyToPlay {
                    self.handlePlaybackEnded()
                }
            }
            avPlayer.play()
            // ユーザーの倍速設定を即座に適用
            if playbackRate != 1.0 {
                avPlayer.rate = playbackRate
            }
            // 前回の再生位置があればシークして復帰する
            resumeIfNeeded(modelContext: modelContext)
            isLoadingStream = false
            // コントロールセンター・ロック画面の Now Playing を開始する
            NowPlayingManager.shared.start(
                player: avPlayer,
                title: info.title,
                thumbnailURL: info.thumbnailURL
            )
            // ダイナミックアイランド Live Activity を開始する
            LiveActivityManager.shared.start(
                title: info.title,
                channelName: "",
                thumbnailURL: info.thumbnailURL,
                player: avPlayer
            )
            // YouTube に再生開始を報告して視聴履歴に記録する
            playbackTracker.start(player: avPlayer, trackingURLs: info.playbackTrackingURLs)
            saveToHistory(videoID: videoID, info: info, modelContext: modelContext)
        } catch {
            streamError = error
            // ボット検出の判定（エラーメッセージに「bot」「ログイン」が含まれる場合）
            let desc = error.localizedDescription.lowercased()
            isBotDetected = desc.contains("bot") || desc.contains("ログイン") || desc.contains("sign in")
            isLoadingStream = false
        }
    }

    private func loadRelated(videoID: String) async {
        do {
            let result = try await contentClient.fetchRelated(videoID)
            relatedVideos = result.videos
            ownerAvatarURL = result.ownerAvatarURL
            videoDescription = result.description
            viewCountText = result.viewCount
            publishDateText = result.publishDate
        } catch {
            // 関連動画の失敗はサイレントに扱う
        }
        isLoadingRelated = false
    }

    private func loadComments(videoID: String) async {
        do {
            let result = try await contentClient.fetchComments(videoID)
            comments = result.comments
            commentsContinuation = result.continuation
        } catch {
            // コメント取得の失敗はサイレントに扱う
        }
        isLoadingComments = false
    }

    /// コメントの次ページを読み込む
    func loadMoreComments() async {
        guard let token = commentsContinuation, !isLoadingMoreComments else { return }
        isLoadingMoreComments = true
        do {
            let result = try await contentClient.fetchCommentsPage(token)
            comments.append(contentsOf: result.comments)
            commentsContinuation = result.continuation
        } catch {
            // 次ページ取得の失敗はサイレントに扱う
        }
        isLoadingMoreComments = false
    }

    /// 再生速度を 1.0 → 2.0 → 1.0 の順に切り替える
    func togglePlaybackRate() {
        playbackRate = (playbackRate == 1.0) ? 2.0 : 1.0
        player?.rate = playbackRate
    }

    /// 任意の再生速度を適用する（倍速メニュー用）
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        // 再生中のみ rate を即適用（停止中に rate を変えると勝手に再生開始するため）
        if player?.rate ?? 0 > 0 {
            player?.rate = rate
        }
    }

    /// 現在位置から指定秒数だけ進める（正で前進、負で後退）
    func skip(by seconds: Double) {
        guard let player, let item = player.currentItem else { return }
        let now = player.currentTime().seconds
        let maxTime: Double = item.duration.isNumeric ? item.duration.seconds : .infinity
        let target = max(0, min(now + seconds, maxTime))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// ループ再生のオン/オフを切り替える
    func toggleLoop() {
        isLooping.toggle()
    }

    /// 次動画自動再生のオン/オフを切り替える
    func toggleAutoPlayNext() {
        autoPlayNext.toggle()
    }

    /// 通常モード ↔ 音声のみモードを切り替え、現在の動画をリロードする
    func toggleAudioOnly() {
        guard let info = videoInfo else { return }
        isAudioOnly.toggle()
        let targetURL = (isAudioOnly && info.audioOnlyURL != nil) ? info.audioOnlyURL! : info.streamURL
        let currentTime = player?.currentTime()
        let wasPlaying = player?.rate != 0

        let newPlayer = AVPlayer(url: targetURL)
        player = newPlayer
        if let time = currentTime, time.isValid {
            newPlayer.seek(to: time)
        }
        if wasPlaying {
            newPlayer.play()
            if playbackRate != 1.0 { newPlayer.rate = playbackRate }
        }
    }

    /// 再生終了時の処理（通知 + 定期監視の両方から呼ばれるため二重発火を防止）
    private func handlePlaybackEnded() {
        guard autoNextVideoID == nil else { return }
        if isLooping {
            player?.seek(to: .zero)
            player?.play()
        } else if !playlistQueue.isEmpty {
            // プレイリスト再生モード: 次のトラックへ
            let nextIndex = playlistIndex + 1
            if nextIndex < playlistQueue.count {
                playlistIndex = nextIndex
                autoNextVideoID = playlistQueue[nextIndex].videoId
            } else if autoPlayNext, let next = relatedVideos.first {
                // プレイリスト末尾 → 関連動画にフォールバック
                autoNextVideoID = next.videoId
            }
        } else if autoPlayNext, let next = relatedVideos.first {
            autoNextVideoID = next.videoId
        }
    }

    /// プレイリスト内の前のトラックへ戻る
    func playPrevious() {
        guard !playlistQueue.isEmpty, playlistIndex > 0 else { return }
        playlistIndex -= 1
        autoNextVideoID = playlistQueue[playlistIndex].videoId
    }

    /// プレイリスト内の次のトラックへ進む
    func playNext() {
        guard !playlistQueue.isEmpty, playlistIndex + 1 < playlistQueue.count else { return }
        playlistIndex += 1
        autoNextVideoID = playlistQueue[playlistIndex].videoId
    }

    /// 現在の再生位置を SwiftData に保存する
    func savePlaybackPosition(modelContext: ModelContext) {
        guard let videoID = loadedVideoID,
              let player,
              let item = player.currentItem,
              item.duration.isNumeric else { return }
        let position = player.currentTime().seconds
        let duration = item.duration.seconds
        guard position.isFinite, duration.isFinite else { return }

        let targetID = videoID
        var descriptor = FetchDescriptor<WatchedVideo>(
            predicate: #Predicate { $0.videoID == targetID }
        )
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first else { return }
        record.playbackPosition = position
        record.videoDuration = duration
    }

    /// 保存済みの再生位置があればシークして復帰する
    /// （95%以上視聴済み or 残り10秒未満 → 最初から再生）
    func resumeIfNeeded(modelContext: ModelContext) {
        guard let videoID = loadedVideoID else { return }
        let targetID = videoID
        var descriptor = FetchDescriptor<WatchedVideo>(
            predicate: #Predicate { $0.videoID == targetID }
        )
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first,
              record.playbackPosition > 5,
              record.videoDuration > 0 else { return }

        let ratio = record.playbackPosition / record.videoDuration
        let remaining = record.videoDuration - record.playbackPosition
        if ratio >= 0.95 || remaining < 10 { return }

        let target = CMTime(seconds: record.playbackPosition, preferredTimescale: 600)
        player?.seek(to: target)
    }

    /// 視聴履歴を保存する（既存レコードがあれば更新、なければ挿入）
    private func saveToHistory(videoID: String, info: VideoInfo, modelContext: ModelContext) {
        let targetID = videoID
        var descriptor = FetchDescriptor<WatchedVideo>(
            predicate: #Predicate { $0.videoID == targetID }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.watchedAt = .now
            existing.title = info.title
            existing.thumbnailURL = info.thumbnailURL
        } else {
            let video = WatchedVideo(
                videoID: videoID,
                title: info.title,
                thumbnailURL: info.thumbnailURL
            )
            modelContext.insert(video)
        }
    }
}

struct PlayerView: View {
    let videoID: String
    /// 外部から注入される PlayerViewModel（PlayerContainerView が所有）
    var vm: PlayerViewModel

    @Environment(PlayerCoordinator.self) private var coordinator
    @State private var showBotVerify = false
    @State private var showFullDescription = false
    @State private var showComments = false
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                // プレイリスト再生インジケータ（N/M 表示。前/次ボタンはプレイヤー内へ移行済み）
                if !vm.playlistQueue.isEmpty, !vm.isLoadingStream, vm.streamError == nil {
                    HStack {
                        Image(systemName: "list.and.film")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("プレイリスト再生中  \(vm.playlistIndex + 1)/\(vm.playlistQueue.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
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
                relatedSection
            }
            }
            } // if !isFullScreen
        }
        .navigationBarTitleDisplayMode(.inline)
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
                    isFullScreen: isFullScreen
                )
                .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    let ty = value.translation.height
                    let tx = abs(value.translation.width)
                    if ty > 0, ty > tx {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            coordinator.dragOffset = ty
                        }
                    }
                }
                .onEnded { value in
                    let ty = value.translation.height
                    let vy = value.predictedEndTranslation.height
                    let screenHeight = UIScreen.main.bounds.height
                    if ty > screenHeight * 0.15 || vy > 300 {
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

            // チャンネル行（アバター + チャンネル名）
            if let channelName = info.channelName {
                channelRow(name: channelName, channelId: info.channelId)
            }
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
                Button { showComments = true } label: {
                    VStack(spacing: 0) {
                        // ヘッダー行
                        HStack {
                            Text("コメント")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            Text("\(vm.comments.count)件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
        .sheet(isPresented: $showComments) {
            commentsSheet
        }
    }

    /// コメント全件表示シート
    private var commentsSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.comments) { comment in
                        commentRow(comment)
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
            .navigationTitle("コメント")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showComments = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func commentRow(_ comment: CommentItem) -> some View {
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
            .frame(width: 32, height: 32)
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

                // コメント本文
                Text(comment.contentText)
                    .font(.subheadline)
                    .lineLimit(4)

                // 高評価数・返信数
                HStack(spacing: 12) {
                    if let likes = comment.likeCountText, !likes.isEmpty {
                        Label(likes, systemImage: "hand.thumbsup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if comment.replyCount > 0 {
                        Label("\(comment.replyCount)件の返信", systemImage: "arrowshape.turn.up.left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                            coordinator.play(videoID: video.videoId)
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

// MARK: - AVPlayer バックグラウンド対応ビュー

/// `AVPlayerViewController` をラップしつつ、バックグラウンド移行時に
/// `player` プロパティを一時的に `nil` にすることで iOS の自動停止を回避する。
/// 標準の再生コントロール（シークバー・再生/停止ボタン等）はそのまま使える。
private struct AVPlayerLayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> _PlayerViewController {
        _PlayerViewController(player: player)
    }

    func updateUIViewController(_ vc: _PlayerViewController, context: Context) {}
}

/// `AVPlayerViewController` のサブクラス。
/// `didEnterBackground` で `player` を一時的に切り離して iOS の自動停止を回避しつつ、
/// バックグラウンド中も再生を継続させるため、直後に `playerRef.play()` で再開する。
/// PiP 中はこの処理をスキップする。
final class _PlayerViewController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    /// アプリ内で同時に存在できる VC は1つだけ。新しい VC が init されたとき
    /// 古い VC が PiP 中であれば stopPictureInPicture() で閉じる。
    private static weak var current: _PlayerViewController?

    private let playerRef: AVPlayer
    /// PiP がアクティブかどうかをデリゲートで追跡する
    private var isPiPActive = false
    /// バックグラウンド移行前に再生中だったか（復帰時の play 再開判定用）
    private var wasPlayingBeforeBackground = false

    init(player: AVPlayer) {
        self.playerRef = player
        super.init(nibName: nil, bundle: nil)
        // 既存の VC を停止してから自分をアクティブにする
        // player = nil にすることで PiP も終了する
        _PlayerViewController.current?.closeAndStop()
        _PlayerViewController.current = self
        self.player = player
        self.delegate = self
        // NowPlayingManager が MPNowPlayingInfoCenter を管理するため、
        // AVPlayerViewController の自動更新を無効化する
        self.updatesNowPlayingInfoCenter = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 再生を停止し、PiP が起動中であれば player = nil で終了させる
    func closeAndStop() {
        playerRef.pause()
        player = nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// バックグラウンド移行時: AVPlayerViewController から AVPlayer を切り離し、
    /// iOS による自動停止を回避する。切り離す際に内部で pause() される可能性があるため、
    /// 直後に playerRef.play() を呼んで音声再生を継続させる。
    /// PiP 中は切り離すと PiP が終了するためスキップする。
    @objc private func didEnterBackground() {
        guard !isPiPActive else { return }
        wasPlayingBeforeBackground = playerRef.rate > 0
        player = nil
        if wasPlayingBeforeBackground {
            playerRef.play()
        }
    }

    /// フォアグラウンド復帰直前: ViewController にプレイヤーを再接続して映像表示を再開する
    @objc private func willEnterForeground() {
        player = playerRef
        // player 再接続時にも内部で pause() される場合があるため、元の再生状態を復元する
        if wasPlayingBeforeBackground {
            playerRef.play()
        }
        wasPlayingBeforeBackground = false
    }

    // MARK: - AVPlayerViewControllerDelegate

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPiPActive = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPiPActive = false
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
