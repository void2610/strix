//
//  PlayerSeekBar.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/22.
//

import SwiftUI

/// YouTube 風のシークバー。ドラッグで任意位置にシークできる。
/// スクラブ中は `controller.isScrubbing = true` をセットしてオーバーレイのフェードを抑制する。
///
/// 表示する進捗は親から渡される `currentTime` 1 本で決まる。
/// 親は `scrubPreviewTime ?? playerTime` のように解決済みの値を渡すこと。
/// 終端処理（`isScrubbing = false` とプレビュー値の解除）はシーク完了後に親側で行う。
struct PlayerSeekBar: View {
    /// 表示する再生位置（秒）。スクラブ中は親がプレビュー値を渡す。
    let currentTime: Double
    /// 総時間（秒）
    let duration: Double
    /// ドラッグ中の値を親に通知（時刻表示とバー進捗用）
    let onScrub: (Double) -> Void
    /// ドラッグ終了時に確定した秒数でシークを要求する
    let onSeek: (Double) -> Void

    @Environment(PlayerOverlayController.self) private var controller

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = progressRatio
            let knobX = width * progress

            ZStack(alignment: .leading) {
                // 背景トラック
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: controller.isScrubbing ? 5 : 3)

                // 再生済み部分
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, knobX), height: controller.isScrubbing ? 5 : 3)

                // つまみ
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: controller.isScrubbing ? 18 : 12,
                           height: controller.isScrubbing ? 18 : 12)
                    .offset(x: knobX - (controller.isScrubbing ? 9 : 6))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !controller.isScrubbing {
                            controller.isScrubbing = true
                        }
                        let x = min(max(0, value.location.x), width)
                        let t = Double(x / width) * max(duration, 0.001)
                        onScrub(t)
                    }
                    .onEnded { value in
                        let x = min(max(0, value.location.x), width)
                        let t = Double(x / width) * max(duration, 0.001)
                        // isScrubbing とプレビュー解除はシーク完了後に親が行う
                        onSeek(t)
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: controller.isScrubbing)
        }
        .frame(height: 22)
    }

    /// 0.0 - 1.0 の範囲に正規化した再生進捗
    private var progressRatio: Double {
        guard duration > 0 else { return 0 }
        return min(max(0, currentTime / duration), 1)
    }
}
