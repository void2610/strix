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
            for (_, v) in dict {
                if let token = extractCommentContinuation(from: v) { return token }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let token = extractCommentContinuation(from: item) { return token }
            }
        }
        return nil
    }

    /// コメント取得 API レスポンスから CommentItem 配列と次ページトークンをパースする。
    /// YouTube の新形式では frameworkUpdates.entityBatchUpdate.mutations 内の
    /// commentEntityPayload からコメントデータを取得する。
    static func parseComments(from json: Any) -> (comments: [CommentItem], continuation: String?) {
        guard let dict = json as? [String: Any] else { return ([], nil) }

        // commentThreadRenderer から commentId の順序を取得
        var orderedIds: [String] = []
        collectCommentIds(in: dict, ids: &orderedIds)

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

        // commentThreadRenderer の順序に従ってコメントを並べる
        var comments: [CommentItem] = []
        for id in orderedIds {
            if let item = payloadMap[id] {
                comments.append(item)
            }
        }
        // 順序リストにない（フォールバック用）コメントも追加
        if comments.isEmpty {
            comments = Array(payloadMap.values)
        }

        // ページネーション用の continuation token
        let nextContinuation = findCommentNextContinuation(in: dict)

        return (comments, nextContinuation)
    }

    /// commentThreadRenderer から commentId を収集して表示順序を決定する。
    private static func collectCommentIds(in json: Any, ids: inout [String]) {
        if let dict = json as? [String: Any] {
            if let ctr = dict["commentThreadRenderer"] as? [String: Any],
               let cvm = ctr["commentViewModel"] as? [String: Any],
               let inner = cvm["commentViewModel"] as? [String: Any],
               let commentId = inner["commentId"] as? String {
                ids.append(commentId)
                return
            }
            for (_, v) in dict { collectCommentIds(in: v, ids: &ids) }
        } else if let array = json as? [Any] {
            for item in array { collectCommentIds(in: item, ids: &ids) }
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
            for (_, v) in dict {
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
