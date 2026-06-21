//
//  ContentClient+Parsing.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/24.
//

import Foundation

// MARK: - YouTube JSON ヘルパー

/// YouTube API の `runs` 配列（`[{"text": "..."}]`）から text を結合する。
extension Array where Element == [String: Any] {
    /// runs 配列内の "text" を連結して返す
    var joinedText: String {
        compactMap { $0["text"] as? String }.joined()
    }
}

// MARK: - 動画レンダラーパース・JSON ツリー探索

extension ContentClient {

    /// JSON ツリーを再帰的に探索して動画 Renderer を全て抽出する。
    /// WEB 旧形式 → videoRenderer / compactVideoRenderer / playlistVideoRenderer
    /// WEB 新形式 → lockupViewModel
    /// IOS 旧形式 → compactVideoRenderer / elementRenderer 内の videoWithContextModel
    /// IOS 新形式 → videoWithContextModel
    /// 広告枠のラッパーキー。配下にネストした動画レンダラーを含むためサブツリーごと除外する。
    static let adRendererKeys: Set<String> = [
        "adSlotRenderer", "promotedVideoRenderer", "compactPromotedVideoRenderer",
        "promotedSparklesWebRenderer", "promotedSparklesTextSearchRenderer",
        "searchPyvRenderer", "displayAdLayoutViewModel", "inFeedAdLayoutRenderer",
        "bannerPromoRenderer", "statementBannerRenderer", "adSlotMetadata"
    ]

    static func findVideoRenderers(in json: Any) -> [[String: Any]] {
        if let dict = json as? [String: Any] {
            // 広告枠はサブツリーごと除外（ネスト内の動画レンダラーが拾われるのを防ぐ）
            if dict.keys.contains(where: { adRendererKeys.contains($0) }) { return [] }
            // WEB 旧形式
            if let vr = dict["videoRenderer"] as? [String: Any] { return [vr] }
            if let vr = dict["compactVideoRenderer"] as? [String: Any] { return [vr] }
            if let vr = dict["playlistVideoRenderer"] as? [String: Any] { return [vr] }
            // WEB 新形式 (2024 年以降の主要フォーマット)
            if let vr = dict["lockupViewModel"] as? [String: Any] { return [vr] }
            // IOS 新形式: videoWithContextModel が直接キーとして現れる場合
            if let vr = dict["videoWithContextModel"] as? [String: Any] { return [vr] }
            // IOS 旧形式: elementRenderer 内の決まったパス
            if let el = dict["elementRenderer"] as? [String: Any],
               let item = extractVideoWithContextModel(from: el) { return [item] }
            // その他のキーを再帰的に探索
            return dict.values.flatMap { findVideoRenderers(in: $0) }
        } else if let array = json as? [Any] {
            return array.flatMap { findVideoRenderers(in: $0) }
        }
        return []
    }

    /// elementRenderer から videoWithContextModel を取り出す。
    /// パス: newElement.type.componentType.model.videoWithContextModel
    static func extractVideoWithContextModel(from el: [String: Any]) -> [String: Any]? {
        guard
            let newElement   = el["newElement"]  as? [String: Any],
            let type_        = newElement["type"] as? [String: Any],
            let component    = type_["componentType"] as? [String: Any],
            let model        = component["model"]     as? [String: Any],
            let vcm          = model["videoWithContextModel"] as? [String: Any]
        else { return nil }
        return vcm
    }

