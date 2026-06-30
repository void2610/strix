//
//  ContentClient+Comments.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/24.
//

import Foundation

// MARK: - コメント取得

extension ContentClient {

    /// /next レスポンスからコメントセクションの continuation token を抽出する。
    static func extractCommentContinuation(from json: Any) -> String? {
        if let dict = json as? [String: Any] {
            // itemSectionRenderer 内の continuationItemRenderer からトークンを取得
            if let isr = dict["itemSectionRenderer"] as? [String: Any],
               let contents = isr["contents"] as? [[String: Any]] {
                for item in contents {
                    if let cir = item["continuationItemRenderer"] as? [String: Any],
                       let ep = cir["continuationEndpoint"] as? [String: Any],
                       let cmd = ep["continuationCommand"] as? [String: Any],
                       let token = cmd["token"] as? String {
                        return token
                    }
                }
            }
            // engagementPanels 内の sectionIdentifier == "comment-item-section" を検出
            if let panels = dict["engagementPanels"] as? [[String: Any]] {
                for panel in panels {
                    if let renderer = panel["engagementPanelSectionListRenderer"] as? [String: Any],
                       let id = renderer["panelIdentifier"] as? String,
                       id.contains("comment") {
                        if let token = extractCommentContinuation(from: renderer) {
                            return token
                        }
                    }
                }
            }
            for (key, v) in dict {
                // 返信スレッドの continuation はコメントセクションのトークンではないため辿らない
                if key == "commentRepliesRenderer" { continue }
                if let token = extractCommentContinuation(from: v) { return token }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let token = extractCommentContinuation(from: item) { return token }
            }
        }
        return nil
    }

    /// コメントスレッド1件分の情報（トップレベル commentId と返信の continuation token）
    private struct CommentThread {
        let commentId: String
        let repliesContinuation: String?
    }

    /// コメント取得 API レスポンスから CommentItem 配列と次ページトークンをパースする。
    /// YouTube の新形式では frameworkUpdates.entityBatchUpdate.mutations 内の
    /// commentEntityPayload からコメントデータを取得する。
    static func parseComments(from json: Any) -> (comments: [CommentItem], continuation: String?) {
        guard let dict = json as? [String: Any] else { return ([], nil) }

        // commentThreadRenderer からトップレベル commentId と返信 continuation を取得
        var threads: [CommentThread] = []
        collectCommentThreads(in: dict, threads: &threads)

        // frameworkUpdates.entityBatchUpdate.mutations から commentEntityPayload を収集
        var payloadMap: [String: CommentItem] = [:]
        if let fu = dict["frameworkUpdates"] as? [String: Any],
           let eu = fu["entityBatchUpdate"] as? [String: Any],
           let mutations = eu["mutations"] as? [[String: Any]] {
            for mutation in mutations {
                guard let payload = mutation["payload"] as? [String: Any],
                      let cep = payload["commentEntityPayload"] as? [String: Any],
                      let item = parseCommentEntityPayload(cep) else { continue }
                payloadMap[item.id] = item
            }
        }

        let topLevelIds = Set(threads.map(\.commentId))

        // commentThreadRenderer の順序に従ってトップレベルコメントのみを並べる
        var comments: [CommentItem] = []
        for thread in threads {
            if var item = payloadMap[thread.commentId] {
                item.repliesContinuation = thread.repliesContinuation
                comments.append(item)
            }
        }

        // フォールバック: threads が空の場合は replyCount > 0 またはすべてをトップレベル扱い
        if comments.isEmpty && !payloadMap.isEmpty {
            // replyCount が 0 より大きいものはトップレベルの可能性が高い
            let candidates = payloadMap.values.filter { $0.replyCount > 0 }
            if !candidates.isEmpty {
                comments = candidates.sorted { $0.id < $1.id }
            } else {
                // 区別不能な場合はすべて表示（返信がないコメントのみの動画）
                comments = Array(payloadMap.values)
            }
        }

        // ページネーション用の continuation token
        let nextContinuation = findCommentNextContinuation(in: dict)

        return (comments, nextContinuation)
    }

    /// 返信コメントをパースする（continuation token で取得した返信スレッド）。
    static func parseReplies(from json: Any) -> (comments: [CommentItem], continuation: String?) {
        guard let dict = json as? [String: Any] else { return ([], nil) }

        // 返信の commentId を収集（commentRenderer から取得）
        var replyIds: [String] = []
        collectReplyIds(in: dict, ids: &replyIds)

        // mutations から全コメントペイロードを収集
        var payloadMap: [String: CommentItem] = [:]
        if let fu = dict["frameworkUpdates"] as? [String: Any],
           let eu = fu["entityBatchUpdate"] as? [String: Any],
           let mutations = eu["mutations"] as? [[String: Any]] {
            for mutation in mutations {
                guard let payload = mutation["payload"] as? [String: Any],
                      let cep = payload["commentEntityPayload"] as? [String: Any],
                      let item = parseCommentEntityPayload(cep) else { continue }
                payloadMap[item.id] = item
            }
        }

        // replyIds の順序で返信を並べる
        var comments: [CommentItem] = []
        for id in replyIds {
            if let item = payloadMap[id] {
                comments.append(item)
            }
        }
        // フォールバック: replyIds が空なら全ペイロードを返す
        if comments.isEmpty {
            comments = Array(payloadMap.values)
        }

        let nextContinuation = findCommentNextContinuation(in: dict)
        return (comments, nextContinuation)
    }

