//
//  PlayerOverlayController.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/22.
//

import Foundation

/// プレイヤーのオーバーレイ表示状態とフェードタイマーを管理する。
/// シークバー操作中・設定メニュー展開中は自動フェードを抑制する。
@MainActor
@Observable
final class PlayerOverlayController {
    /// オーバーレイ（上部バー・中央ボタン・下部シークバー）が見えているか
    var isVisible: Bool = true
    /// シークバー操作中（scrubbing）はフェードを抑制
    var isScrubbing: Bool = false
    /// ⋯ メニュー展開中はフェードを抑制（Phase 3 で使用）
    var isSettingsOpen: Bool = false

    private var fadeTask: Task<Void, Never>?

    /// プレイヤー領域がタップされた時の挙動: 表示 ↔ 非表示をトグル
    func tapped() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// オーバーレイを表示してフェードタイマーを仕込む
    func show() {
        isVisible = true
        scheduleFade()
    }

    /// オーバーレイを即座に非表示にする
    func hide() {
        isVisible = false
        fadeTask?.cancel()
        fadeTask = nil
    }

    /// タイマー再セット（操作のたびに呼んで非表示までの 3 秒をリセット）
    func bumpFade() {
        guard isVisible else { return }
        scheduleFade()
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            // スクラブ中・設定展開中はフェードを保留
            if self.isScrubbing || self.isSettingsOpen {
                self.scheduleFade()
                return
            }
            self.isVisible = false
        }
    }
}
