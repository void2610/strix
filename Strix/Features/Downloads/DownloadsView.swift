//
//  DownloadsView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/07/10.
//

import SwiftUI
import SwiftData
import NukeUI

/// オフライン保存済み・ダウンロード中の動画一覧。
/// 完了したものはタップでオフライン再生、スワイプで削除できる。
struct DownloadsView: View {
    @Query(sort: \DownloadedVideo.downloadedAt, order: .reverse)
    private var downloads: [DownloadedVideo]
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerCoordinator.self) private var playerCoordinator

    var body: some View {
        Group {
            if downloads.isEmpty {
                ContentUnavailableView(
                    "ダウンロードした動画がありません",
                    systemImage: "arrow.down.circle",
                    description: Text("動画を長押しして「ダウンロード」を選ぶとオフラインで再生できます")
                )
            } else {
                List {
                    ForEach(downloads) { download in
                        DownloadRowView(download: download,
                                        liveProgress: DownloadManager.shared.progress[download.videoID])
                            .contentShape(Rectangle())
                            .onTapGesture { play(download) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    DownloadManager.shared.delete(download, modelContext: modelContext)
                                } label: {
                                    Label(download.state == .downloading ? "中止" : "削除",
                                          systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("ダウンロード")
        .navigationBarTitleDisplayMode(.large)
    }

    private func play(_ download: DownloadedVideo) {
        guard download.state == .completed else { return }
        playerCoordinator.play(download.toVideoItem)
    }
}

/// ダウンロード行。状態に応じて進捗・サイズ・エラーを出し分ける。
private struct DownloadRowView: View {
    let download: DownloadedVideo
    /// マネージャが持つリアルタイム進捗（進行中のみ）
    let liveProgress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(download.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                if let channel = download.channelName, !channel.isEmpty {
                    Text(channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch download.state {
        case .completed:
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                Text(sizeText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        case .downloading:
            let fraction = liveProgress ?? download.progress
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text("ダウンロード中… \(Int(fraction * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("ダウンロードに失敗しました")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private var sizeText: String {
        guard download.fileSize > 0 else { return "オフライン再生可能" }
        return ByteCountFormatter.string(fromByteCount: download.fileSize, countStyle: .file)
    }

    @ViewBuilder
    private var thumbnail: some View {
        // オフラインでも確実に表示できるようローカル保存サムネイルを優先する
        if let localThumb = localThumbnailURL {
            LazyImage(url: localThumb) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    thumbnailPlaceholder
                }
            }
        } else if let remote = URL(string: download.remoteThumbnailURL) {
            LazyImage(url: remote) { state in
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

    private var localThumbnailURL: URL? {
        guard let name = download.thumbnailFileName else { return nil }
        let url = DownloadManager.localFileURL(fileName: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var thumbnailPlaceholder: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                Image(systemName: "play.rectangle")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}
