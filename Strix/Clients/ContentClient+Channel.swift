//
//  ContentClient+Channel.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/24.
//

import Foundation

// MARK: - チャンネル情報取得

extension ContentClient {

    /// Innertube /browse でチャンネルヘッダー情報を取得する。
    static func fetchChannelViaInnertube(channelId: String, cookies: String) async throws -> ChannelInfo {
        let json = try await callBrowseAPI(browseId: channelId, params: nil, cookies: cookies)

        // ヘッダー情報をパース（c4TabbedHeaderRenderer または pageHeaderRenderer）
        let header = json["header"] as? [String: Any]
        let c4 = header?["c4TabbedHeaderRenderer"] as? [String: Any]
        let pageHeader = (header?["pageHeaderRenderer"] as? [String: Any])
        let pageHeaderContent = (pageHeader?["content"] as? [String: Any])?["pageHeaderViewModel"] as? [String: Any]

        let name = c4?["title"] as? String
            ?? extractTextFromPageHeader(pageHeaderContent, key: "title")
        let handle = (c4?["channelHandleText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let handleText = handle?.compactMap({ $0["text"] as? String }).joined()
            ?? extractTextFromPageHeader(pageHeaderContent, key: "subtitle")
        let subscriberCount = (c4?["subscriberCountText"] as? [String: Any])?["simpleText"] as? String
            ?? extractMetadataFromPageHeader(pageHeaderContent, index: 0)
        let videoCount = (c4?["videosCountText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let videoCountText = videoCount?.compactMap({ $0["text"] as? String }).joined()
            ?? extractMetadataFromPageHeader(pageHeaderContent, index: 1)

        let avatarThumbs = (c4?["avatar"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let pageAvatarImage = (pageHeaderContent?["image"] as? [String: Any])?["decoratedAvatarViewModel"] as? [String: Any]
        let pageAvatarSources = ((pageAvatarImage?["avatar"] as? [String: Any])?["avatarViewModel"] as? [String: Any])?["image"] as? [String: Any]
        let avatarSources = avatarThumbs ?? (pageAvatarSources?["sources"] as? [[String: Any]])
        let avatarURL = ContentClient.imageURL(from: avatarSources?.last?["url"] as? String)

        let bannerThumbs = (c4?["banner"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let pageBanner = (pageHeaderContent?["banner"] as? [String: Any])?["imageBannerViewModel"] as? [String: Any]
        let pageBannerSources = (pageBanner?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
        let bannerSources = bannerThumbs ?? pageBannerSources
        let bannerURL = ContentClient.imageURL(from: bannerSources?.last?["url"] as? String)

        return ChannelInfo(
            channelId: channelId,
            name: name,
            handle: handleText,
            subscriberCount: subscriberCount,
            videoCount: videoCountText,
            avatarURL: avatarURL,
            bannerURL: bannerURL
        )
    }

    /// チャンネルの特定タブを取得する（params で動画/ライブ/プレイリストを切り替え）。
    static func fetchChannelTabViaInnertube(channelId: String, params: String?, cookies: String) async throws -> ([VideoItem], String?) {
        let json = try await callBrowseAPI(browseId: channelId, params: params, cookies: cookies)
        let videos = findVideoRenderers(in: json).compactMap { parseVideoRenderer($0) }
        let continuation = extractContinuationToken(in: json)
        return (videos, continuation)
    }

    /// pageHeaderViewModel からテキストを抽出するヘルパー
    static func extractTextFromPageHeader(_ pageHeader: [String: Any]?, key: String) -> String? {
        guard let ph = pageHeader else { return nil }
        if let titleVM = (ph[key] as? [String: Any])?["dynamicTextViewModel"] as? [String: Any] {
            return (titleVM["text"] as? [String: Any])?["content"] as? String
        }
        return (ph[key] as? [String: Any])?["content"] as? String
    }

    /// pageHeaderViewModel の metadata からインデックス指定でテキストを取得するヘルパー
    static func extractMetadataFromPageHeader(_ pageHeader: [String: Any]?, index: Int) -> String? {
        guard let ph = pageHeader,
              let metadata = (ph["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any],
              let rows = metadata["metadataRows"] as? [[String: Any]],
              index < rows.count,
              let parts = rows[index]["metadataParts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = (firstPart["text"] as? [String: Any])?["content"] as? String
        else { return nil }
        return text
    }

    /// JSON ツリーから lockupViewModel (PLAYLIST/ALBUM) をパースしてプレイリスト一覧を返す。
    static func parsePlaylistLockups(from json: Any) -> [ChannelPlaylistItem] {
        var items: [ChannelPlaylistItem] = []
        findLockups(in: json, items: &items)
        return items
    }

    private static func findLockups(in json: Any, items: inout [ChannelPlaylistItem]) {
        if let dict = json as? [String: Any] {
            if let lvm = dict["lockupViewModel"] as? [String: Any],
               let contentType = lvm["contentType"] as? String,
               contentType.contains("PLAYLIST") || contentType.contains("ALBUM"),
               let contentId = lvm["contentId"] as? String {
                let meta = (lvm["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
                let title = (meta?["title"] as? [String: Any])?["content"] as? String ?? contentId

                // サムネイル: collectionThumbnailViewModel.primaryThumbnail.thumbnailViewModel.image.sources
                let ci = lvm["contentImage"] as? [String: Any]
                let ctvm = ci?["collectionThumbnailViewModel"] as? [String: Any]
                    ?? ci?["thumbnailViewModel"] as? [String: Any]
                let primaryThumb = (ctvm?["primaryThumbnail"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
                    ?? ctvm
                let thumbSrcs = (primaryThumb?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
                let thumbnailURL = imageURL(from: thumbSrcs?.first?["url"] as? String)

                // 動画数: overlays 内の thumbnailBadgeViewModel.text
                var videoCount: String? = nil
                if let overlays = primaryThumb?["overlays"] as? [[String: Any]] {
                    for overlay in overlays {
                        if let badge = overlay["thumbnailOverlayBadgeViewModel"] as? [String: Any],
                           let badges = badge["thumbnailBadges"] as? [[String: Any]],
                           let first = badges.first,
                           let text = (first["thumbnailBadgeViewModel"] as? [String: Any])?["text"] as? String {
                            videoCount = text
                            break
                        }
                    }
                }

                items.append(ChannelPlaylistItem(
                    playlistId: contentId,
                    title: title,
                    thumbnailURL: thumbnailURL,
                    videoCount: videoCount
                ))
            } else {
                for (_, value) in dict { findLockups(in: value, items: &items) }
            }
        } else if let array = json as? [Any] {
            for item in array { findLockups(in: item, items: &items) }
        }
    }
}
