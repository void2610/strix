import Foundation

// MARK: - /next のチャプター・高評価

extension ContentClient {

    /// /next レスポンスのシークバー用マーカーからチャプターを取り出す。
    static func extractChapters(from json: Any) -> [VideoChapter] {
        guard let markersMap = findValue(forKey: "markersMap", in: json) as? [[String: Any]] else { return [] }
        // 概要欄に書かれたチャプターを、自動生成のチャプターより優先する
        let entry = markersMap.first { $0["key"] as? String == "DESCRIPTION_CHAPTERS" }
            ?? markersMap.first { $0["key"] as? String == "AUTO_CHAPTERS" }
        let chapters = (entry?["value"] as? [String: Any])?["chapters"] as? [[String: Any]] ?? []
        return chapters.compactMap { item in
            guard let renderer = item["chapterRenderer"] as? [String: Any],
                  let title = (renderer["title"] as? [String: Any])?["simpleText"] as? String,
                  let startMillis = (renderer["timeRangeStartMillis"] as? NSNumber)?.doubleValue else { return nil }
            let thumbs = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            return VideoChapter(
                title: title,
                startSeconds: startMillis / 1000,
                thumbnailURL: imageURL(from: thumbs?.last?["url"] as? String)
            )
        }
        .sorted { $0.startSeconds < $1.startSeconds }
    }

    /// /next レスポンスの高評価ボタンから評価状態と件数を取り出す。未ログインで評価できないときは nil。
    static func extractLikeState(from json: Any) -> LikeState? {
        guard let segmented = findValue(forKey: "segmentedLikeDislikeButtonViewModel", in: json) as? [String: Any],
              let like = (segmented["likeButtonViewModel"] as? [String: Any])?["likeButtonViewModel"] as? [String: Any] else { return nil }
        let status = (like["likeStatusEntity"] as? [String: Any])?["likeStatus"] as? String
        let toggle = (like["toggleButtonViewModel"] as? [String: Any])?["toggleButtonViewModel"] as? [String: Any]
        // 未ログインの応答では、押すとログインを促す signInEndpoint が付く
        if findValue(forKey: "signInEndpoint", in: toggle?["defaultButtonViewModel"] as Any) != nil { return nil }
        func title(_ key: String) -> String? {
            ((toggle?[key] as? [String: Any])?["buttonViewModel"] as? [String: Any])?["title"] as? String
        }
        return LikeState(
            rating: status == "LIKE" ? .like : status == "DISLIKE" ? .dislike : .none,
            countText: title("defaultButtonViewModel"),
            likedCountText: title("toggledButtonViewModel")
        )
    }

    /// /next レスポンスのコメントパネルの見出しからコメントの総数を取り出す。
    static func extractCommentCount(from json: Any) -> String? {
        let panels = (json as? [String: Any])?["engagementPanels"] as? [[String: Any]] ?? []
        let comments = panels
            .compactMap { $0["engagementPanelSectionListRenderer"] as? [String: Any] }
            .first { $0["panelIdentifier"] as? String == "engagement-panel-comments-section" }
        let header = (comments?["header"] as? [String: Any])?["engagementPanelTitleHeaderRenderer"] as? [String: Any]
        let runs = (header?["contextualInfo"] as? [String: Any])?["runs"] as? [[String: Any]]
        return runs.map(\.joinedText).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// JSON ツリーを深さ優先で探し、最初に見つかったキーの値を返す。
    static func findValue(forKey key: String, in json: Any) -> Any? {
        if let dict = json as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values {
                if let found = findValue(forKey: key, in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let found = findValue(forKey: key, in: item) { return found }
            }
        }
        return nil
    }
}
