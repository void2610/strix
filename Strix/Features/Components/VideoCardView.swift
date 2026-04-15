//
//  VideoCardView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import SwiftData
import NukeUI

/// YouTube 風の動画カード（サムネイル 16:9 + チャンネルアバター + メタ情報）
/// ホームフィードで使用する。
struct VideoCardView: View {
    let video: VideoItem
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // サムネイル（16:9）+ プログレスバー
            thumbnail
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipped()
                .overlay(alignment: .bottom) {
                    VideoProgressBar(videoID: video.videoId, modelContext: modelContext)
                }

            // メタ情報行（アバター + タイトル・チャンネル名・視聴回数）
            HStack(alignment: .top, spacing: 12) {
                // チャンネルアバター（タップでチャンネルページへ）
                if let channelId = video.channelId {
                    NavigationLink(value: ChannelDestination(channelId: channelId)) {
                        channelAvatar
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    channelAvatar
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    // チャンネル名（タップでチャンネルページへ）
                    if let channelId = video.channelId {
                        NavigationLink(value: ChannelDestination(channelId: channelId)) {
                            metaText
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        metaText
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - サブビュー

    @ViewBuilder
    private var thumbnail: some View {
        ZStack(alignment: .trailing) {
            if let url = video.thumbnailURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        thumbnailPlaceholder
                    }
                }
            } else {
                thumbnailPlaceholder
            }

            // ミックスリスト・プレイリストのオーバーレイ
            if video.playlistId != nil {
                HStack(spacing: 0) {
                    // 左側のグラデーション
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 40)

                    // 右側の背景 + アイコン
                    Color.black.opacity(0.7)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "list.triangle")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                Text("MIX")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 80)
                }
            }
        }
    }

    private var thumbnailPlaceholder: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                Image(systemName: "play.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
    }

    @ViewBuilder
    private var channelAvatar: some View {
        if let url = video.channelAvatarURL {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    avatarPlaceholder
                }
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color(.tertiarySystemBackground))
            .overlay {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title2)
            }
    }

    private var metaText: some View {
        let parts = [video.channelName, video.viewCountText, video.timePostedText]
            .compactMap { $0 }
        return Text(parts.joined(separator: " • "))
    }
}

/// 検索結果・関連動画リスト向けのコンパクトな横並びビュー
struct VideoRowView: View {
    let video: VideoItem
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // サムネイル + プログレスバー
            Group {
                if let url = video.thumbnailURL {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color(.secondarySystemBackground)
                        }
                    }
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(width: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                VideoProgressBar(videoID: video.videoId, modelContext: modelContext)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // メタ情報
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                let meta = [video.channelName, video.viewCountText, video.timePostedText]
                    .compactMap { $0 }.joined(separator: " • ")
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 再生プログレスバー

/// サムネイル下部に表示する再生進捗バー（YouTube 風の赤いバー）。
/// WatchedVideo の playbackPosition / videoDuration から進捗率を算出する。
struct VideoProgressBar: View {
    let videoID: String
    let modelContext: ModelContext

    var body: some View {
        let progress = fetchProgress()
        if let progress {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.red)
                    .frame(width: geo.size.width * progress, height: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 3)
        }
    }

    /// SwiftData から再生進捗率を取得する（0.0〜1.0、未視聴なら nil）
    private func fetchProgress() -> Double? {
        let targetID = videoID
        var descriptor = FetchDescriptor<WatchedVideo>(
            predicate: #Predicate { $0.videoID == targetID }
        )
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first,
              record.videoDuration > 0,
              record.playbackPosition > 5 else { return nil }
        let ratio = record.playbackPosition / record.videoDuration
        // 95%以上は視聴完了扱い → バーを表示しない
        if ratio >= 0.95 { return nil }
        return min(ratio, 1.0)
    }
}