    /// videoRenderer / compactVideoRenderer / playlistVideoRenderer / lockupViewModel / videoWithContextModel から VideoItem を生成する。
    static func parseVideoRenderer(_ vr: [String: Any]) -> VideoItem? {
        // 未加入では再生できないメンバー限定動画は一覧から除外する
        if containsMembersOnlyBadge(vr) { return nil }

        // ── WEB 新形式: lockupViewModel ────────────────────────────────────
        if vr["contentId"] != nil {
            return parseLockupViewModel(vr)
        }

        // ── IOS 新形式: videoWithContextModel ─────────────────────────────
        if let vcData = vr["videoWithContextData"] as? [String: Any] {
            return parseVideoWithContextData(vcData)
        }

        // ── 旧形式: videoRenderer / compactVideoRenderer ───────────────────
        guard let videoId = vr["videoId"] as? String else { return nil }

        // タイトル: videoRenderer → title.runs[0].text
        //           compactVideoRenderer → title.simpleText
        // 解決できないものは広告等の不正エントリとみなし除外する
        let titleObj = vr["title"] as? [String: Any]
        guard let title = (titleObj?["simpleText"] as? String)
            ?? ((titleObj?["runs"] as? [[String: Any]])?.first?["text"] as? String)
        else { return nil }

        // サムネイル
        let thumbs = (vr["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = ContentClient.imageURL(from: thumbs?.last?["url"] as? String)

        // チャンネル名・チャンネルID: ownerText / longBylineText / shortBylineText
        let ownerRuns = ((vr["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]])
            ?? ((vr["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])
            ?? ((vr["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])
        let channelName = ownerRuns?.first?["text"] as? String
        let channelId = ((ownerRuns?.first?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String

        // チャンネルアバター
        let chThumb = vr["channelThumbnailSupportedRenderers"] as? [String: Any]
        let chThumbLink = chThumb?["channelThumbnailWithLinkRenderer"] as? [String: Any]
        let chThumbObj = chThumbLink?["thumbnail"] as? [String: Any]
        let chThumbs = chThumbObj?["thumbnails"] as? [[String: Any]]
        let avatarURL = ContentClient.imageURL(from: chThumbs?.last?["url"] as? String)

        // 視聴回数・投稿日時
        let videoInfoRuns = (vr["videoInfo"] as? [String: Any])?["runs"] as? [[String: Any]]
        let viewCount = (vr["shortViewCountText"] as? [String: Any])?["simpleText"] as? String
            ?? videoInfoRuns?.first?["text"] as? String
        let timePosted = (vr["publishedTimeText"] as? [String: Any])?["simpleText"] as? String
            ?? videoInfoRuns?.dropFirst().first(where: { ($0["text"] as? String) != " • " })?["text"] as? String

        // フィードバックトークン（「興味なし」等）
        let tokens = extractFeedbackTokens(from: vr)

        // プレイリストエントリ固有ID（playlistVideoRenderer に含まれる）
        let setVideoId = vr["setVideoId"] as? String

        return VideoItem(
            videoId: videoId,
            title: title,
            channelId: channelId,
            channelName: channelName,
            thumbnailURL: thumbURL,
            channelAvatarURL: avatarURL,
            viewCountText: viewCount,
            timePostedText: timePosted,
            feedbackTokens: tokens,
            setVideoId: setVideoId
        )
    }

    /// WEB 新形式 lockupViewModel から VideoItem を生成する。
    static func parseLockupViewModel(_ lvm: [String: Any]) -> VideoItem? {
        guard let contentId = lvm["contentId"] as? String else { return nil }
        let contentType = lvm["contentType"] as? String ?? ""
        let isPlaylist = contentType.contains("PLAYLIST") || contentType.contains("MIX")

        let lmvm = (lvm["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]

        // タイトル: 解決できないものは広告等の不正エントリとみなし除外する
        guard let title = (lmvm?["title"] as? [String: Any])?["content"] as? String else { return nil }

        // サムネイル: thumbnailViewModel または collectionThumbnailViewModel
        let ci = lvm["contentImage"] as? [String: Any]
        let ciTvm = ci?["thumbnailViewModel"] as? [String: Any]
        let collTvm = (ci?["collectionThumbnailViewModel"] as? [String: Any])?["primaryThumbnail"] as? [String: Any]
        let resolvedTvm = ciTvm ?? (collTvm?["thumbnailViewModel"] as? [String: Any])
        let thumbSrcs = (resolvedTvm?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
        let thumbnailURL = ContentClient.imageURL(from: thumbSrcs?.last?["url"] as? String)

        // チャンネル名・チャンネルID: lockupMetadataViewModel 内を再帰探索
        let (channelName, channelId) = extractChannelInfo(from: lmvm as Any)

        // チャンネルアバター: 複数パスから探索
        var channelAvatarURL: URL? = nil
        // パス1: lockupMetadataViewModel.image.sources
        let avatarSrcs = (lmvm?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
        channelAvatarURL = ContentClient.imageURL(from: avatarSrcs?.last?["url"] as? String)
        // パス2: metadataRows 内を深く探索
        if channelAvatarURL == nil, let cmvm = (lmvm?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any],
           let rows = cmvm["metadataRows"] as? [[String: Any]] {
            for row in rows {
                if let rvm = row["metadataRowViewModel"] as? [String: Any] {
                    if let avatarVM = rvm["image"] as? [String: Any] {
                        let sources = (avatarVM["image"] as? [String: Any])?["sources"] as? [[String: Any]]
                            ?? avatarVM["sources"] as? [[String: Any]]
                        if let url = ContentClient.imageURL(from: sources?.last?["url"] as? String) {
                            channelAvatarURL = url
                            break
                        }
                    }
                }
            }
        }
        // パス3: lockupMetadataViewModel 内を再帰探索（yt3.ggpht.com）
        if channelAvatarURL == nil {
            channelAvatarURL = findAvatarURL(in: lmvm as Any)
        }

        // フィードバックトークン
        let tokens = extractFeedbackTokens(from: lvm)

        return VideoItem(
            videoId: contentId,
            title: title,
            channelId: channelId,
            channelName: channelName,
            thumbnailURL: thumbnailURL,
            channelAvatarURL: channelAvatarURL,
            viewCountText: nil,
            timePostedText: nil,
            playlistId: isPlaylist ? contentId : nil,
            feedbackTokens: tokens
        )
    }

    /// IOS 新形式の videoWithContextData オブジェクトから VideoItem を生成する。
    static func parseVideoWithContextData(_ data: [String: Any]) -> VideoItem? {
        // videoId
        let onTap       = data["onTap"]             as? [String: Any]
        let itCmd       = onTap?["innertubeCommand"] as? [String: Any]
        let watchEP     = itCmd?["watchEndpoint"]   as? [String: Any]
        guard let videoId = watchEP?["videoId"] as? String else { return nil }

        // metadata
        let videoData   = data["videoData"]         as? [String: Any]
        let metadata    = videoData?["metadata"]    as? [String: Any]

        // タイトル: 解決できないものは広告等の不正エントリとみなし除外する
        guard let title = metadata?["title"] as? String else { return nil }

        // チャンネル名: byline または channelName
        let channelName = (metadata?["byline"] as? String)
            ?? (metadata?["channelName"] as? String)

        // サムネイル: videoData.thumbnail.image.sources[last].url
        let thumbImage  = (videoData?["thumbnail"] as? [String: Any])?["image"] as? [String: Any]
        let thumbSrcs   = thumbImage?["sources"] as? [[String: Any]]
        let thumbURL    = ContentClient.imageURL(from: thumbSrcs?.last?["url"] as? String)

        // チャンネルアバター: channelThumbnail.image.sources[last].url
        let chThumbImg  = (data["channelThumbnail"] as? [String: Any])?["image"] as? [String: Any]
        let chThumbSrcs = chThumbImg?["sources"] as? [[String: Any]]
        let avatarURL   = ContentClient.imageURL(from: chThumbSrcs?.last?["url"] as? String)

        // チャンネルID
        let channelId = metadata?["channelId"] as? String
            ?? ((onTap?["innertubeCommand"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["channelId"] as? String

        // 視聴回数・投稿日時
        let viewCount   = metadata?["shortViewCountText"] as? String
        let timePosted  = metadata?["publishedTimeText"]  as? String

        // フィードバックトークン
        let tokens = extractFeedbackTokens(from: data)

        return VideoItem(
            videoId: videoId,
            title: title,
            channelId: channelId,
            channelName: channelName,
            thumbnailURL: thumbURL,
            channelAvatarURL: avatarURL,
            viewCountText: viewCount,
            timePostedText: timePosted,
            feedbackTokens: tokens
        )
    }

    /// メンバー限定動画を示すバッジを再帰的に検出する。
    /// WEB 新形式: badgeViewModel.badgeStyle == "BADGE_MEMBERS_ONLY"
    /// WEB 旧形式: metadataBadgeRenderer.style == "BADGE_STYLE_TYPE_MEMBERS_ONLY"
    static func containsMembersOnlyBadge(_ json: Any) -> Bool {
        if let dict = json as? [String: Any] {
            if dict["badgeStyle"] as? String == "BADGE_MEMBERS_ONLY" { return true }
            if dict["style"] as? String == "BADGE_STYLE_TYPE_MEMBERS_ONLY" { return true }
            for v in dict.values where containsMembersOnlyBadge(v) { return true }
        } else if let array = json as? [Any] {
            for v in array where containsMembersOnlyBadge(v) { return true }
        }
        return false
    }

    /// レンダラー JSON から feedbackToken を再帰的に抽出する。
    static func extractFeedbackTokens(from json: Any) -> [String] {
        var tokens: [String] = []
        collectFeedbackTokens(in: json, tokens: &tokens)
        return tokens
    }

    private static func collectFeedbackTokens(in json: Any, tokens: inout [String]) {
        if let dict = json as? [String: Any] {
            if let ep = dict["feedbackEndpoint"] as? [String: Any],
               let token = ep["feedbackToken"] as? String {
                tokens.append(token)
                return
            }
            if let token = dict["feedbackToken"] as? String,
               dict["feedbackEndpoint"] == nil {
                tokens.append(token)
                return
            }
            for (_, v) in dict { collectFeedbackTokens(in: v, tokens: &tokens) }
        } else if let array = json as? [Any] {
            for item in array { collectFeedbackTokens(in: item, tokens: &tokens) }
        }
    }

    /// /next レスポンスから動画説明欄データ（説明文・視聴回数・投稿日）を抽出する。
    static func extractVideoDescription(from json: Any) -> (description: String?, viewCount: String?, publishDate: String?) {
        var description: String?
        var viewCount: String?
        var publishDate: String?

        guard let dict = json as? [String: Any] else { return (nil, nil, nil) }

        // structuredDescriptionContentRenderer から取得
        func findStructured(in obj: Any) {
            if let d = obj as? [String: Any] {
                if let sdcr = d["structuredDescriptionContentRenderer"] as? [String: Any],
                   let items = sdcr["items"] as? [[String: Any]] {
                    for item in items {
                        if let hdr = item["videoDescriptionHeaderRenderer"] as? [String: Any] {
                            let viewRuns = (hdr["views"] as? [String: Any])?["simpleText"] as? String
                            if let v = viewRuns { viewCount = v }
                            let dateText = (hdr["publishDate"] as? [String: Any])?["simpleText"] as? String
                            if let d = dateText { publishDate = d }
                        }
                        if let body = item["expandableVideoDescriptionBodyRenderer"] as? [String: Any] {
                            let content = (body["attributedDescriptionBodyText"] as? [String: Any])?["content"] as? String
                                ?? (body["descriptionBodyText"] as? [String: Any])?["content"] as? String
                            if let c = content { description = c }
                        }
                    }
                    return
                }
                for (_, v) in d { findStructured(in: v) }
            } else if let a = obj as? [Any] {
                for item in a { findStructured(in: item) }
            }
        }
        findStructured(in: dict)

        // フォールバック: videoPrimaryInfoRenderer / videoSecondaryInfoRenderer
        if viewCount == nil || publishDate == nil {
            func findPrimary(in obj: Any) {
                if let d = obj as? [String: Any] {
                    if let vpir = d["videoPrimaryInfoRenderer"] as? [String: Any] {
                        if viewCount == nil {
                            let vcr = (vpir["viewCount"] as? [String: Any])?["videoViewCountRenderer"] as? [String: Any]
                            viewCount = (vcr?["viewCount"] as? [String: Any])?["simpleText"] as? String
                        }
                        if publishDate == nil {
                            publishDate = (vpir["dateText"] as? [String: Any])?["simpleText"] as? String
                        }
                        return
                    }
                    for (_, v) in d { findPrimary(in: v) }
                } else if let a = obj as? [Any] {
                    for item in a { findPrimary(in: item) }
                }
            }
            findPrimary(in: dict)
        }

        if description == nil {
            func findSecondary(in obj: Any) {
                if let d = obj as? [String: Any] {
                    if let vsir = d["videoSecondaryInfoRenderer"] as? [String: Any] {
                        description = (vsir["attributedDescription"] as? [String: Any])?["content"] as? String
                        return
                    }
                    for (_, v) in d { findSecondary(in: v) }
                } else if let a = obj as? [Any] {
                    for item in a { findSecondary(in: item) }
                }
            }
            findSecondary(in: dict)
        }

        return (description, viewCount, publishDate)
    }

    /// /next レスポンスの videoOwnerRenderer からチャンネルアバター URL を抽出する。
    static func extractOwnerAvatarURL(from json: Any) -> URL? {
        if let dict = json as? [String: Any] {
            if let vor = dict["videoOwnerRenderer"] as? [String: Any] {
                let thumbs = (vor["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                return imageURL(from: thumbs?.last?["url"] as? String)
            }
            for (_, v) in dict {
                if let url = extractOwnerAvatarURL(from: v) { return url }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let url = extractOwnerAvatarURL(from: item) { return url }
            }
        }
        return nil
    }

    /// JSON ツリー内から UC 始まりの browseId（チャンネルID）と隣接するテキスト（チャンネル名）を探索する。
    static func extractChannelInfo(from json: Any) -> (name: String?, id: String?) {
        var channelName: String?
        var channelId: String?
        findChannelBrowseEndpoints(in: json, name: &channelName, id: &channelId)
        return (channelName, channelId)
    }

    /// browseEndpoint.browseId が UC 始まりのものを探し、対応するテキストをチャンネル名として返す。
    private static func findChannelBrowseEndpoints(in json: Any, name: inout String?, id: inout String?) {
        guard id == nil else { return }
        if let dict = json as? [String: Any] {
            // "content" + "commandRuns" パターン
            if let content = dict["content"] as? String,
               let cmdRuns = dict["commandRuns"] as? [[String: Any]] {
                for cmdRun in cmdRuns {
                    if let browse = ((cmdRun["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
                       let bid = browse["browseId"] as? String, bid.hasPrefix("UC") {
                        name = content
                        id = bid
                        return
                    }
                }
            }
            // "runs" パターン
            if let runs = dict["runs"] as? [[String: Any]] {
                for run in runs {
                    if let text = run["text"] as? String,
                       let browse = (run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
                       let bid = browse["browseId"] as? String, bid.hasPrefix("UC") {
                        name = text
                        id = bid
                        return
                    }
                }
            }
            // decoratedAvatarViewModel パターン
            if let dav = dict["decoratedAvatarViewModel"] as? [String: Any] {
                let a11y = dav["a11yLabel"] as? String
                let rc = (dav["rendererContext"] as? [String: Any])?["commandContext"] as? [String: Any]
                let browse = ((rc?["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
                if let bid = browse?["browseId"] as? String, bid.hasPrefix("UC") {
                    id = bid
                    if let a11y, let start = a11y.firstIndex(of: "「"), let end = a11y.lastIndex(of: "」") {
                        let nameStart = a11y.index(after: start)
                        if nameStart < end {
                            name = String(a11y[nameStart..<end])
                        }
                    }
                    return
                }
            }
            // metadataParts パターン
            if let parts = dict["metadataParts"] as? [[String: Any]], id == nil {
                if name == nil, let firstText = (parts.first?["text"] as? [String: Any])?["content"] as? String {
                    name = firstText
                }
            }
            for (_, value) in dict {
                findChannelBrowseEndpoints(in: value, name: &name, id: &id)
                if id != nil { return }
            }
        } else if let array = json as? [Any] {
            for item in array {
                findChannelBrowseEndpoints(in: item, name: &name, id: &id)
                if id != nil { return }
            }
        }
    }

    /// JSON ツリー内から yt3.ggpht.com を含むアバター URL を再帰的に探索する。
    static func findAvatarURL(in json: Any) -> URL? {
        if let dict = json as? [String: Any] {
            if let urlStr = dict["url"] as? String, urlStr.contains("yt3.ggpht.com") {
                return imageURL(from: urlStr)
            }
            for (_, value) in dict {
                if let url = findAvatarURL(in: value) { return url }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let url = findAvatarURL(in: item) { return url }
            }
        }
        return nil
    }

    /// JSON ツリーを再帰的に探索して continuation token を抽出する。
    static func extractContinuationToken(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let cmd = dict["continuationCommand"] as? [String: Any],
               let token = cmd["token"] as? String {
                return token
            }
            for value in dict.values {
                if let token = extractContinuationToken(in: value) { return token }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let token = extractContinuationToken(in: item) { return token }
            }
        }
        return nil
    }

    /// YouTube のプロトコル相対 URL（`//` 始まり）を `https:` 付きに補正して URL を生成する。
    static func imageURL(from string: String?) -> URL? {
        guard var s = string, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }
}
