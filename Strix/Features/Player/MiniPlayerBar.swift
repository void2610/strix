//
//  MiniPlayerBar.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/18.
//

import SwiftUI
import AVFoundation
import UIKit

// MARK: - ミニプレイヤー用の軽量映像ビュー

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

// MARK: - UIPanGestureRecognizer ベースのドラッグハンドラ

/// SwiftUI の DragGesture は内部で遅延があるため、
/// UIKit の UIPanGestureRecognizer を直接使って即時追従を実現する。
private struct UIPanGesture: UIGestureRecognizerRepresentable {
    var onChange: (_ translation: CGSize, _ velocity: CGSize) -> Void
    var onEnd: (_ translation: CGSize, _ velocity: CGSize) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        let t = recognizer.translation(in: recognizer.view)
        let v = recognizer.velocity(in: recognizer.view)
        let translation = CGSize(width: t.x, height: t.y)
        let velocity = CGSize(width: v.x, height: v.y)

        switch recognizer.state {
        case .changed:
            onChange(translation, velocity)
        case .ended, .cancelled:
            onEnd(translation, velocity)
            recognizer.setTranslation(.zero, in: recognizer.view)
        default:
            break
        }
    }
}

// MARK: - ミニプレイヤー

struct MiniPlayerView: View {
    let vm: PlayerViewModel
    let onTap: () -> Void
    let onClose: () -> Void

    private let videoWidth: CGFloat = 160
    private let videoHeight: CGFloat = 90
    private let edgePadding: CGFloat = 12

    /// 現在のオフセット（右下の初期位置からの相対値）
    @State private var offset: CGSize = .zero
    /// ドラッグ中の一時オフセット
    @State private var dragDelta: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let safeArea = geo.safeAreaInsets
            let screenW = geo.size.width
            let screenH = geo.size.height

            // 初期位置（右下）
            let baseX = screenW - videoWidth - edgePadding - safeArea.trailing
            let baseY = screenH - videoHeight - edgePadding - safeArea.bottom - 49

            // クランプ範囲（offset として）
            let minOX = edgePadding + safeArea.leading - baseX
            let maxOX: CGFloat = 0
            let minOY = edgePadding + safeArea.top - baseY
            let maxOY: CGFloat = 0

            let totalX = offset.width + dragDelta.width
            let totalY = offset.height + dragDelta.height

            // ゴムバンド表示
            let displayX = baseX + rubberBand(totalX, min: minOX, max: maxOX)
            let displayY = baseY + rubberBand(totalY, min: minOY, max: maxOY)

            Group {
                if let player = vm.player {
                    MiniPlayerVideoView(player: player)
                } else {
                    Color.black
                }
            }
            .frame(width: videoWidth, height: videoHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .offset(x: 6, y: -6)
            }
            .frame(width: videoWidth, height: videoHeight)
            .position(x: displayX + videoWidth / 2, y: displayY + videoHeight / 2)
            .gesture(
                UIPanGesture(
                    onChange: { translation, _ in
                        dragDelta = translation
                    },
                    onEnd: { translation, velocity in
                        // ドラッグ分を offset に統合
                        let newW = offset.width + translation.width
                        let newH = offset.height + translation.height
                        dragDelta = .zero

                        // 速度から慣性の着地点を計算（減速距離）
                        let decel: CGFloat = 800
                        let vxDist = velocity.width * abs(velocity.width) / (2 * decel)
                        let vyDist = velocity.height * abs(velocity.height) / (2 * decel)
                        let targetW = clamp(newW + vxDist, min: minOX, max: maxOX)
                        let targetH = clamp(newH + vyDist, min: minOY, max: maxOY)

                        // アニメーションなしで統合位置を設定
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            offset = CGSize(width: newW, height: newH)
                        }

                        // スプリングで最終位置へ
                        withAnimation(.interpolatingSpring(stiffness: 180, damping: 22)) {
                            offset = CGSize(width: targetW, height: targetH)
                        }
                    }
                )
            )
            .onTapGesture(perform: onTap)
        }
        .ignoresSafeArea()
    }

    private func rubberBand(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        if value < lo {
            let d = lo - value
            return lo - d / (1 + d * 0.008)
        } else if value > hi {
            let d = value - hi
            return hi + d / (1 + d * 0.008)
        }
        return value
    }

    private func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lo), hi)
    }
}
