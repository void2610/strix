//
//  AddToPlaylistMenu.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/18.
//

import SwiftUI
import YouTubeKit

/// プレイリスト一覧を取得・キャッシュし、コンテキストメニューのサブメニューとして提供する。
@MainActor
@Observable
final class PlaylistMenuState {
    static let shared = PlaylistMenuState()

    var playlists: [YTPlaylist] = []
    private var lastFetched: Date?

    private init() {}

    /// 最後の取得から60秒以上経っていれば再取得する
    func refreshIfNeeded() async {
        if let last = lastFetched, Date().timeIntervalSince(last) < 60 { return }
        do {
            let library = try await AccountClient.live.fetchLibrary()
            var list: [YTPlaylist] = []
            if let wl = library.watchLater { list.append(wl) }
            if let likes = library.likes { list.append(likes) }
            list.append(contentsOf: library.playlists)
            playlists = list
            lastFetched = Date()
        } catch {
            strixLog("プレイリスト一覧取得エラー: \(error)")
        }
    }
}

/// コンテキストメニュー内で「プレイリストに追加」サブメニューを表示するビュー。
struct AddToPlaylistMenu: View {
    let videoId: String

    @State private var menuState = PlaylistMenuState.shared

    var body: some View {
        Menu {
            if menuState.playlists.isEmpty {
                Text("読み込み中...")
            } else {
                ForEach(menuState.playlists, id: \.playlistId) { playlist in
                    Button {
                        Task {
                            try? await ContentClient.addToPlaylist(
                                playlistId: playlist.playlistId,
                                videoId: videoId
                            )
                        }
                    } label: {
                        Label(playlist.title ?? "不明なプレイリスト", systemImage: "music.note.list")
                    }
                }
            }
        } label: {
            Label("プレイリストに追加", systemImage: "text.badge.plus")
        }
        .task {
            await menuState.refreshIfNeeded()
        }
    }
}
