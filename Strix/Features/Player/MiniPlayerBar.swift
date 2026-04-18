//
//  MiniPlayerBar.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/18.
//

import SwiftUI
import AVFoundation

// MARK: - ミニプレイヤー用の軽量映像ビュー（コントロールなし）

/// AVPlayerLayer を直接表示する UIView ラッパー。
private struct MiniPlayerVideoView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerUIView: UIView {
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
}

// MARK: - ミニプレイヤー

/// 画面右下に浮かぶ小さな動画ウィンドウ。タップでフルスクリーンに展開。
struct MiniPlayerView: View {
    let vm: PlayerViewModel
    let onTap: () -> Void
    let onClose: () -> Void

    @GestureState private var dragOffset: CGSize = .zero
    @State private var position: CGSize = .zero

    var body: some View {
        Group {
            if let player = vm.player {
                MiniPlayerVideoView(player: player)
            } else {
                Color.black
            }
        }
        .frame(width: 160, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .overlay(alignment: .topTrailing) {
            // 閉じるボタン
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .offset(x: 6, y: -6)
        }
        .onTapGesture(perform: onTap)
        .offset(x: position.width + dragOffset.width,
                y: position.height + dragOffset.height)
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    position.width += value.translation.width
                    position.height += value.translation.height
                }
        )
    }
}
