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
    /// 現在再生中の動画（手動キューの種化に使う）。PlayerContainerView がロード後に更新する。
    var currentVideoItem: VideoItem?
    /// フルスクリーン時の下方向ドラッグオフセット（PlayerView の playerSection から更新）
    var dragOffset: CGFloat = 0
    /// 現在選択中のタブインデックス（RootTabView からバインド）
    var selectedTab: Int = 0
    /// プレイヤーからチャンネルページへ遷移する際の保留先
    var pendingChannelNavigation: ChannelDestination?
    /// フルスクリーン表示中（横回転）
    var isFullScreen: Bool = false

    /// 任意のビューから動画再生を開始する
    func play(videoID: String, playlistQueue: [VideoItem] = [], initialIndex: Int = 0) {
        self.playlistQueue = playlistQueue
        self.initialIndex = initialIndex
        self.currentVideoID = videoID
        self.mode = .fullScreen
    }

    /// VideoItem 付きで再生を開始する（手動キューの種化に使う現在動画を保持する）
    func play(_ video: VideoItem, playlistQueue: [VideoItem] = [], initialIndex: Int = 0) {
        self.currentVideoItem = playlistQueue.isEmpty ? video : playlistQueue[safe: initialIndex] ?? video
        play(videoID: video.videoId, playlistQueue: playlistQueue, initialIndex: initialIndex)
    }

    // MARK: - 手動キュー操作

    /// 「次に再生」: 現在の再生位置の直後に挿入する。未再生なら即再生する。
    func playNext(_ video: VideoItem) {
        guard mode != .hidden else { play(video); return }
        ensureQueueSeeded()
        let insertAt = min(initialIndex + 1, playlistQueue.count)
        playlistQueue.insert(video, at: insertAt)
    }

    /// 「キューに追加」: キュー末尾に追加する。未再生なら即再生する。
    func enqueue(_ video: VideoItem) {
        guard mode != .hidden else { play(video); return }
        ensureQueueSeeded()
        playlistQueue.append(video)
    }

    /// 単体再生中（キューが空）なら、現在動画を先頭にしたキューへ変換する
    private func ensureQueueSeeded() {
        guard playlistQueue.isEmpty else { return }
        if let current = currentVideoItem {
            playlistQueue = [current]
        } else if let id = currentVideoID {
            playlistQueue = [VideoItem(videoId: id, title: id)]
        }
        initialIndex = 0
    }

    /// キューから削除する（再生中の項目は削除しない）
    func removeFromQueue(at index: Int) {
        guard playlistQueue.indices.contains(index), index != initialIndex else { return }
        playlistQueue.remove(at: index)
        if index < initialIndex { initialIndex -= 1 }
    }

    /// onDelete 用に複数オフセットをまとめて削除する
    func removeFromQueue(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) { removeFromQueue(at: index) }
    }

    /// キュー内を並び替える（再生中の項目の位置を維持する）
    func moveInQueue(from source: IndexSet, to destination: Int) {
        let currentID = playlistQueue[safe: initialIndex]?.videoId
        playlistQueue.move(fromOffsets: source, toOffset: destination)
        if let currentID, let idx = playlistQueue.firstIndex(where: { $0.videoId == currentID }) {
            initialIndex = idx
        }
    }

    /// 指定したキュー位置へジャンプする
    func jumpTo(index: Int) {
        guard playlistQueue.indices.contains(index) else { return }
        initialIndex = index
        currentVideoItem = playlistQueue[index]
        currentVideoID = playlistQueue[index].videoId
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
        currentVideoItem = nil
        playlistQueue = []
        initialIndex = 0
        isFullScreen = false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
