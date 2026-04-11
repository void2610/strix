//
//  HomePlaylistEditView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/11.
//

import SwiftUI
import SwiftData
import YouTubeKit

/// ホーム画面に表示するプレイリストを選択する画面。
struct HomePlaylistEditView: View {
    let allPlaylists: [YTPlaylist]
    var onSave: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCustomizedHomePlaylists") private var hasCustomized = false
    @State private var selectedIds: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(allPlaylists.enumerated()), id: \.offset) { _, playlist in
                    Button {
                        toggleSelection(playlist.playlistId)
                    } label: {
                        HStack {
                            playlistIcon(playlist)
                            Text(playlist.title ?? "プレイリスト")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedIds.contains(playlist.playlistId) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("表示するプレイリスト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
        .task { loadCurrentSelection() }
    }

    // MARK: - プレイリストアイコン

    @ViewBuilder
    private func playlistIcon(_ playlist: YTPlaylist) -> some View {
        switch playlist.playlistId {
        case "VLWL":
            Image(systemName: "bookmark.fill")
                .frame(width: 24)
                .foregroundStyle(.orange)
        case "VLLL":
            Image(systemName: "hand.thumbsup.fill")
                .frame(width: 24)
                .foregroundStyle(.blue)
        default:
            Image(systemName: "music.note.list")
                .frame(width: 24)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - ロジック

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// 現在の PinnedPlaylist から選択状態を読み込む。未カスタマイズなら全選択。
    private func loadCurrentSelection() {
        if hasCustomized {
            let descriptor = FetchDescriptor<PinnedPlaylist>()
            let pinned = (try? modelContext.fetch(descriptor)) ?? []
            selectedIds = Set(pinned.map(\.playlistId))
        } else {
            // 未カスタマイズ: 全プレイリストを選択状態にする
            selectedIds = Set(allPlaylists.map(\.playlistId))
        }
    }

    /// 選択状態を SwiftData に保存する。
    private func save() {
        // 既存の PinnedPlaylist を全削除
        do {
            try modelContext.delete(model: PinnedPlaylist.self)
        } catch {}

        // 選択されたプレイリストを挿入（表示順を保持）
        for (index, playlist) in allPlaylists.enumerated() {
            if selectedIds.contains(playlist.playlistId) {
                modelContext.insert(PinnedPlaylist(playlistId: playlist.playlistId, sortOrder: index))
            }
        }
        try? modelContext.save()

        hasCustomized = true
        onSave()
        dismiss()
    }
}
