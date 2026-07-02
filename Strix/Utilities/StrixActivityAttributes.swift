//
//  StrixActivityAttributes.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import ActivityKit

/// ダイナミックアイランド Live Activity の属性定義。
/// メインアプリと Widget Extension の両方から参照される。
struct StrixActivityAttributes: ActivityAttributes {
    /// 動的に更新するコンテンツ
    struct ContentState: Codable, Hashable {
        var title: String
        var channelName: String
        var thumbnailURL: String
        var isPlaying: Bool
        var elapsedSeconds: Double
        var durationSeconds: Double
        /// 現在の再生速度（1.0・2.0 のほか倍速メニューの任意値）
        var playbackRate: Double = 1.0
    }
}
