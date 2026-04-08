//
//  LiveActivityManager.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import ActivityKit
import AVFoundation

/// ダイナミックアイランド Live Activity の開始・更新・終了を管理する。
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private init() {}

    private var activity: Activity<StrixActivityAttributes>?

    // MARK: - 外部インターフェース

    /// 再生開始時に Live Activity を起動する。
    func start(title: String, channelName: String, thumbnailURL: String, player: AVPlayer) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            strixLog(" LiveActivity: 端末で Live Activities が無効")
            return
        }

        // 既存の Activity があれば終了してから開始
        Task { await stopCurrent() }

        let initialState = StrixActivityAttributes.ContentState(
            title: title,
            channelName: channelName,
            thumbnailURL: thumbnailURL,
            isPlaying: player.rate != 0,
            elapsedSeconds: CMTimeGetSeconds(player.currentTime()),
            durationSeconds: durationSeconds(of: player)
        )

        do {
            let activity = try Activity.request(
                attributes: StrixActivityAttributes(),
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            self.activity = activity
            strixLog(" LiveActivity 開始: \(activity.id)")
        } catch {
            strixLog(" LiveActivity 開始失敗: \(error)")
        }
    }

    /// 再生状態が変化したときに更新する。
    func update(isPlaying: Bool, player: AVPlayer) {
        guard let activity else { return }
        Task {
            var state = await activity.content.state
            state.isPlaying = isPlaying
            state.elapsedSeconds = CMTimeGetSeconds(player.currentTime())
            state.durationSeconds = durationSeconds(of: player)
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// 再生停止時に Live Activity を終了する。
    func stop() {
        Task { await stopCurrent() }
    }

    // MARK: - プライベート

    private func stopCurrent() async {
        await activity?.end(.init(state: activity!.content.state, staleDate: nil), dismissalPolicy: .immediate)
        activity = nil
    }

    private func durationSeconds(of player: AVPlayer) -> Double {
        guard let duration = player.currentItem?.duration, duration.isNumeric else { return 0 }
        return CMTimeGetSeconds(duration)
    }
}
