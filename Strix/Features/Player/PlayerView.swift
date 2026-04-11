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
    /// 現在の再生速度（1.0 または 2.0）
    var playbackRate: Float = 1.0
    /// ループ再生が有効かどうか
    var isLooping = false
    /// 次動画を自動再生するかどうか
    var autoPlayNext = false
    /// auto-next 時に View がセットした次動画 ID（View の onChange で消費される）
    var autoNextVideoID: String?
    /// 現在ロード済みの動画 ID（View の .task(id:) による二重ロードを防ぐ）
    private(set) var loadedVideoID: String?

    private let youtubeClient: YouTubeClient
    private let contentClient: ContentClient
    /// rate 変更監視トークン（再生再開時に playbackRate を復元するため）
    private var rateObserver: Any?
    /// 動画終端監視トークン（ループ・自動再生で使用）
    private var endObserver: Any?

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
        rateObserver = nil
        endObserver = nil
        autoNextVideoID = nil
        player?.pause()
        player = nil
        videoInfo = nil
        relatedVideos = []
        isLoadingStream = true
        isLoadingRelated = true
        streamError = nil
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
            // 動画終端: ループ or 次動画自動再生
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if self.isLooping {
                    self.player?.seek(to: .zero)
                    self.player?.play()
                } else if self.autoPlayNext, let next = self.relatedVideos.first {
                    self.autoNextVideoID = next.videoId
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
            isLoadingStream = false
        }
    }

    private func loadRelated(videoID: String) async {
        do {
            relatedVideos = try await contentClient.fetchRelated(videoID)
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
    @State private var currentVideoID: String

    @State private var vm = PlayerViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(videoID: String) {
        self.videoID = videoID
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
        .task(id: currentVideoID) {
            // loadedVideoID が一致する場合は再ロードしない
            // （PiP 復帰・ナビゲーションでのビュー再表示による二重ロードを防ぐ）
            guard vm.loadedVideoID != currentVideoID else { return }
            await vm.load(videoID: currentVideoID, modelContext: modelContext)
        }
        .onChange(of: vm.autoNextVideoID) { _, nextID in
            guard let nextID else { return }
            vm.autoNextVideoID = nil
            currentVideoID = nextID
        }
        .onDisappear {
            // バックグラウンド移行時は onDisappear が誤発火することがあるため
            // scenePhase が active のときだけ（= ナビゲーションで離脱したとき）停止する
            guard scenePhase == .active else { return }
            vm.player?.pause()
            NowPlayingManager.shared.stop()
            LiveActivityManager.shared.stop()
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
                ContentUnavailableView(
                    "再生できません",
                    systemImage: "exclamationmark.triangle",
                    description: Text(vm.streamError?.localizedDescription ?? "")
                )
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
        // アバターURL: VideoInfo → 関連動画の同一チャンネル → 関連動画の先頭
        let avatarURL = vm.videoInfo?.channelAvatarURL
            ?? vm.relatedVideos.first(where: { $0.channelId == channelId })?.channelAvatarURL
            ?? vm.relatedVideos.first?.channelAvatarURL
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
                NavigationLink(value: ChannelDestination(channelId: channelId)) {
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

