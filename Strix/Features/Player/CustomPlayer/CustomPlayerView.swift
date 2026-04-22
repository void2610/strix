//
//  CustomPlayerView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/22.
//

import SwiftUI
import AVFoundation

/// YouTube 風のカスタムプレイヤー本体。
/// AVPlayerLayer で映像を描画し、SwiftUI でオーバーレイコントロールを重ねる。
///
/// Phase 1 の最小構成:
///  - 映像表示
///  - タップでオーバーレイ表示/非表示
///  - 中央: 再生/停止
///  - 下部: シークバー + 時刻
///  - バックグラウンド再生継続
struct CustomPlayerView: View {
    let player: AVPlayer

    @State private var controller = PlayerOverlayController()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying: Bool = false
    /// スクラブ中にユーザーが触っている位置（時刻表示用、nil なら currentTime を表示）
    @State private var scrubPreviewTime: Double? = nil

    /// バックグラウンド再生管理（AVPlayer と lifecycle を揃える）
    @State private var backgroundObserver: PlayerBackgroundObserver?
    /// PeriodicTimeObserver 解除用トークン
    @State private var timeObserverToken: Any?
    /// player.rate 監視用
    @State private var rateObserverToken: NSObjectProtocol?

    var body: some View {
        ZStack {
            // MARK: 映像
            PlayerLayerView(player: player) { uiView in
                backgroundObserver?.layerView = uiView
            }

            // MARK: オーバーレイ背景（フェード）
            Color.black.opacity(controller.isVisible ? 0.35 : 0)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.2), value: controller.isVisible)

            // MARK: オーバーレイ UI
            overlay
                .opacity(controller.isVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: controller.isVisible)
                .allowsHitTesting(controller.isVisible)
        }
        // プレイヤー背景をタップでオーバーレイ表示/非表示（最下層に配置して子ボタンを邪魔しない）
        .contentShape(Rectangle())
        .onTapGesture { controller.tapped() }
        .environment(controller)
        .onAppear { setup() }
        .onDisappear { teardown() }
    }

    // MARK: - オーバーレイ UI

    private var overlay: some View {
        ZStack {
            // 中央: 再生/停止
            Button {
                togglePlay()
                controller.bumpFade()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.25), in: Circle())
            }
            .buttonStyle(.plain)

            // 下部: シークバー + 時刻
            VStack(spacing: 0) {
                Spacer()
                bottomBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    )
            }
        }
    }

    private var bottomBar: some View {
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
    }

    // MARK: - ヘルパー

    /// 時刻表示に使う値（スクラブ中はプレビュー位置）
    private var displayedTime: Double {
        scrubPreviewTime ?? currentTime
    }

    private func togglePlay() {
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
        // バックグラウンド再生
        backgroundObserver = PlayerBackgroundObserver(player: player)

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

        // 初期値
        isPlaying = player.rate > 0
        if let d = player.currentItem?.duration, d.isNumeric {
            duration = d.seconds
        }
        currentTime = player.currentTime().seconds
    }

    private func teardown() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = rateObserverToken {
            NotificationCenter.default.removeObserver(token)
            rateObserverToken = nil
        }
        backgroundObserver = nil
    }
}
