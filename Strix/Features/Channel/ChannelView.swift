//
//  ChannelView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/11.
//

import SwiftUI
import NukeUI

// MARK: - ViewModel

@MainActor
@Observable
final class ChannelViewModel {
    var channelInfo: ChannelInfo?
    var isLoading = true
    var error: String?

    private let contentClient: ContentClient

    init(contentClient: ContentClient = .live) {
        self.contentClient = contentClient
    }

    func load(channelId: String) async {
        do {
            channelInfo = try await contentClient.fetchChannel(channelId)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - ナビゲーション用の型

struct ChannelDestination: Hashable {
    let channelId: String
}

// MARK: - View

struct ChannelView: View {
    let channelId: String

    @State private var vm = ChannelViewModel()

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.error {
                ContentUnavailableView(
                    "読み込みエラー",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let info = vm.channelInfo {
                channelContent(info: info)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(channelId: channelId) }
    }

    // MARK: - チャンネルコンテンツ

    private func channelContent(info: ChannelInfo) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // バナー
                bannerSection(info: info)

                // チャンネルヘッダー
                channelHeader(info: info)

                Divider()
                    .padding(.vertical, 8)

                // 動画一覧
                if info.videos.isEmpty {
                    ContentUnavailableView(
                        "動画がありません",
                        systemImage: "play.slash"
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(info.videos) { video in
                        NavigationLink(value: video.videoId) {
                            VideoCardView(video: video)
                        }
                        .buttonStyle(.plain)

                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - バナー

    @ViewBuilder
    private func bannerSection(info: ChannelInfo) -> some View {
        if let bannerURL = info.bannerURL {
            LazyImage(url: bannerURL) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .aspectRatio(6.2, contentMode: .fit)
            .clipped()
        }
    }

    // MARK: - チャンネルヘッダー

    private func channelHeader(info: ChannelInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // アバター
            if let avatarURL = info.avatarURL {
                LazyImage(url: avatarURL) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Circle().fill(Color(.secondarySystemBackground))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                // チャンネル名
                Text(info.name ?? "チャンネル")
                    .font(.title3.bold())
                    .lineLimit(2)

                // ハンドル・登録者数・動画数
                let meta = [info.handle, info.subscriberCount, info.videoCount]
                    .compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
