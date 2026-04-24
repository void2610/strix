//
//  CustomPlayer+Gestures.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/24.
//

import SwiftUI

// MARK: - ダブルタップスキップ モデル

enum SkipSide { case left, right }

struct SkipRipple: Equatable {
    var side: SkipSide
    var amount: Int
    /// 連続タップでアニメーションを再始動させるための id
    var triggerID: UUID = UUID()
}

/// ダブルタップスキップの波紋 + 秒数ラベル
struct SkipRippleView: View {
    let ripple: SkipRipple
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            // 円の直径: 画面に対して十分大きく、アニメ後に広がっても端まで到達する
            let diameter = max(width, height) * 1.1

            // 波紋本体のみ。方向・秒数表示は中央のスキップボタンが担うため省略する
            Circle()
                .fill(.white.opacity(animate ? 0 : 0.2))
                .frame(width: diameter, height: diameter)
                .scaleEffect(animate ? 1.05 : 0.4)
                .position(
                    x: ripple.side == .left ? 0 : width,
                    y: height / 2
                )
        }
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { animate = true } }
    }
}
