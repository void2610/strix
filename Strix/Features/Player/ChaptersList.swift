import AVFoundation
import NukeUI
import SwiftUI

/// チャプター一覧のパネルの中身。再生中のチャプターを強調し、タップでその位置へ移動する。
struct ChaptersList: View {
    let chapters: [VideoChapter]
    let player: AVPlayer?
    let onSelect: (VideoChapter) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            // パネルを開いたまま再生が進んでも強調が追従するよう、再生位置を定期的に読み直す
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let current = VideoChapter.current(in: chapters, at: player?.currentTime().seconds ?? 0)
                List(chapters) { chapter in
                    Button {
                        onSelect(chapter)
                    } label: {
                        row(chapter)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(chapter == current ? Color(.tertiarySystemFill) : Color.clear)
                    .id(chapter.id)
                }
                .listStyle(.plain)
                .panelPullToDismiss()
            }
            .onAppear {
                if let current = VideoChapter.current(in: chapters, at: player?.currentTime().seconds ?? 0) {
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
        }
    }

    private func row(_ chapter: VideoChapter) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ChapterThumbnail(url: chapter.thumbnailURL)
                .frame(width: 112, height: 63)
            VStack(alignment: .leading, spacing: 4) {
                Text(chapter.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(PlaybackTimeFormatter.string(from: chapter.startSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// チャプターのサムネイル（読み込み前は灰色）
struct ChapterThumbnail: View {
    let url: URL?

    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
