//
//  PlayerContainerView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/18.
//

import SwiftUI
import AVFoundation

/// RootTabView のオーバーレイとして配置され、フルスクリーン/ミニプレイヤーのモード遷移を管理する。
struct PlayerContainerView: View {
    @Environment(PlayerCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext

    @State private var vm = PlayerViewModel()
    /// ドラッグ中のオフセット。onChanged でアニメーションなしに直接更新。
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let tabBarHeight: CGFloat = 49 + geo.safeAreaInsets.bottom

            ZStack(alignment: .bottom) {
                if coordinator.mode == .fullScreen {
                    fullScreenPlayer(geo: geo)
                }

                if coordinator.mode == .miniPlayer {
                    MiniPlayerView(
                        vm: vm,
                        onTap: {
                            withAnimation(.snappy(duration: 0.3)) {
                                coordinator.expand()
                            }
                        },
                        onClose: { dismissPlayer() }
                    )
                    .padding(.trailing, 12)
                    .padding(.bottom, tabBarHeight + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .task(id: coordinator.currentVideoID) {
            guard let videoID = coordinator.currentVideoID,
                  vm.loadedVideoID != videoID else { return }
            if !coordinator.playlistQueue.isEmpty {
                vm.playlistQueue = coordinator.playlistQueue
                vm.playlistIndex = coordinator.initialIndex
            }
            await vm.load(videoID: videoID, modelContext: modelContext)
        }
        .onChange(of: coordinator.mode) { _, newMode in
            if newMode == .hidden { dismissPlayer() }
        }
        .onChange(of: vm.autoNextVideoID) { _, nextID in
            guard let nextID else { return }
            vm.autoNextVideoID = nil
            coordinator.currentVideoID = nextID
        }
    }

    // MARK: - フルスクリーンプレイヤー

    @ViewBuilder
    private func fullScreenPlayer(geo: GeometryProxy) -> some View {
        let screenHeight = geo.size.height

        ZStack(alignment: .top) {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                NavigationStack {
                    PlayerView(videoID: coordinator.currentVideoID ?? "", vm: vm)
                        .navigationDestination(for: ChannelDestination.self) { dest in
                            ChannelView(channelId: dest.channelId)
                        }
                }
            }

            // 映像エリア上の透明ドラッグキャッチャー
            // 画面幅 × 9/16（映像）+ ナビバー・safe area 分を加算して映像全体をカバー
            Color.clear
                .frame(height: geo.size.width * 9 / 16 + geo.safeAreaInsets.top + 44)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .global)
                        .onChanged { value in
                            let ty = value.translation.height
                            if ty > 0 {
                                // アニメーションなしで直接追従
                                var t = Transaction()
                                t.disablesAnimations = true
                                withTransaction(t) {
                                    dragOffset = ty
                                }
                            }
                        }
                        .onEnded { value in
                            let ty = value.translation.height
                            let vy = value.predictedEndTranslation.height
                            if ty > screenHeight * 0.15 || vy > 300 {
                                // 画面外へ飛ばしてからミニプレイヤーに切り替える
                                withAnimation(.easeOut(duration: 0.2)) {
                                    dragOffset = screenHeight
                                } completion: {
                                    dragOffset = 0
                                    coordinator.minimize()
                                }
                            } else {
                                // 元に戻す
                                withAnimation(.snappy(duration: 0.25)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
        }
        .offset(y: dragOffset)
        .transition(.move(edge: .bottom))
    }

    // MARK: - プレイヤー終了

    private func dismissPlayer() {
        vm.savePlaybackPosition(modelContext: modelContext)
        vm.player?.pause()
        NowPlayingManager.shared.stop()
        LiveActivityManager.shared.stop()
        vm = PlayerViewModel()
        coordinator.dismiss()
    }
}
