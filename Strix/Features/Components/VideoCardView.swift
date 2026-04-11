//
//  VideoCardView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import NukeUI

/// YouTube 風の動画カード（サムネイル 16:9 + チャンネルアバター + メタ情報）
/// ホームフィードで使用する。
struct VideoCardView: View {
    let video: VideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // サムネイル（16:9）
            thumbnail
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipped()

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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // サムネイル
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
