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
    }

    /// 現在コントロール対象の AVPlayer
    private weak var player: AVPlayer?
    /// 再生位置の定期更新タスク
    private var positionUpdateTask: Task<Void, Never>?

    // MARK: - 外部インターフェース

    /// 動画の再生開始時に呼ぶ。Now Playing 情報を設定してリモートコマンドを有効化する。
    func start(player: AVPlayer, title: String, thumbnailURL: String) {
        self.player = player
        updateNowPlayingInfo(title: title, thumbnailURL: thumbnailURL)
        startPositionUpdates()
    }

    /// 動画停止・画面離脱時に呼ぶ。Now Playing 情報とタスクをクリアする。
    func stop() {
        positionUpdateTask?.cancel()
        positionUpdateTask = nil
        player = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Now Playing 情報

    private func updateNowPlayingInfo(title: String, thumbnailURL: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:          title,
            MPMediaItemPropertyMediaType:      MPMediaType.anyVideo.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackRate: player?.rate ?? 0,
        ]

        // 再生時間・現在位置
        if let duration = player?.currentItem?.duration,
           duration.isNumeric {
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
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    // MARK: - リモートコマンド（コントロールセンター・ヘッドフォンボタン等）

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // 再生
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
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
            if player.rate == 0 { player.play() } else { player.pause() }
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
