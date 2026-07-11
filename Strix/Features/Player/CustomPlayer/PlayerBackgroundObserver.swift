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
/// 旧 `_PlayerViewController` の didEnterBackground / willEnterForeground と同じ役割。
///
/// Task/Async を挟むと iOS の自動 pause と順序が前後して音声が止まるため、
/// @objc selector で同期実行されるようにする（NSObject 継承）。
final class PlayerBackgroundObserver: NSObject {
    /// 対象の UIView（AVPlayerLayer を持つ）
    weak var layerView: PlayerLayerUIView?
    private let player: AVPlayer
    /// true を返す間はバックグラウンドで detach せず、PiP に映像継続を委ねる
    private let pipHandlesBackground: (() -> Bool)?
    /// バックグラウンド移行時に再生中だったか（復帰時の再開判定用）
    private var wasPlaying = false

    init(player: AVPlayer, pipHandlesBackground: (() -> Bool)? = nil) {
        self.player = player
        self.pipHandlesBackground = pipHandlesBackground
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func didEnterBackground() {
        // PiP が映像継続を担う場合は detach せず、自動 PiP に委ねる
        if pipHandlesBackground?() == true { return }
        wasPlaying = player.rate > 0
        // layer から切り離して iOS の自動停止を回避
        layerView?.detachPlayer()
        // detach 時に内部で pause される場合があるため明示的に再生を継続
        if wasPlaying {
            player.play()
        }
    }

    @objc private func willEnterForeground() {
        // layer に再接続して映像表示を再開
        if let layerView {
            layerView.attach(player: player)
        }
        if wasPlaying {
            player.play()
        }
        wasPlaying = false
    }
}