    /// commentThreadRenderer からトップレベル commentId と返信 continuation token を収集する。
    private static func collectCommentThreads(in json: Any, threads: inout [CommentThread]) {
        if let dict = json as? [String: Any] {
            if let ctr = dict["commentThreadRenderer"] as? [String: Any] {
                // commentId を取得（複数パスを試行）
                var commentId: String?
                if let cvm = ctr["commentViewModel"] as? [String: Any],
                   let inner = cvm["commentViewModel"] as? [String: Any],
                   let id = inner["commentId"] as? String {
                    commentId = id
                } else if let comment = ctr["comment"] as? [String: Any],
                          let cr = comment["commentRenderer"] as? [String: Any],
                          let id = cr["commentId"] as? String {
                    commentId = id
                }

                // 返信 continuation token を取得
                var repliesCont: String?
                if let replies = ctr["replies"] as? [String: Any],
                   let crr = replies["commentRepliesRenderer"] as? [String: Any],
                   let contents = crr["contents"] as? [[String: Any]] {
                    for item in contents {
                        if let cir = item["continuationItemRenderer"] as? [String: Any],
                           let ep = cir["continuationEndpoint"] as? [String: Any],
                           let cmd = ep["continuationCommand"] as? [String: Any],
                           let token = cmd["token"] as? String {
                            repliesCont = token
                            break
                        }
                    }
                }

                if let commentId {
                    threads.append(CommentThread(commentId: commentId, repliesContinuation: repliesCont))
                    return
                }
            }
            for (_, v) in dict { collectCommentThreads(in: v, threads: &threads) }
        } else if let array = json as? [Any] {
            for item in array { collectCommentThreads(in: item, threads: &threads) }
        }
    }

    /// 返信レスポンスから commentRenderer の commentId を順序通りに収集する。
    private static func collectReplyIds(in json: Any, ids: inout [String]) {
        if let dict = json as? [String: Any] {
            // commentViewModel 形式
            if let cvm = dict["commentViewModel"] as? [String: Any],
               let id = cvm["commentId"] as? String {
                ids.append(id)
                return
            }
            // commentRenderer 形式
            if let cr = dict["commentRenderer"] as? [String: Any],
               let id = cr["commentId"] as? String {
                ids.append(id)
                return
            }
            for (_, v) in dict { collectReplyIds(in: v, ids: &ids) }
        } else if let array = json as? [Any] {
            for item in array { collectReplyIds(in: item, ids: &ids) }
        }
    }

    /// commentEntityPayload から CommentItem をパースする（新形式）。
    private static func parseCommentEntityPayload(_ cep: [String: Any]) -> CommentItem? {
        let properties = cep["properties"] as? [String: Any] ?? [:]
        let author = cep["author"] as? [String: Any] ?? [:]
        let toolbar = cep["toolbar"] as? [String: Any] ?? [:]

        guard let commentId = properties["commentId"] as? String else { return nil }

        // コメント本文
        let contentText = (properties["content"] as? [String: Any])?["content"] as? String ?? ""
        guard !contentText.isEmpty else { return nil }

        // 著者名
        let authorName = author["displayName"] as? String ?? "不明"

        // 著者アバター
        let avatarURL = (author["avatarThumbnailUrl"] as? String).flatMap { URL(string: $0) }

        // 投稿日時
        let publishedTime = properties["publishedTime"] as? String

        // 高評価数
        let likeCountText = toolbar["likeCountNotliked"] as? String

        // 返信数
        let replyCount = Int(toolbar["replyCount"] as? String ?? "") ?? 0

        return CommentItem(
            id: commentId,
            authorName: authorName,
            authorAvatarURL: avatarURL,
            contentText: contentText,
            publishedTimeText: publishedTime,
            likeCountText: likeCountText,
            replyCount: replyCount
        )
    }

    /// コメントレスポンスからページネーション用の continuation token を探す。
    private static func findCommentNextContinuation(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            // continuationItemRenderer 内のトークン
            if let cir = dict["continuationItemRenderer"] as? [String: Any] {
                if let ep = cir["continuationEndpoint"] as? [String: Any],
                   let cmd = ep["continuationCommand"] as? [String: Any],
                   let token = cmd["token"] as? String {
                    return token
                }
            }
            for (key, v) in dict {
                // 返信スレッドの continuation は次ページトークンではないため辿らない。
                // Dictionary の反復順は非決定的なため、除外しないと返信トークンを誤って掴む。
                if key == "commentRepliesRenderer" { continue }
                if let token = findCommentNextContinuation(in: v) { return token }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let token = findCommentNextContinuation(in: item) { return token }
            }
        }
        return nil
    }
}
