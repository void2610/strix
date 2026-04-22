//
//  PlayerLayerView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/22.
//

import SwiftUI
import AVFoundation
import UIKit

/// AVPlayerLayer を持つ UIView。AVPlayerViewController を使わずに映像だけを表示する。
/// バックグラウンド移行時に `detachPlayer()` で layer から AVPlayer を切り離すことで
/// iOS の自動停止を回避する。復帰時は `attachPlayer(_:)` で再接続する。
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func attach(player: AVPlayer) {
        playerLayer.player = player
        // 16:9 などのアスペクト比を維持しつつ枠内に収める
        playerLayer.videoGravity = .resizeAspect
    }

    func detachPlayer() {
        playerLayer.player = nil
    }
}

/// SwiftUI から使うための UIViewRepresentable ラッパー。
/// `player` 変更時は updateUIView で AVPlayerLayer に反映する。
/// `observer` に UIView 参照を渡すことで、View 側から detachPlayer / attachPlayer を呼べる。
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// UIView の参照を外部（PlayerBackgroundObserver など）に渡すためのフック
    var onMakeView: ((PlayerLayerUIView) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.attach(player: player)
        onMakeView?(view)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        // AVPlayer が差し替わった場合の追従
        if uiView.playerLayer.player !== player {
            uiView.attach(player: player)
        }
    }
}
