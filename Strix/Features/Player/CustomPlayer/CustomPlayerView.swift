//
//  CustomPlayerView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/22.
//

import SwiftUI
import AVFoundation
import SwiftData

/// YouTube 風のカスタムプレイヤー本体。
/// AVPlayerLayer で映像を描画し、SwiftUI でオーバーレイコントロールを重ねる。
///
/// Phase 1 + 2 + 3 の統合構成:
///  - 映像表示・タップでオーバーレイ表示/非表示・3秒自動フェード
///  - 中央: 再生/停止・10秒スキップ（通常時）／前・再生/停止・次（プレイリスト時）
///  - 下部: シークバー + 時刻
///  - 上部: ミニプレイヤー化・タイトル・設定メニュー・フルスクリーン切替
///  - 設定メニュー: 倍速・ループ・自動再生・音声のみ・共有
///  - ダブルタップで左右10秒スキップ（波紋エフェクト）
///  - バッファリングインジケータ
///  - バックグラウンド再生継続
struct CustomPlayerView: View {
    let videoID: String
    var vm: PlayerViewModel
    /// フルスクリーン切替を上位に伝える（PlayerContainerView 側で handle）
    var onToggleFullScreen: (() -> Void)? = nil
    /// フルスクリーン中かどうか（ボタンアイコン切替用）
    var isFullScreen: Bool = false

    @Environment(PlayerCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext

    @State private var controller = PlayerOverlayController()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying: Bool = false
    @State private var isBuffering: Bool = false
    /// スクラブ中にユーザーが触っている位置（時刻表示用、nil なら currentTime を表示）
    @State private var scrubPreviewTime: Double? = nil
    /// ダブルタップスキップの波紋エフェクト
    @State private var skipRipple: SkipRipple? = nil

    /// PeriodicTimeObserver 解除用トークン
    @State private var timeObserverToken: Any?
    /// player.rate 監視用
    @State private var rateObserverToken: NSObjectProtocol?
    /// AVPlayer KVO トークン（isPlaybackLikelyToKeepUp 監視用）
    @State private var itemBufferObservation: NSKeyValueObservation?

    private var player: AVPlayer? { vm.player }

    var body: some View {
        ZStack {
            // MARK: 映像
            if let player {
                // バックグラウンド自動停止回避は PlayerLayerView 内部の Coordinator で完結
                PlayerLayerView(player: player)

                // 音声のみモード: 映像トラックがない（またはフォールバックの低画質映像）ため
                // 代わりにサムネイルを表示する
                if vm.isAudioOnly {
                    audioOnlyArtwork
                }
            } else {
                Color.black
            }

            // MARK: ダブルタップスキップ + シングルタップでオーバーレイ切替
            // 同じ領域に両方を付けると SwiftUI がダブル判定のためシングルを ~250ms 遅延させるが、
            // ダブルタップ領域の上に別のタップレイヤーを置くと count:2 がシングルも消費してしまい
            // シングルが発火しなくなるため、同居させて遅延は受け入れる方針にする
            doubleTapSkipLayer

            // MARK: オーバーレイ背景（フェード）
            Color.black.opacity(controller.isVisible ? 0.35 : 0)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.1), value: controller.isVisible)

            // MARK: オーバーレイ UI
            overlay
                .opacity(controller.isVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.1), value: controller.isVisible)
                .allowsHitTesting(controller.isVisible)

