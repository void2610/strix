//
//  PlayerBackgroundObserver.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/22.
//

import Foundation
import AVFoundation
import UIKit

/// バックグラウンド移行時に AVPlayerLayer から AVPlayer を切り離して
/// iOS の自動停止を回避し、直後に再生を再開する。
/// 既存の `_PlayerViewController` の didEnterBackground / willEnterForeground と同じ役割。
@MainActor
final class PlayerBackgroundObserver {
    /// 対象の UIView（AVPlayerLayer を持つ）
    weak var layerView: PlayerLayerUIView?
    private let player: AVPlayer
    /// バックグラウンド移行時に再生中だったか（復帰時の再開判定用）
    private var wasPlaying = false

    private var didEnterBackgroundToken: NSObjectProtocol?
    private var willEnterForegroundToken: NSObjectProtocol?

    init(player: AVPlayer) {
        self.player = player
        didEnterBackgroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.didEnterBackground() }
        }
        willEnterForegroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.willEnterForeground() }
        }
    }

    deinit {
        if let t = didEnterBackgroundToken { NotificationCenter.default.removeObserver(t) }
        if let t = willEnterForegroundToken { NotificationCenter.default.removeObserver(t) }
    }

    private func didEnterBackground() {
        wasPlaying = player.rate > 0
        // layer から切り離して iOS の自動停止を回避
        layerView?.detachPlayer()
        // detach 後に内部で pause される場合があるため明示的に再生を継続
        if wasPlaying {
            player.play()
        }
    }

    private func willEnterForeground() {
        // layer に再接続して映像表示を再開
        layerView?.attach(player: player)
        if wasPlaying {
            player.play()
        }
        wasPlaying = false
    }
}
