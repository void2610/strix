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
    /// 現在の再生速度（1.0 または 2.0）
    var playbackRate: Float = 1.0
    /// ループ再生が有効かどうか
    var isLooping = false
    /// 次動画を自動再生するかどうか
    var autoPlayNext = true
    /// auto-next 時に View がセットした次動画 ID（View の onChange で消費される）
    var autoNextVideoID: String?
    /// /next API から取得したチャンネルオーナーのアバター URL
    var ownerAvatarURL: URL?
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

    init(youtubeClient: YouTubeClient = .live, contentClient: ContentClient = .live) {
        self.youtubeClient = youtubeClient
        self.contentClient = contentClient
    }

    func load(videoID: String, modelContext: ModelContext) async {
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
        player?.pause()
        player = nil
        videoInfo = nil
        relatedVideos = []
        ownerAvatarURL = nil
        isLoadingStream = true
        isLoadingRelated = true
        streamError = nil
        isBotDetected = false
        playbackRate = 1.0

        // ストリームと関連動画を並列取得
        async let streamTask: Void = loadStream(videoID: videoID, modelContext: modelContext)
        async let relatedTask: Void = loadRelated(videoID: videoID)
        _ = await (streamTask, relatedTask)
    }

    private func loadStream(videoID: String, modelContext: ModelContext) async {
        do {
            let info = try await youtubeClient.fetchVideo(videoID)
            videoInfo = info
            let avPlayer = AVPlayer(url: info.streamURL)
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
        } catch {
            // 関連動画の失敗はサイレントに扱う
        }
        isLoadingRelated = false
    }

    /// 再生速度を 1.0 → 2.0 → 1.0 の順に切り替える
    func togglePlaybackRate() {
        playbackRate = (playbackRate == 1.0) ? 2.0 : 1.0
        player?.rate = playbackRate
    }

    /// ループ再生のオン/オフを切り替える
    func toggleLoop() {
        isLooping.toggle()
    }

    /// 次動画自動再生のオン/オフを切り替える
    func toggleAutoPlayNext() {
        autoPlayNext.toggle()
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

    private func saveToHistory(videoID: String, info: VideoInfo, modelContext: ModelContext) {
        let video = WatchedVideo(
            videoID: videoID,
            title: info.title,
            thumbnailURL: info.thumbnailURL
        )
        modelContext.insert(video)
    }
}

struct PlayerView: View {
    let videoID: String
    /// プレイリスト再生モード用の動画リスト
    let playlistQueue: [VideoItem]
    let initialIndex: Int

    @State private var currentVideoID: String