            // MARK: バッファリング表示
            if isBuffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
                    .allowsHitTesting(false)
            }
        }
        .environment(controller)
        .onAppear { setup() }
        .onDisappear { teardown() }
        // AVPlayer? は Equatable ではないため、代わりに loadedVideoID で変化を検知する
        .onChange(of: vm.loadedVideoID) { _, _ in
            rebindObservers()
        }
        // 音声のみ切替時はアイテムが差し替わるため、アイテム単位の KVO を貼り直す
        .onChange(of: vm.isAudioOnly) { _, _ in
            rebindObservers()
        }
    }

    /// 音声のみモードで映像の代わりに表示するサムネイル
    private var audioOnlyArtwork: some View {
        ZStack {
            Color.black
            if let urlStr = vm.videoInfo?.thumbnailURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Color.black
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - ダブルタップスキップ

    /// 左半分 = -10秒、右半分 = +10秒。シングルタップはオーバーレイ表示切替に割り当てる。
    private var doubleTapSkipLayer: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                skipHalfArea(side: .left, width: geo.size.width / 2)
                skipHalfArea(side: .right, width: geo.size.width / 2)
            }
            .overlay {
                if let ripple = skipRipple {
                    SkipRippleView(ripple: ripple)
                        .allowsHitTesting(false)
                        .id(ripple.triggerID)
                }
            }
        }
    }

    private func skipHalfArea(side: SkipSide, width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            // ダブルタップ優先、シングルタップはオーバーレイ表示/非表示
            .onTapGesture(count: 2) {
                let delta = side == .left ? -10.0 : 10.0
                vm.skip(by: delta)
                triggerRipple(side: side, amount: Int(abs(delta)))
            }
            .onTapGesture {
                controller.tapped()
            }
    }

    private func triggerRipple(side: SkipSide, amount: Int) {
        // 連続ダブルタップで秒数を累積
        if var r = skipRipple, r.side == side {
            r.amount += amount
            r.triggerID = UUID()
            skipRipple = r
        } else {
            skipRipple = SkipRipple(side: side, amount: amount)
        }
        // 0.6秒後に消す
        let current = skipRipple?.triggerID
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            await MainActor.run {
                // 同一トリガーなら消す（新しいタップで上書きされた場合は残す）
                if skipRipple?.triggerID == current {
                    skipRipple = nil
                }
            }
        }
    }

    // MARK: - オーバーレイ本体

    private var overlay: some View {
        ZStack {
            topBar
            centerControls
            bottomBar
        }
    }

    // MARK: 上部バー

    private var topBar: some View {
        VStack {
            HStack(spacing: 4) {
                // ミニプレイヤー化
                topBarButton(system: "chevron.down") {
                    coordinator.minimize()
                }

                if let title = vm.videoInfo?.title {
                    Text(title)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }

                // 倍速トグル（1× / 2×）
                playbackRateToggle

                // フルスクリーン切替
                topBarButton(
                    system: isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                ) {
                    onToggleFullScreen?()
                    controller.bumpFade()
                }

                // 設定メニュー（一番端）
                settingsMenu
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            )

            Spacer()
        }
    }

    /// 上部バー用のボタン。アイコンの見た目サイズは 16pt、当たり判定は 44×44pt。
    private func topBarButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 1× ↔ 2× のトグル。当たり判定は 44×44pt、見た目は小さめのピル。
    private var playbackRateToggle: some View {
        Button {
            vm.togglePlaybackRate()
            controller.bumpFade()
        } label: {
            Text(vm.playbackRate == 1.0 ? "1×" : "2×")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.18), in: Capsule())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 中央コントロール

    private var centerControls: some View {
        HStack(spacing: 36) {
            if !vm.playlistQueue.isEmpty {
                // プレイリスト再生時: 前トラック
                playerIconButton(
                    system: "backward.end.fill",
                    size: 28,
                    disabled: vm.playlistIndex == 0
                ) {
                    vm.playPrevious()
                    controller.bumpFade()
                }
            } else {
                // 通常再生時: 10秒戻る
                playerIconButton(system: "gobackward.10", size: 30) {
                    vm.skip(by: -10)
                    triggerRipple(side: .left, amount: 10)
                    controller.bumpFade()
                }
            }

            // 再生/停止（アイコン 40pt のまま、当たり判定 88×88pt）
            Button {
                togglePlay()
                controller.bumpFade()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !vm.playlistQueue.isEmpty {
                playerIconButton(
                    system: "forward.end.fill",
                    size: 28,
                    disabled: vm.playlistIndex + 1 >= vm.playlistQueue.count
                ) {
                    vm.playNext()
                    controller.bumpFade()
                }
            } else {
                playerIconButton(system: "goforward.10", size: 30) {
                    vm.skip(by: 10)
                    triggerRipple(side: .right, amount: 10)
                    controller.bumpFade()
                }
            }
        }
    }

    private func playerIconButton(
        system: String,
        size: CGFloat,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(disabled ? Color.white.opacity(0.35) : .white)
                .frame(width: 72, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: 下部バー

    private var bottomBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Text(formatTime(displayedTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 40, alignment: .leading)

                PlayerSeekBar(
                    // プレビュー優先で渡すことで、ドラッグ中もシーク完了待ちの間も同じ値で進捗を描画する
                    currentTime: displayedTime,
                    duration: duration,
                    onScrub: { t in
                        scrubPreviewTime = t
                    },
                    onSeek: { t in
                        guard let player else { return }
                        let target = CMTime(seconds: t, preferredTimescale: 600)
                        // completionHandler でシーク完了を待ってからプレビューと isScrubbing を解除することで、
                        // PeriodicTimeObserver の currentTime が追いつく前に「元の位置に戻る」ちらつきを防ぐ
                        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            Task { @MainActor in
                                currentTime = t
                                scrubPreviewTime = nil
                                controller.isScrubbing = false
                                controller.bumpFade()
                            }
                        }
                    }
                )

                Text(formatTime(max(duration, 0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .padding(.top, 20)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            )
        }
    }

    // MARK: 設定メニュー

    private var settingsMenu: some View {
        Menu {
            // ループ
            Toggle(isOn: loopingBinding) {
                Label("ループ再生", systemImage: "repeat")
            }

            // 自動再生
            Toggle(isOn: autoPlayNextBinding) {
                Label("自動再生", systemImage: "forward.end.fill")
            }

            // 音声のみ
            Toggle(isOn: audioOnlyBinding) {
                Label("音声のみ", systemImage: vm.isAudioOnly ? "speaker.wave.2.fill" : "video.fill")
            }

            Divider()

            // ダウンロード（状態に応じてラベルを出し分ける）
            downloadMenuItem

            // 共有
            if let url = URL(string: "https://youtu.be/\(videoID)") {
                ShareLink(item: url) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        // Menu を開いている間はオーバーレイを消したくない（Menu を開いた瞬間に親が消えると Menu も閉じる）
        // SwiftUI Menu は開閉フックがないので、Picker/Toggle/Button 各アクションで bumpFade を呼ぶ
    }

    /// 再生中の動画をオフライン保存するメニュー項目。状態に応じて出し分ける。
    @ViewBuilder
    private var downloadMenuItem: some View {
        if let video = vm.currentVideoItem {
            let record = DownloadManager.record(for: video.videoId, in: modelContext)
            if let record, DownloadManager.isPlayableOffline(record) {
                Label("ダウンロード済み", systemImage: "arrow.down.circle.fill")
            } else if DownloadManager.shared.isDownloading(video.videoId) || record?.state == .downloading {
                Label("ダウンロード中…", systemImage: "arrow.down.circle.dotted")
            } else {
                Button {
                    DownloadManager.shared.startDownload(video: video, modelContext: modelContext)
                    controller.bumpFade()
                } label: {
                    Label("ダウンロード", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    // MARK: - ViewModel バインディング

    private var loopingBinding: Binding<Bool> {
        Binding(
            get: { vm.isLooping },
            set: { _ in
                vm.toggleLoop()
                controller.bumpFade()
            }
        )
    }

    private var autoPlayNextBinding: Binding<Bool> {
        Binding(
            get: { vm.autoPlayNext },
            set: { _ in
                vm.toggleAutoPlayNext()
                controller.bumpFade()
            }
        )
    }

    private var audioOnlyBinding: Binding<Bool> {
        Binding(
            get: { vm.isAudioOnly },
            set: { _ in
                vm.toggleAudioOnly()
                controller.bumpFade()
            }
        )
    }

    // MARK: - ヘルパー

    /// 時刻表示に使う値（スクラブ中はプレビュー位置）
    private var displayedTime: Double {
        scrubPreviewTime ?? currentTime
    }

    private func togglePlay() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
        } else {
            player.play()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: - ライフサイクル

    private func setup() {
        rebindObservers()
    }

    private func teardown() {
        removeObservers()
    }

    /// 動画切替時や初回表示時に observer を貼り直す
    private func rebindObservers() {
        removeObservers()
        guard let player else { return }

        // 再生位置監視（0.25 秒間隔）
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                // スクラブ中は currentTime を更新しない（つまみのちらつき防止）
                guard !controller.isScrubbing else { return }
                if time.isNumeric {
                    currentTime = time.seconds
                }
                if let d = player.currentItem?.duration, d.isNumeric, d.seconds > 0 {
                    duration = d.seconds
                }
                isPlaying = player.rate > 0
            }
        }

        // rate 変更で isPlaying を即時更新
        rateObserverToken = NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification,
            object: player,
            queue: .main
        ) { _ in
            Task { @MainActor in
                isPlaying = player.rate > 0
            }
        }

        // バッファリング状態を KVO で監視
        if let item = player.currentItem {
            itemBufferObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { item, _ in
                Task { @MainActor in
                    // 再生中かつ「追いつけない」時のみバッファ表示
                    isBuffering = !item.isPlaybackLikelyToKeepUp && (vm.player?.rate ?? 0) > 0
                }
            }
        }

        // 初期値
        isPlaying = player.rate > 0
        if let d = player.currentItem?.duration, d.isNumeric {
            duration = d.seconds
        }
        currentTime = player.currentTime().seconds
    }

    private func removeObservers() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        if let token = rateObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        rateObserverToken = nil
        itemBufferObservation?.invalidate()
        itemBufferObservation = nil
    }
}

