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
                    .transition(.opacity)
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
                }
            }
        }
        .offset(y: coordinator.dragOffset)
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
