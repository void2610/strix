//
//  TogglePlaybackSpeedIntent.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/07/02.
//

import AppIntents
import Foundation

/// ダイナミックアイランドの倍速ボタンから実行される App Intent。
/// LiveActivityIntent はアプリ本体のプロセスで実行されるため、
/// NotificationCenter 経由で LiveActivityManager → PlayerViewModel に転送する。
/// メインアプリと Widget Extension の両方でコンパイルされる。
struct TogglePlaybackSpeedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "再生速度を切り替える"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .strixTogglePlaybackSpeed, object: nil)
        }
        return .result()
    }
}

extension Notification.Name {
    /// ダイナミックアイランドからの倍速トグル要求
    static let strixTogglePlaybackSpeed = Notification.Name("strixTogglePlaybackSpeed")
}
