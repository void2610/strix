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
    private init() {
        // ダイナミックアイランドの倍速ボタン（TogglePlaybackSpeedIntent）からの要求を受ける
        NotificationCenter.default.addObserver(
            forName: .strixTogglePlaybackSpeed,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.onSpeedToggle?()
            }
        }
    }

    private var activity: Activity<StrixActivityAttributes>?
    /// 倍速トグル要求時に呼ばれるハンドラ（PlayerViewModel が start() で登録する）
    private var onSpeedToggle: (() -> Void)?

    // MARK: - 外部インターフェース

    /// 再生開始時に Live Activity を起動する。
    /// - Parameter onSpeedToggle: ダイナミックアイランドの倍速ボタンが押されたときに呼ばれる
    func start(title: String, channelName: String, thumbnailURL: String, player: AVPlayer,
               playbackRate: Float = 1.0, onSpeedToggle: (() -> Void)? = nil) {
        self.onSpeedToggle = onSpeedToggle
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
            durationSeconds: durationSeconds(of: player),
            playbackRate: Double(playbackRate)
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

    /// 再生速度が変化したときにダイナミックアイランドの表示を更新する。
    func updatePlaybackRate(_ rate: Float) {
        guard let activity else { return }
        Task {
            var state = await activity.content.state
            state.playbackRate = Double(rate)
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// 再生停止時に Live Activity を終了する。
    func stop() {
        onSpeedToggle = nil
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
