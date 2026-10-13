import Foundation

/// /next API から取り出す、再生画面の下半分に出す情報
struct WatchNextInfo {
    var videos: [VideoItem] = []
    var ownerAvatarURL: URL?
    var description: String?
    var viewCount: String?
    var publishDate: String?
    var chapters: [VideoChapter] = []
    /// コメントの総数の表示（「137」など）
    var commentCountText: String?
    /// 高評価ボタンの状態（取得できなければ nil）
    var like: LikeState?
}

/// 動画のチャプター
struct VideoChapter: Equatable, Identifiable {
    var id: Double { startSeconds }
    let title: String
    let startSeconds: Double
    let thumbnailURL: URL?

    /// 指定時刻を含むチャプターを返す（chapters は開始時刻の昇順）
    static func current(in chapters: [VideoChapter], at seconds: Double) -> VideoChapter? {
        chapters.last { $0.startSeconds <= seconds }
    }
}

/// 動画への評価
enum VideoRating: Equatable {
    case none, like, dislike
}

/// 高評価・低評価ボタンの状態
struct LikeState: Equatable {
    var rating: VideoRating
    /// 高評価していないときに表示する件数
    let countText: String?
    /// 高評価したときに表示する件数（自分の 1 件を含む）
    let likedCountText: String?

    var displayCountText: String? { rating == .like ? likedCountText : countText }
}
