//
//  HomeView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import SwiftData

@Observable
final class HomeViewModel {
    var videos: [VideoItem] = []
    var isLoading = false
    var error: String?

    private let client: ContentClient

    init(client: ContentClient = .live) {
        self.client = client
    }

    func load() async {
        guard videos.isEmpty else { return }
        isLoading = true
        error = nil
        do {
            videos = try await client.fetchHome()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func reload() async {
        videos = []
        await load()
    }
}

struct HomeView: View {
    @State private var vm = HomeViewModel()
    @State private var urlInput = ""
    @State private var path = NavigationPath()
    @Query(sort: \WatchedVideo.watchedAt, order: .reverse) private var history: [WatchedVideo]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // URL 入力セクション
                    urlInputSection

                    // 視聴履歴（ある場合）
                    if !history.isEmpty {
                        historySection
                    }

                    Divider()
                        .padding(.vertical, 8)

                    // ホームフィード
                    if vm.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let error = vm.error {
                        ContentUnavailableView(
                            "読み込みに失敗しました",
                            systemImage: "wifi.exclamationmark",
                            description: Text(error)
                        )
                        .padding(.top, 40)
                    } else {
                        sectionHeader("おすすめ")
                    feedSection
                    }
                }
            }
            .navigationTitle("Strix")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await vm.reload() }
            .navigationDestination(for: String.self) { videoID in
                PlayerView(videoID: videoID)
            }
        }
        .task { await vm.load() }
        // ログイン・ログアウト時にパーソナライズされたフィードを再取得する
        .onChange(of: AuthState.shared.isSignedIn) { _, _ in
            Task { await vm.reload() }
        }
    }

    // MARK: - サブセクション

    private var urlInputSection: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("YouTube URL または動画 ID", text: $urlInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit(playFromInput)
                if !urlInput.isEmpty {
                    Button {
                        urlInput = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)

            Button(action: playFromInput) {
                Label("再生", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(extractVideoID(from: urlInput) == nil)
            .padding(.horizontal)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近再生した動画")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(history.prefix(10)) { video in
                        Button { path.append(video.videoID) } label: {
                            HistoryThumbnailView(video: video)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
    }

    private var feedSection: some View {
        LazyVStack(spacing: 0) {
            ForEach(vm.videos) { video in
                Button {
                    path.append(video.videoId)
                } label: {
                    VideoCardView(video: video)
                }
                .buttonStyle(.plain)

                Divider()
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - アクション

    private func playFromInput() {
        if let id = extractVideoID(from: urlInput) {
            path.append(id)
            urlInput = ""
        }
    }
}

// MARK: - 視聴履歴サムネイル

private struct HistoryThumbnailView: View {
    let video: WatchedVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: URL(string: video.thumbnailURL)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.secondarySystemBackground)
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
