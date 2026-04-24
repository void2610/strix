//
//  ContentClient+Playlist.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/24.
//

import Foundation

// MARK: - フィードバック送信・プレイリスト操作

extension ContentClient {

    /// YouTube に feedbackToken を送信する（「興味なし」等）
    static func sendFeedback(tokens: [String]) async throws {
        guard !tokens.isEmpty else { return }
        try await InnertubeRequest.performWeb(url: YouTubeConstants.feedbackURL, body: [
            "feedbackTokens": tokens,
            "isFeedbackTokenUnencrypted": false,
            "shouldMerge": false
        ])
    }

    /// 動画を「後で見る」プレイリストに追加する
    static func addToWatchLater(videoId: String) async throws {
        try await addToPlaylist(playlistId: "WL", videoId: videoId)
    }

    /// 動画を任意のプレイリストに追加する
    static func addToPlaylist(playlistId: String, videoId: String) async throws {
        // VLプレフィックスを除去してAPIに渡す
        let rawId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        try await InnertubeRequest.performWeb(url: YouTubeConstants.editPlaylistURL, body: [
            "playlistId": rawId,
            "actions": [["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"]]
        ])
    }

    /// プレイリストそのものを削除（自身のプレイリストをライブラリから取り除く）
    static func deletePlaylist(playlistId: String) async throws {
        // VLプレフィックスを除去してAPIに渡す
        let rawId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        try await InnertubeRequest.performWeb(url: YouTubeConstants.deletePlaylistURL, body: [
            "playlistId": rawId
        ])
    }

    /// プレイリストから動画を削除する
    static func removeFromPlaylist(playlistId: String, videoId: String, setVideoId: String) async throws {
        try await InnertubeRequest.performWeb(url: YouTubeConstants.editPlaylistURL, body: [
            "playlistId": playlistId,
            "actions": [["setVideoId": setVideoId, "removedVideoId": videoId, "action": "ACTION_REMOVE_VIDEO"]]
        ])
    }

    /// /next エンドポイントでミックスリスト・プレイリストの動画一覧を取得する。
    static func fetchMixViaNextAPI(playlistId: String, cookies: String) async throws -> [VideoItem] {
        let json = try await callNextAPI(params: ["playlistId": playlistId], cookies: cookies)
        return parsePlaylistPanelRenderers(from: json)
    }

    /// playlistPanelVideoRenderer から VideoItem の配列をパースする。
    static func parsePlaylistPanelRenderers(from json: Any) -> [VideoItem] {
        var renderers: [[String: Any]] = []
        findPlaylistPanelRenderers(in: json, results: &renderers)
        return renderers.compactMap { renderer -> VideoItem? in
            guard let videoId = renderer["videoId"] as? String else { return nil }
            let title = (renderer["title"] as? [String: Any])?["simpleText"] as? String
                ?? ((renderer["title"] as? [String: Any])?["runs"] as? [[String: Any]])?.joinedText
                ?? videoId
            let thumbs = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let thumbURL = imageURL(from: thumbs?.last?["url"] as? String)
            let channelName = ((renderer["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String
                ?? ((renderer["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String
            return VideoItem(videoId: videoId, title: title, channelName: channelName, thumbnailURL: thumbURL)
        }
    }

    private static func findPlaylistPanelRenderers(in json: Any, results: inout [[String: Any]]) {
        if let dict = json as? [String: Any] {
            if let r = dict["playlistPanelVideoRenderer"] as? [String: Any] {
                results.append(r)
            } else {
                for (_, v) in dict { findPlaylistPanelRenderers(in: v, results: &results) }
            }
        } else if let array = json as? [Any] {
            for item in array { findPlaylistPanelRenderers(in: item, results: &results) }
        }
    }
}
