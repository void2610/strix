//
//  HomeView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/07.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @State private var input = ""
    @State private var path = NavigationPath()
    @Query(sort: \WatchedVideo.watchedAt, order: .reverse) private var history: [WatchedVideo]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 16) {
                // URL / 動画 ID 入力欄
                TextField("YouTube URL または動画 ID", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal)

                Button("再生") {
                    if let id = extractVideoID(from: input) {
                        path.append(id)
                        input = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(extractVideoID(from: input) == nil)

                // 視聴履歴
                if !history.isEmpty {
                    Divider()
                        .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近再生した動画")
                            .font(.headline)
                            .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(history) { video in
                                    Button {
                                        path.append(video.videoID)
                                    } label: {
                                        HistoryThumbnailView(video: video)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Strix")
            .navigationDestination(for: String.self) { videoID in
                PlayerView(videoID: videoID)
            }
        }
    }
}

/// 視聴履歴のサムネイルビュー
private struct HistoryThumbnailView: View {
    let video: WatchedVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: URL(string: video.thumbnailURL)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(video.title)
                .font(.caption)
                .lineLimit(2)
                .frame(width: 120, alignment: .leading)
        }
    }
}
