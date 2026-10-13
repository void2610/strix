import ImageIO
import SwiftUI

/// ストーリーボードから指定時刻の 1 コマを切り出して表示する。
struct StoryboardThumbnail: View {
    let storyboard: Storyboard
    let time: Double

    /// 次のコマを読み込む間も直前のコマを出し続けて、スクラブ中のちらつきを防ぐ
    @State private var image: CGImage?

    var body: some View {
        let frame = storyboard.frame(at: time)
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
            } else {
                Color.black
            }
        }
        .task(id: frame.map { "\($0.sheetURL)#\($0.rect)" }) {
            guard let frame,
                  let sheet = await StoryboardSheetCache.shared.image(for: frame.sheetURL),
                  let cropped = sheet.cropping(to: frame.rect) else { return }
            image = cropped
        }
    }
}

/// ストーリーボード画像の取得とキャッシュ。同じ画像への同時要求は 1 回の通信にまとめる。
actor StoryboardSheetCache {
    static let shared = StoryboardSheetCache()

    /// 1 時間の動画でも 30 枚程度なので、それを超えたら古い動画の分ごと捨てる
    private let maxImages = 60
    private var images: [URL: CGImage] = [:]
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]

    func image(for url: URL) async -> CGImage? {
        if let cached = images[url] { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task<CGImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            if images.count >= maxImages { images.removeAll() }
            images[url] = image
        }
        return image
    }
}
