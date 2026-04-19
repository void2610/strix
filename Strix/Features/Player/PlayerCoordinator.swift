//
//  PlayerCoordinator.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/18.
//

import SwiftUI

/// アプリ全体のプレイヤー状態を管理するコーディネーター。
/// RootTabView で `.environment()` 経由で注入し、どのタブからでも再生を開始できる。
@MainActor
@Observable
final class PlayerCoordinator {
    enum PlayerMode {
        case hidden      // プレイヤー非表示
        case fullScreen  // フルスクリーン表示
        case miniPlayer  // ミニプレイヤーバー表示
    }

    var mode: PlayerMode = .hidden
    var currentVideoID: String?
    var playlistQueue: [VideoItem] = []
    var initialIndex: Int = 0
    /// フルスクリーン時の下方向ドラッグオフセット（PlayerView の playerSection から更新）
    var dragOffset: CGFloat = 0
    /// 現在選択中のタブインデックス（RootTabView からバインド）
    var selectedTab: Int = 0
    /// プレイヤーからチャンネルページへ遷移する際の保留先
    var pendingChannelNavigation: ChannelDestination?

    /// 任意のビューから動画再生を開始する
    func play(videoID: String, playlistQueue: [VideoItem] = [], initialIndex: Int = 0) {
        self.playlistQueue = playlistQueue
        self.initialIndex = initialIndex
        self.currentVideoID = videoID
        self.mode = .fullScreen
    }

    /// フルスクリーンからミニプレイヤーに最小化する
    func minimize() {
        mode = .miniPlayer
    }

    /// プレイヤーを最小化してチャンネルページへ遷移する
    func navigateToChannel(_ destination: ChannelDestination) {
        pendingChannelNavigation = destination
        minimize()
    }

    /// ミニプレイヤーからフルスクリーンに展開する
    func expand() {
        mode = .fullScreen
    }

    /// プレイヤーを完全に閉じる
    func dismiss() {
        mode = .hidden
        currentVideoID = nil
        playlistQueue = []
        initialIndex = 0
    }
}
