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
            // 手動キューの種化に使えるよう、ロード完了後の動画を coordinator に反映する
            coordinator.currentVideoItem = vm.currentVideoItem ?? coordinator.currentVideoItem
        }
        .onChange(of: coordinator.playlistQueue) { _, queue in
            // 再生中にキューが編集された場合に VM 側へ同期する（同一動画なら再ロードは起きない）
            vm.playlistQueue = queue
            vm.playlistIndex = coordinator.initialIndex
        }
        .onChange(of: coordinator.mode) { _, newMode in
            if newMode == .hidden { dismissPlayer() }
        }
        .onChange(of: vm.autoNextVideoID) { _, nextID in
            guard let nextID else { return }
            vm.autoNextVideoID = nil
            // プレイリスト内遷移では vm 側で更新済みのインデックスを coordinator にも反映し、
            // task(id:) 再実行時に initialIndex へ巻き戻されるのを防ぐ
            coordinator.initialIndex = vm.playlistIndex
            coordinator.currentVideoID = nextID
        }
    }

    // MARK: - フルスクリーンプレイヤー

    @ViewBuilder
    private func fullScreenPlayer(geo: GeometryProxy) -> some View {
        ZStack(alignment: .top) {
            // フルスクリーン時は黒背景、通常時はシステム背景
            (coordinator.isFullScreen ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()

            // NavigationStack で包まない。UIKit の画面管理は画面上の位置から安全領域を計算し直すため、引いて下げると中身が押し戻されて暴れる
            PlayerView(videoID: coordinator.currentVideoID ?? "", vm: vm)
                // 外側で安全領域を無視しているので、引いている間も変わらない窓の値で付け直す
                .safeAreaPadding(windowSafeAreaInsets)
        }
        .offset(y: coordinator.dragOffset)
        .transition(.move(edge: .bottom))
    }

    private var windowSafeAreaInsets: EdgeInsets {
        let insets = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets ?? .zero
        return EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
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
