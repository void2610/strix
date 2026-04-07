//
//  PlayerView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/07.
//

import SwiftUI
import AVKit
import SwiftData

struct PlayerView: View {
    let videoID: String

    @Environment(\.modelContext) private var modelContext
    @State private var player: AVPlayer?
    @State private var videoInfo: VideoInfo?
    @State private var isLoading = true
    @State private var error: Error?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if isLoading {
                ProgressView("読み込み中...")
            } else if error != nil {
                ContentUnavailableView(
                    "再生できません",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error?.localizedDescription ?? "")
                )
            }
        }
        .task {
            await loadStream()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func loadStream() async {
        do {
            let info = try await YouTubeClient.live.fetchVideo(videoID)
            videoInfo = info
            player = AVPlayer(url: info.streamURL)
            player?.play()
            isLoading = false
            saveToHistory(info)
        } catch {
            self.error = error
            isLoading = false
        }
    }

    /// 視聴履歴に保存する
    private func saveToHistory(_ info: VideoInfo) {
        let video = WatchedVideo(
            videoID: videoID,
            title: info.title,
            thumbnailURL: info.thumbnailURL
        )
        modelContext.insert(video)
    }
}
