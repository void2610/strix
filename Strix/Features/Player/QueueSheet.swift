//
//  QueueSheet.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/06/17.
//

import SwiftUI
import NukeUI

/// 再生キュー一覧シート。
/// iOS 標準 List の常時編集モードで滑らかに並び替える。
/// List 全体を RTL にして並び替えハンドルを左端へ寄せ、行内容は LTR に戻して通常表示する。
/// 削除のマイナスボタンは出さず（onDelete を使わない）、削除は長押しメニューから行う。
struct QueueSheet: View {
    @Environment(PlayerCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(coordinator.playlistQueue.enumerated()), id: \.element.videoId) { index, video in
                    QueueRow(video: video, isCurrent: index == coordinator.initialIndex)
                        .environment(\.layoutDirection, .leftToRight)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
                        .listRowBackground(index == coordinator.initialIndex ? Color.accentColor.opacity(0.10) : Color(.systemBackground))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            coordinator.jumpTo(index: index)
                            dismiss()
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                coordinator.removeFromQueue(at: index)
                            } label: {
                                Label("キューから削除", systemImage: "trash")
                            }
                        }
                }
                .onMove { coordinator.moveInQueue(from: $0, to: $1) }
            }
            .listStyle(.plain)
            // 常時編集モードでハンドルを常時表示し、RTL でハンドルを左端へ寄せる
            .environment(\.editMode, .constant(.active))
            .environment(\.layoutDirection, .rightToLeft)
            .navigationTitle("再生キュー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct QueueRow: View {
    let video: VideoItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            LazyImage(url: video.thumbnailURL) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .frame(width: 80, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.subheadline)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(2)
                if let channel = video.channelName {
                    Text(channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: "waveform")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        }
        .padding(.vertical, 2)
    }
}
