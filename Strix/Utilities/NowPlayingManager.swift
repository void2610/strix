//
//  NowPlayingManager.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import AVFoundation
import MediaPlayer

/// コントロールセンター・ロック画面・ダイナミックアイランドのNow Playing情報と
/// リモートコマンド（再生/一時停止/シーク）を管理するシングルトン。
@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()
    private init() {
        setupRemoteCommands()
        setupAudioSessionObservers()
    }

    /// 現在コントロール対象の AVPlayer（strong で保持し、次の start() 呼び出しまで確実に停止できるようにする）
    private var player: AVPlayer?
    /// 再生位置の定期更新タスク
    private var positionUpdateTask: Task<Void, Never>?

    // MARK: - 外部インターフェース

    /// 動画の再生開始時に呼ぶ。Now Playing 情報を設定してリモートコマンドを有効化する。
    func start(player: AVPlayer, title: String, thumbnailURL: String) {
        // 前の動画が再生中の場合は停止して同時再生を防ぐ
        self.player?.pause()
        self.player = player
        activateAudioSession()
        updateNowPlayingInfo(title: title, thumbnailURL: thumbnailURL)
        startPositionUpdates()
    }

    /// 動画停止・画面離脱時に呼ぶ。Now Playing 情報とタスクをクリアする。
    /// player 参照は nil にしない。次の start() が呼ばれるまで strong 参照を保持することで、
    /// PiP 中に onDisappear → stop() で参照が失われても start(new) で旧プレイヤーを確実に停止できる。
    func stop() {
        positionUpdateTask?.cancel()
        positionUpdateTask = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - AVAudioSession

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            strixLog(" AVAudioSession アクティブ化失敗: \(error)")
        }
    }

    /// AVAudioSession の割り込み・ルート変更通知を登録する
    private func setupAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(notification)
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(notification)
            }
        }
    }

    /// 割り込み（電話・他アプリ音声など）への対処
    private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // 割り込み開始: プレイヤーは自動停止するため何もしない
            strixLog(" AVAudioSession 割り込み開始")

        case .ended:
            // 割り込み終了: セッションを再アクティブ化して再生を再開する
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            strixLog(" AVAudioSession 割り込み終了 (shouldResume: \(options.contains(.shouldResume)))")
            activateAudioSession()
            if options.contains(.shouldResume) {
                player?.play()
            }

        @unknown default:
            break
        }
    }

    /// ヘッドフォン抜き差しなどのルート変更への対処
    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        // イヤフォン・ヘッドフォンが抜かれたときは停止（標準的な動作）
        if reason == .oldDeviceUnavailable {
            strixLog(" オーディオルート変更: 出力デバイス切断 → 再生停止")
            player?.pause()
        }
    }

    // MARK: - Now Playing 情報

    private func updateNowPlayingInfo(title: String, thumbnailURL: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:             title,
            MPMediaItemPropertyMediaType:         MPMediaType.anyVideo.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackRate: player?.rate ?? 0,
        ]

        // 再生時間・現在位置
        if let duration = player?.currentItem?.duration, duration.isNumeric {
            info[MPMediaItemPropertyPlaybackDuration] = CMTimeGetSeconds(duration)
        }
        if let current = player?.currentTime() {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = CMTimeGetSeconds(current)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // サムネイルを非同期で取得して後からセットする
        if let url = URL(string: thumbnailURL) {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let uiImage = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }

    /// 再生位置を 0.5 秒ごとに更新する
    private func startPositionUpdates() {
        positionUpdateTask?.cancel()
        positionUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let player = self.player else { break }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = CMTimeGetSeconds(player.currentTime())
                info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
                // HLS は再生開始直後に duration が不明なため、取得できたタイミングで設定する
                // duration が未設定だとロック画面のシークバーが非アクティブになる
                if info[MPMediaItemPropertyPlaybackDuration] == nil,
                   let duration = player.currentItem?.duration,
                   duration.isNumeric {
                    info[MPMediaItemPropertyPlaybackDuration] = CMTimeGetSeconds(duration)
                }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    // MARK: - リモートコマンド（コントロールセンター・ヘッドフォンボタン等）

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // 再生: セッションを再アクティブ化してから play()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.activateAudioSession()
            self?.player?.play()
            return .success
        }

        // 一時停止
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            return .success
        }

        // トグル再生/一時停止
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            if player.rate == 0 {
                self?.activateAudioSession()
                player.play()
            } else {
                player.pause()
            }
            return .success
        }

        // 15秒スキップ
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let player = self?.player,
                  let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let newTime = CMTimeAdd(player.currentTime(), CMTimeMakeWithSeconds(e.interval, preferredTimescale: 1))
            player.seek(to: newTime)
            return .success
        }

        // 15秒戻し
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let player = self?.player,
                  let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let newTime = CMTimeSubtract(player.currentTime(), CMTimeMakeWithSeconds(e.interval, preferredTimescale: 1))
            player.seek(to: newTime)
            return .success
        }

        // シークバー操作
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let player = self?.player,
                  let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player.seek(to: CMTimeMakeWithSeconds(e.positionTime, preferredTimescale: 1))
            return .success
        }
    }
}
