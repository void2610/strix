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
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func attach(player: AVPlayer) {
        playerLayer.player = player
        // 16:9 などのアスペクト比を維持しつつ枠内に収める
        playerLayer.videoGravity = .resizeAspect
    }
}

/// SwiftUI から使う UIViewRepresentable ラッパー。
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// AVPlayerLayer 生成/差し替え時に通知する（PiP コントローラ構築用）
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.attach(player: player)
        onLayerReady?(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.attach(player: player)
        }
        onLayerReady?(uiView.playerLayer)
    }
}
