//
//  PlayerSeekBar.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/22.
//

import SwiftUI

/// YouTube 風のシークバー。ドラッグで任意位置にシークできる。
/// スクラブ中は `controller.isScrubbing = true` をセットしてオーバーレイのフェードを抑制する。
///
/// 表示する進捗は親から渡される `currentTime` 1 本で決まる。
/// 親は `scrubPreviewTime ?? playerTime` のように解決済みの値を渡すこと。
/// 終端処理（`isScrubbing = false` とプレビュー値の解除）はシーク完了後に親側で行う。
struct PlayerSeekBar: View {
    /// 表示する再生位置（秒）。スクラブ中は親がプレビュー値を渡す。
    let currentTime: Double
    /// 総時間（秒）
    let duration: Double
    /// ドラッグ中の値を親に通知（時刻表示とバー進捗用）
    let onScrub: (Double) -> Void
    /// ドラッグ終了時に確定した秒数でシークを要求する
    let onSeek: (Double) -> Void
    /// バーを区切って表示するチャプター
    var chapters: [VideoChapter] = []
    /// スクラブ中に出すサムネイルの元画像
    var storyboard: Storyboard?

    private let previewWidth: CGFloat = 160

    @Environment(PlayerOverlayController.self) private var controller

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = progressRatio
            let knobX = width * progress

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    // 背景トラック
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: controller.isScrubbing ? 5 : 3)

                    // 再生済み部分
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, knobX), height: controller.isScrubbing ? 5 : 3)
                }
                .mask { chapterGapMask(width: width) }

                // つまみ
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: controller.isScrubbing ? 18 : 12,
                           height: controller.isScrubbing ? 18 : 12)
                    .offset(x: knobX - (controller.isScrubbing ? 9 : 6))
            }
            .frame(height: 22)
            .overlay(alignment: .bottomLeading) {
                if controller.isScrubbing {
                    scrubPreview
                        .offset(x: min(max(knobX - previewWidth / 2, 0), max(width - previewWidth, 0)), y: -30)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !controller.isScrubbing {
                            controller.isScrubbing = true
                        }
                        let x = min(max(0, value.location.x), width)
                        let t = Double(x / width) * max(duration, 0.001)
                        onScrub(t)
                    }
                    .onEnded { value in
                        let x = min(max(0, value.location.x), width)
                        let t = Double(x / width) * max(duration, 0.001)
                        // isScrubbing とプレビュー解除はシーク完了後に親が行う
                        onSeek(t)
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: controller.isScrubbing)
        }
        .frame(height: 22)
    }

    /// チャプターの境目に隙間を空けるマスク
    private func chapterGapMask(width: CGFloat) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            guard duration > 0 else { return }
            context.blendMode = .clear
            for chapter in chapters where chapter.startSeconds > 0 && chapter.startSeconds < duration {
                let x = width * chapter.startSeconds / duration
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.black))
            }
        }
    }

    /// スクラブ中に指の上に出すサムネイル・チャプター名・時刻
    private var scrubPreview: some View {
        VStack(spacing: 4) {
            if let storyboard {
                StoryboardThumbnail(storyboard: storyboard, time: currentTime)
                    .frame(width: previewWidth, height: previewWidth * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 1.5))
            }
            if let chapter = VideoChapter.current(in: chapters, at: currentTime) {
                Text(chapter.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            Text(PlaybackTimeFormatter.string(from: currentTime))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 2)
        .frame(width: previewWidth)
    }

    /// 0.0 - 1.0 の範囲に正規化した再生進捗
    private var progressRatio: Double {
        guard duration > 0 else { return 0 }
        return min(max(0, currentTime / duration), 1)
    }
}
