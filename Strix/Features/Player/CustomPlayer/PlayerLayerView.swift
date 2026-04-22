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
/// iOS の自動停止を回避する。復帰時は `attach(player:)` で再接続する。
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

/// SwiftUI から使う UIViewRepresentable ラッパー。
/// バックグラウンド自動停止回避を Coordinator に内包することで、
/// SwiftUI の @State 更新タイミング問題（makeUIView 中の State 代入が次回 body 評価まで反映されない）を回避する。
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.attach(player: player)
        // makeUIView 時点で確実に observer に view を紐付ける
        context.coordinator.bind(layerView: view)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        // AVPlayer が差し替わった場合は coordinator 側も rebind する
        if context.coordinator.currentPlayer !== player {
            context.coordinator.rebind(player: player, layerView: uiView)
        }
        if uiView.playerLayer.player !== player {
            uiView.attach(player: player)
        }
    }

    /// AVPlayerLayer の UIView 参照と、バックグラウンド再生継続用 observer を保持する。
    final class Coordinator {
        private(set) var currentPlayer: AVPlayer
        private var observer: PlayerBackgroundObserver

        init(player: AVPlayer) {
            self.currentPlayer = player
            self.observer = PlayerBackgroundObserver(player: player)
        }

        /// makeUIView の時点で layer view を observer に紐付ける。
        func bind(layerView: PlayerLayerUIView) {
            observer.layerView = layerView
        }

        /// player が別のインスタンスに切り替わった際に observer を再生成する。
        func rebind(player: AVPlayer, layerView: PlayerLayerUIView) {
            self.currentPlayer = player
            self.observer = PlayerBackgroundObserver(player: player)
            self.observer.layerView = layerView
        }
    }
}
