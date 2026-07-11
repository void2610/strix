//
//  PlayerPiPController.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/07/11.
//

import Foundation
import AVKit

/// AVPlayerLayer に紐づく Picture in Picture を管理する。
/// バックグラウンド移行時の自動 PiP と、手動ボタンからの開始/停止に対応する。
@MainActor
@Observable
final class PiPManager: NSObject, AVPictureInPictureControllerDelegate {
    private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    /// PiP 実行中か（ボタンのアイコン切替に使う）
    private(set) var isActive = false

    @ObservationIgnored private var controller: AVPictureInPictureController?

    /// AVPlayerLayer 生成後に PiP コントローラを構築する。同一 layer に対しては再構築しない。
    func configure(with layer: AVPlayerLayer) {
        guard isSupported, controller?.playerLayer !== layer else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        // アプリがバックグラウンドへ移行した際に自動で PiP を開始する
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
    }

    /// 手動 PiP ボタンから呼ぶ。実行中なら停止、そうでなければ開始する。
    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    // MARK: - AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    /// PiP から元の再生画面へ復帰する。UI は常設のため即座に完了扱いにする。
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
