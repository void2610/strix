//
//  PlayerView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import AVKit
import SwiftData
import YouTubeKit

@Observable
final class PlayerViewModel {
    var player: AVPlayer?
    var videoInfo: VideoInfo?
    var relatedVideos: [YTVideo] = []
    var isLoadingStream = true
    var isLoadingRelated = true
    var streamError: Error?

    func load(videoID: String, modelContext: ModelContext) async {
        // ストリームと関連動画を並列取得
        async let streamTask: Void = loadStream(videoID: videoID, modelContext: modelContext)
        async let relatedTask: Void = loadRelated(videoID: videoID)
        _ = await (streamTask, relatedTask)
    }

    private func loadStream(videoID: String, modelContext: ModelContext) async {
        do {
            let info = try await YouTubeClient.live.fetchVideo(videoID)
            videoInfo = info
            player = AVPlayer(url: info.streamURL)
            player?.play()
            isLoadingStream = false
            saveToHistory(videoID: videoID, info: info, modelContext: modelContext)
        } catch {
            streamError = error
            isLoadingStream = false
        }
    }

    private func loadRelated(videoID: String) async {
        do {
            relatedVideos = try await ContentClient.live.fetchRelated(videoID)
        } catch {
            // 関連動画の失敗はサイレントに扱う
        }
        isLoadingRelated = false
    }

    private func saveToHistory(videoID: String, info: VideoInfo, modelContext: ModelContext) {
        let video = WatchedVideo(
            videoID: videoID,
            title: info.title,
            thumbnailURL: info.thumbnailURL
        )
        modelContext.insert(video)
    }
}

struct PlayerView: View {
    let videoID: String

    @State private var vm = PlayerViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 動画プレイヤー（画面幅 × 16:9）
                playerSection

                if vm.isLoadingStream {
                    // ローディング中はタイトルスケルトン
                    skeletonTitle
                } else if let info = vm.videoInfo {
                    // タイトル・チャンネル情報
                    videoMeta(info: info)
                }

                Divider()
                    .padding(.top, 8)

                // 関連動画
                relatedSection
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(edges: .top)
        .task { await vm.load(videoID: videoID, modelContext: modelContext) }
        .onDisappear { vm.player?.pause() }
    }

    // MARK: - プレイヤー

    private var playerSection: some View {
        ZStack {
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)

            if vm.isLoadingStream {
                ProgressView()
                    .tint(.white)
            } else if vm.streamError != nil {
                ContentUnavailableView(
                    "再生できません",
                    systemImage: "exclamationmark.triangle",
                    description: Text(vm.streamError?.localizedDescription ?? "")
                )
                .colorScheme(.dark)
            } else if let player = vm.player {
                VideoPlayer(player: player)
            }
        }
    }

    // MARK: - タイトル・メタ情報

    private func videoMeta(info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.title)
                .font(.headline)
                .lineLimit(3)

            // チャンネル名は関連動画取得後に vm.relatedVideos の先頭から参照
            // それまでは空表示
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var skeletonTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.secondarySystemBackground))
                .frame(height: 18)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 160, height: 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 関連動画

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !vm.relatedVideos.isEmpty {
                Text("関連動画")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                LazyVStack(spacing: 0) {
                    ForEach(vm.relatedVideos, id: \.videoId) { video in
                        NavigationLink(value: video.videoId) {
                            VideoRowView(video: video)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 12)
                    }
                }
            } else if vm.isLoadingRelated {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            }
        }
    }
}
