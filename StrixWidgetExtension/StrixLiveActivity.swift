//
//  StrixLiveActivity.swift
//  StrixWidgetExtension
//
//  Created by Shuya Izumi on 2026/04/08.
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Widget Extension 本体

@main
struct StrixWidgetExtension: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StrixActivityAttributes.self) { context in
            // ロック画面・バナー表示
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                // ダイナミックアイランド展開時
                DynamicIslandExpandedRegion(.leading) {
                    AsyncImage(url: URL(string: context.state.thumbnailURL)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(.secondarySystemBackground)
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                DynamicIslandExpandedRegion(.trailing) {
                    playbackControls(isPlaying: context.state.isPlaying)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text(context.state.channelName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // シークバー
                        ProgressView(
                            value: max(0, min(context.state.elapsedSeconds, context.state.durationSeconds)),
                            total: max(1, context.state.durationSeconds)
                        )
                        .tint(.red)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // コンパクト表示（左）: サムネイル
                AsyncImage(url: URL(string: context.state.thumbnailURL)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.red.opacity(0.3)
                }
                .frame(width: 24, height: 24)
                .clipShape(Circle())
            } compactTrailing: {
                // コンパクト表示（右）: 再生/停止アイコン
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } minimal: {
                // 最小表示: YouTube 風の再生アイコン
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func playbackControls(isPlaying: Bool) -> some View {
        HStack(spacing: 16) {
            // コントロールは MPRemoteCommandCenter 経由で動作するため
            // ダイナミックアイランドはステータス表示のみ
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - ロック画面表示

private struct LockScreenView: View {
    let state: StrixActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: state.thumbnailURL)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.secondarySystemBackground)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                Text(state.channelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(
                    value: max(0, min(state.elapsedSeconds, state.durationSeconds)),
                    total: max(1, state.durationSeconds)
                )
                .tint(.red)
            }

            Spacer()

            Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title)
                .foregroundStyle(.red)
        }
        .padding(16)
        .activityBackgroundTint(Color(.systemBackground))
    }
}
