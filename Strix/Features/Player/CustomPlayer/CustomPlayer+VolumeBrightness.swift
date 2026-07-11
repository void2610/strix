//
//  CustomPlayer+VolumeBrightness.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/07/10.
//

import SwiftUI
import MediaPlayer
import AVFoundation

// MARK: - システム音量コントローラ

/// システム音量を読み書きする。AVAudioSession.outputVolume は読み取り専用のため、
/// 非表示の MPVolumeView 内の UISlider を介して音量を設定する（iOS 標準の手法）。
@MainActor
final class SystemVolumeController {
    private weak var volumeView: MPVolumeView?

    /// SystemVolumeHost（UIViewRepresentable）から生成された MPVolumeView を紐付ける
    func attach(_ view: MPVolumeView) {
        volumeView = view
    }

    private var slider: UISlider? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    /// 現在のシステム音量（0...1）
    var currentVolume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    /// システム音量を設定する（0...1 にクランプ）
    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        // MPVolumeView の UISlider は次の runloop で subviews に揃うことがあるため、実行時に都度取得する
        Task { @MainActor in
            self.slider?.value = clamped
        }
    }
}

/// 音量制御用の MPVolumeView を画面外に配置する隠しビュー。
/// スライダーを操作可能にするには MPVolumeView がビュー階層に存在する必要があるため配置する。
struct SystemVolumeHost: UIViewRepresentable {
    let controller: SystemVolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        // 画面外に配置し、標準の音量 HUD（システムの音量表示）を出さないようにする
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - 音量/明るさ HUD モデル

enum AdjustKind {
    case volume
    case brightness
}

/// 音量・明るさ調整時に中央に表示する HUD の状態
struct AdjustHUD: Equatable {
    var kind: AdjustKind
    /// 0...1 の現在値
    var value: Double
    /// 再表示・再アニメーション用の id
    var triggerID: UUID = UUID()
}

/// ドラッグ中に表示する音量/明るさインジケータ
struct AdjustHUDView: View {
    let hud: AdjustHUD

    private var iconName: String {
        switch hud.kind {
        case .volume:
            if hud.value <= 0.001 { return "speaker.slash.fill" }
            if hud.value < 0.33 { return "speaker.wave.1.fill" }
            if hud.value < 0.66 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return hud.value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(height: 26)
                // アイコン幅の変化でレイアウトが揺れないよう固定
                .frame(width: 30)

            // 縦バー
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                    Capsule()
                        .fill(.white)
                        .frame(height: geo.size.height * CGFloat(min(max(hud.value, 0), 1)))
                }
            }
            .frame(width: 5, height: 90)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }
}