    @State private var vm = PlayerViewModel()
    @State private var channelToOpen: String?
    @State private var showBotVerify = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(videoID: String, playlistQueue: [VideoItem] = [], initialIndex: Int = 0) {
        self.videoID = videoID
        self.playlistQueue = playlistQueue
        self.initialIndex = initialIndex
        self._currentVideoID = State(initialValue: videoID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 動画プレイヤー（画面幅 × 16:9）
                playerSection

                // コントロールボタン（ループ・自動再生・倍速）
                if !vm.isLoadingStream && vm.streamError == nil {
                    HStack(spacing: 8) {
                        // ループ切り替え
                        playerControlButton(
                            icon: vm.isLooping ? "repeat.1" : "repeat",
                            isActive: vm.isLooping
                        ) { vm.toggleLoop() }

                        // 次動画自動再生切り替え
                        playerControlButton(
                            icon: "forward.end.fill",
                            isActive: vm.autoPlayNext
                        ) { vm.toggleAutoPlayNext() }

                        // プレイリスト再生時: 前/次トラック
                        if !vm.playlistQueue.isEmpty {
                            playerControlButton(
                                icon: "backward.fill",
                                isActive: vm.playlistIndex > 0
                            ) { vm.playPrevious() }

                            Text("\(vm.playlistIndex + 1)/\(vm.playlistQueue.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            playerControlButton(
                                icon: "forward.fill",
                                isActive: vm.playlistIndex + 1 < vm.playlistQueue.count
                            ) { vm.playNext() }
                        }

                        Spacer()

                        // 倍速切り替え
                        Button { vm.togglePlaybackRate() } label: {
                            Text(vm.playbackRate == 1.0 ? "1×" : "2×")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.thinMaterial, in: Capsule())
                        }
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

                // 関連動画
                relatedSection
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { channelToOpen != nil },
            set: { if !$0 { channelToOpen = nil } }
        )) {
            if let channelId = channelToOpen {
                ChannelView(channelId: channelId)
                    .navigationDestination(for: String.self) { videoID in
                        PlayerView(videoID: videoID)
                    }
                    .navigationDestination(for: ChannelDestination.self) { dest in
                        ChannelView(channelId: dest.channelId)
                    }
            }
        }
        .task(id: currentVideoID) {
            guard vm.loadedVideoID != currentVideoID else { return }
            // 初回のみプレイリストキューをセット
            if vm.playlistQueue.isEmpty, !playlistQueue.isEmpty {
                vm.playlistQueue = playlistQueue
                vm.playlistIndex = initialIndex
            }
            await vm.load(videoID: currentVideoID, modelContext: modelContext)
        }
        .onChange(of: vm.autoNextVideoID) { _, nextID in
            guard let nextID else { return }
            vm.autoNextVideoID = nil
            currentVideoID = nextID
        }
        .onDisappear {
            guard scenePhase == .active else { return }
            vm.player?.pause()
            NowPlayingManager.shared.stop()
            LiveActivityManager.shared.stop()
        }
        .sheet(isPresented: $showBotVerify) {
            BotVerifyView {
                // 認証完了後にリトライ
                showBotVerify = false
                Task {
                    await vm.load(videoID: currentVideoID, modelContext: modelContext)
                }
            }
        }
    }

    // MARK: - コントロールボタン

    private func playerControlButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - プレイヤー

    private var playerSection: some View {
        ZStack {
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)

            if vm.isLoadingStream {
                ProgressView()
                    .tint(.white)
            } else if vm.streamError != nil {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "再生できません",
                        systemImage: "exclamationmark.triangle",
                        description: Text(vm.streamError?.localizedDescription ?? "")
                    )
                    // ボット検出の場合は認証ボタンを表示
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
            } else if let player = vm.player {
                AVPlayerLayerView(player: player)
            }
        }
    }

    // MARK: - タイトル・メタ情報

    private func videoMeta(info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // タイトル
            Text(info.title)
                .font(.headline)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

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
                    channelToOpen = channelId
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
                        NavigationLink(value: video.videoId) {
                            VideoRowView(video: video)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)

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
/// `willResignActive` で `player = nil` にしてバックグラウンド自動停止を無効化し、
/// `willEnterForeground` で `player` を復元する。
/// PiP 中は `player = nil` をスキップして PiP を維持する。
final class _PlayerViewController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    /// アプリ内で同時に存在できる VC は1つだけ。新しい VC が init されたとき
    /// 古い VC が PiP 中であれば stopPictureInPicture() で閉じる。
    private static weak var current: _PlayerViewController?

    private let playerRef: AVPlayer
    /// PiP がアクティブかどうかをデリゲートで追跡する
    private var isPiPActive = false

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
            selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification,
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

    /// バックグラウンド移行直前: ViewController とプレイヤーの接続を切り離して iOS の自動停止を無効化する。
    /// PiP 中は切り離すと PiP が終了するためスキップする。
    @objc private func willResignActive() {
        guard !isPiPActive else { return }
        player = nil
    }

    /// フォアグラウンド復帰直前: ViewController にプレイヤーを再接続して映像表示を再開する
    @objc private func willEnterForeground() {
        player = playerRef
    }

    // MARK: - AVPlayerViewControllerDelegate

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPiPActive = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPiPActive = false
    }
}

