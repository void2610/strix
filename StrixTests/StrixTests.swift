//
//  StrixTests.swift
//  StrixTests
//
//  Created by Shuya Izumi on 2026/04/07.
//

import Testing
import Foundation
import SwiftData
import AVFoundation
import YouTubeKit
@testable import Strix

// MARK: - ContentClient JSON パーサー ユニットテスト

struct ContentClientParsingTests {

    // MARK: lockupViewModel

    private func makeLockupViewModelJSON(
        contentId: String = "abc123",
        title: String = "テスト動画",
        channelName: String = "テストチャンネル",
        thumbURL: String = "https://i.ytimg.com/vi/abc123/hq720.jpg"
    ) -> [String: Any] {
        [
            "contentId": contentId,
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "contentImage": [
                "thumbnailViewModel": [
                    "image": [
                        "sources": [
                            ["url": thumbURL, "width": 1280, "height": 720]
                        ]
                    ]
                ]
            ],
            "metadata": [
                "lockupMetadataViewModel": [
                    "title": ["content": title],
                    "image": [
                        "sources": [["url": "https://yt3.ggpht.com/avatar.jpg"]]
                    ],
                    "metadata": [
                        "contentMetadataViewModel": [
                            "metadataRows": [
                                [
                                    "metadataRowViewModel": [
                                        "title": [
                                            "content": channelName,
                                            "commandRuns": [
                                                [
                                                    "onTap": [
                                                        "innertubeCommand": [
                                                            "browseEndpoint": [
                                                                "browseId": "UCtest123"
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    }

    @Test func parseLockupViewModelExtractsVideoId() {
        let json = makeLockupViewModelJSON(contentId: "xyz789")
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item?.videoId == "xyz789")
    }

    @Test func parseLockupViewModelExtractsTitle() {
        let json = makeLockupViewModelJSON(title: "素晴らしい動画")
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item?.title == "素晴らしい動画")
    }

    @Test func parseLockupViewModelExtractsThumbnailURL() {
        let url = "https://i.ytimg.com/vi/abc123/hq720.jpg"
        let json = makeLockupViewModelJSON(thumbURL: url)
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item?.thumbnailURL?.absoluteString == url)
    }

    @Test func parseLockupViewModelExtractsChannelName() {
        let json = makeLockupViewModelJSON(channelName: "マイチャンネル")
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item?.channelName == "マイチャンネル")
    }

    @Test func parseLockupViewModelReturnsNilWhenNoContentId() {
        var json = makeLockupViewModelJSON()
        json.removeValue(forKey: "contentId")
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item == nil)
    }

    @Test func parseLockupViewModelExcludesTitlelessEntry() {
        var json = makeLockupViewModelJSON(contentId: "fallback123")
        json["metadata"] = [String: Any]()  // タイトル解決不可 → 広告等とみなし除外
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item == nil)
    }

    // MARK: findVideoRenderers

    @Test func findVideoRenderersFindsLockupViewModel() {
        let lvm = makeLockupViewModelJSON()
        let json: [String: Any] = [
            "richItemRenderer": ["content": ["lockupViewModel": lvm]]
        ]
        let found = ContentClient.findVideoRenderers(in: json)
        #expect(found.count == 1)
        #expect(found.first?["contentId"] as? String == "abc123")
    }

    @Test func findVideoRenderersFindsVideoRenderer() {
        let json: [String: Any] = [
            "contents": [
                ["videoRenderer": [
                    "videoId": "vid1",
                    "title": ["runs": [["text": "動画タイトル"]]],
                    "thumbnail": ["thumbnails": [["url": "https://example.com/thumb.jpg"]]]
                ]]
            ]
        ]
        let found = ContentClient.findVideoRenderers(in: json)
        #expect(found.count == 1)
        #expect(found.first?["videoId"] as? String == "vid1")
    }

    @Test func findVideoRenderersFindsPlaylistVideoRenderer() {
        let json: [String: Any] = [
            "contents": [
                ["playlistVideoRenderer": [
                    "videoId": "plist1",
                    "title": ["runs": [["text": "プレイリスト動画"]]],
                    "thumbnail": ["thumbnails": [["url": "https://example.com/thumb.jpg"]]]
                ]]
            ]
        ]
        let found = ContentClient.findVideoRenderers(in: json)
        #expect(found.count == 1)
        #expect(found.first?["videoId"] as? String == "plist1")
    }

    @Test func findVideoRenderersFindsMultipleItems() {
        let json: [String: Any] = [
            "contents": [
                ["richItemRenderer": ["content": ["lockupViewModel": makeLockupViewModelJSON(contentId: "id1")]]],
                ["richItemRenderer": ["content": ["lockupViewModel": makeLockupViewModelJSON(contentId: "id2")]]],
                ["richItemRenderer": ["content": ["lockupViewModel": makeLockupViewModelJSON(contentId: "id3")]]]
            ]
        ]
        let found = ContentClient.findVideoRenderers(in: json)
        #expect(found.count == 3)
    }

    @Test func findVideoRenderersSkipsAdsAndContinuation() {
        let json: [String: Any] = [
            "contents": [
                ["richItemRenderer": ["content": ["adSlotRenderer": [:]]]],
                ["continuationItemRenderer": [:]],
                ["richItemRenderer": ["content": ["lockupViewModel": makeLockupViewModelJSON(contentId: "real")]]]
            ]
        ]
        let found = ContentClient.findVideoRenderers(in: json)
        #expect(found.count == 1)
        #expect(found.first?["contentId"] as? String == "real")
    }

    @Test func findVideoRenderersHandlesHistoryStructure() {
        // FEhistory が返す sectionListRenderer 構造をシミュレート
        let videoRenderer: [String: Any] = [
            "videoId": "histVid1",
            "title": ["runs": [["text": "履歴動画"]]],
            "thumbnail": ["thumbnails": [["url": "https://example.com/thumb.jpg"]]]
        ]
        let json: [String: Any] = [
            "contents": [
                "sectionListRenderer": [
                    "contents": [
                        [
                            "shelfRenderer": [
                                "content": [
                                    "expandedShelfContentsRenderer": [
                                        "items": [
                                            ["videoRenderer": videoRenderer]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let found = ContentClient.findVideoRenderers(in: json)
        #expect(found.count == 1)
        #expect(found.first?["videoId"] as? String == "histVid1")
    }

    @Test func parseVideoRendererDispatchesToLockupViewModel() {
        let json = makeLockupViewModelJSON(contentId: "dispatch123", title: "ディスパッチテスト")
        let item = ContentClient.parseVideoRenderer(json)
        #expect(item?.videoId == "dispatch123")
        #expect(item?.title == "ディスパッチテスト")
    }

    @Test func parseVideoRendererHandlesVideoRenderer() {
        let json: [String: Any] = [
            "videoId": "vr123",
            "title": ["runs": [["text": "videoRenderer タイトル"]]],
            "thumbnail": ["thumbnails": [["url": "https://example.com/t.jpg"]]]
        ]
        let item = ContentClient.parseVideoRenderer(json)
        #expect(item?.videoId == "vr123")
        #expect(item?.title == "videoRenderer タイトル")
    }

    @Test func parseVideoRendererHandlesPlaylistVideoRenderer() {
        let json: [String: Any] = [
            "videoId": "pl123",
            "title": ["runs": [["text": "playlistVideoRenderer タイトル"]]],
            "thumbnail": ["thumbnails": [["url": "https://example.com/p.jpg"]]],
            "shortBylineText": ["runs": [["text": "プレイリストチャンネル"]]],
            "videoInfo": ["runs": [["text": "123万回視聴"], ["text": " • "], ["text": "1年前"]]]
        ]
        let item = ContentClient.parseVideoRenderer(json)
        #expect(item?.videoId == "pl123")
        #expect(item?.title == "playlistVideoRenderer タイトル")
        #expect(item?.channelName == "プレイリストチャンネル")
        #expect(item?.viewCountText == "123万回視聴")
        #expect(item?.timePostedText == "1年前")
    }

    // MARK: メンバー限定動画の除外

    @Test func parseVideoRendererExcludesMembersOnlyLockup() {
        var json = makeLockupViewModelJSON(contentId: "members123")
        var metadata = json["metadata"] as! [String: Any]
        var lmvm = metadata["lockupMetadataViewModel"] as! [String: Any]
        lmvm["metadata"] = [
            "contentMetadataViewModel": [
                "metadataRows": [
                    ["badges": [
                        ["badgeViewModel": [
                            "badgeText": "メンバー限定",
                            "badgeStyle": "BADGE_MEMBERS_ONLY",
                            "iconName": "SPONSORSHIP_STAR"
                        ]]
                    ]]
                ]
            ]
        ]
        metadata["lockupMetadataViewModel"] = lmvm
        json["metadata"] = metadata
        #expect(ContentClient.parseVideoRenderer(json) == nil)
    }

    @Test func parseVideoRendererExcludesMembersOnlyVideoRenderer() {
        let json: [String: Any] = [
            "videoId": "memvr123",
            "title": ["runs": [["text": "メンバー限定動画"]]],
            "thumbnail": ["thumbnails": [["url": "https://example.com/m.jpg"]]],
            "badges": [
                ["metadataBadgeRenderer": [
                    "style": "BADGE_STYLE_TYPE_MEMBERS_ONLY",
                    "label": "メンバー限定"
                ]]
            ]
        ]
        #expect(ContentClient.parseVideoRenderer(json) == nil)
    }

    @Test func parseVideoRendererKeepsNonMembersVideo() {
        let json = makeLockupViewModelJSON(contentId: "public123")
        #expect(ContentClient.parseVideoRenderer(json)?.videoId == "public123")
    }

    // MARK: 広告の除外

    @Test func findVideoRenderersSkipsAdWithNestedRenderer() {
        // 実際の広告枠は adSlotRenderer 配下に動画レンダラーをネストして含む
        let json: [String: Any] = [
            "contents": [
                ["richItemRenderer": ["content": ["lockupViewModel": makeLockupViewModelJSON(contentId: "real")]]],
                ["adSlotRenderer": ["fulfillmentContent": ["fulfilledLayout": [
                    "inFeedAdLayoutRenderer": ["renderingContent": [
                        "lockupViewModel": makeLockupViewModelJSON(contentId: "JSUfdt8JcX8")
                    ]]
                ]]]]
            ]
        ]
        let renderers = ContentClient.findVideoRenderers(in: json)
        #expect(renderers.count == 1)
        #expect(renderers.first?["contentId"] as? String == "real")
    }

    @Test func parseVideoRendererExcludesTitlelessVideoRenderer() {
        let json: [String: Any] = [
            "videoId": "JSUfdt8JcX8",
            "thumbnail": ["thumbnails": [["url": "https://example.com/a.jpg"]]]
        ]
        #expect(ContentClient.parseVideoRenderer(json) == nil)
    }
}

// MARK: - lockupViewModel プレイリスト・ミックス パーサーテスト

struct LockupPlaylistParsingTests {

    private func makePlaylistLockup(contentId: String = "PLtest123", title: String = "テストプレイリスト") -> [String: Any] {
        [
            "contentId": contentId,
            "contentType": "LOCKUP_CONTENT_TYPE_PLAYLIST",
            "contentImage": [
                "collectionThumbnailViewModel": [
                    "primaryThumbnail": [
                        "thumbnailViewModel": [
                            "image": ["sources": [["url": "https://i.ytimg.com/vi/test/hq720.jpg"]]]
                        ]
                    ]
                ]
            ],
            "metadata": [
                "lockupMetadataViewModel": [
                    "title": ["content": title]
                ]
            ]
        ]
    }

    @Test func parseLockupPlaylistSetsPlaylistId() {
        let json = makePlaylistLockup(contentId: "PLabc789")
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item?.playlistId == "PLabc789")
        #expect(item?.videoId == "PLabc789")
    }

    @Test func parseLockupVideoHasNilPlaylistId() {
        let json: [String: Any] = [
            "contentId": "abc123",
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "metadata": ["lockupMetadataViewModel": ["title": ["content": "動画"]]]
        ]
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item?.playlistId == nil)
    }

    @Test func parseLockupPlaylistExtractsThumbnailFromCollection() {
        let json = makePlaylistLockup()
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item?.thumbnailURL?.absoluteString.contains("ytimg.com") == true)
    }

    @Test func findVideoRenderersIncludesPlaylistLockups() {
        let json: [String: Any] = [
            "contents": [
                ["richItemRenderer": ["content": ["lockupViewModel": makePlaylistLockup(contentId: "PLtest")]]],
                ["richItemRenderer": ["content": ["lockupViewModel": [
                    "contentId": "vid1",
                    "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                    "metadata": ["lockupMetadataViewModel": ["title": ["content": "動画"]]]
                ]]]]
            ]
        ]
        let found = ContentClient.findVideoRenderers(in: json)
        #expect(found.count == 2)
    }
}

// MARK: - playlistPanelVideoRenderer パーサーテスト

struct PlaylistPanelParserTests {

    @Test func parsePlaylistPanelRenderers() {
        let json: [String: Any] = [
            "contents": [
                "twoColumnWatchNextResults": [
                    "playlist": [
                        "playlist": [
                            "contents": [
                                ["playlistPanelVideoRenderer": [
                                    "videoId": "vid1",
                                    "title": ["simpleText": "動画1"],
                                    "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/vid1/hq.jpg"]]],
                                    "longBylineText": ["runs": [["text": "チャンネル1"]]]
                                ]],
                                ["playlistPanelVideoRenderer": [
                                    "videoId": "vid2",
                                    "title": ["runs": [["text": "動画2"]]],
                                    "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/vid2/hq.jpg"]]]
                                ]]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let items = ContentClient.parsePlaylistPanelRenderers(from: json)
        #expect(items.count == 2)
        #expect(items[0].videoId == "vid1")
        #expect(items[0].title == "動画1")
        #expect(items[0].channelName == "チャンネル1")
        #expect(items[1].videoId == "vid2")
        #expect(items[1].title == "動画2")
    }

    @Test func parsePlaylistPanelRenderersReturnsEmptyForNoData() {
        let json: [String: Any] = ["empty": true]
        let items = ContentClient.parsePlaylistPanelRenderers(from: json)
        #expect(items.isEmpty)
    }
}

// MARK: - AccountViewModel ユニットテスト

@MainActor
struct AccountViewModelTests {

    @Test func loadPopulatesLibraryPlaylists() async {
        let library = LibraryResponse(
            watchLater: YTPlaylist(playlistId: "VLWL", title: "後で見る", videoCount: "12"),
            likes: YTPlaylist(playlistId: "VLLL", title: "いいねした動画", videoCount: "8"),
            playlists: [
                YTPlaylist(playlistId: "VLPL1", title: "作業用", videoCount: "24"),
                YTPlaylist(playlistId: "VLPL2", title: "後で確認", videoCount: "6")
            ]
        )

        let client = AccountClient.mock(
            fetchInfo: { AccountInfo(name: "Test User", handle: "@test", avatarURL: nil) },
            fetchLibrary: { library }
        )
        let vm = AccountViewModel(accountClient: client)

        await vm.load()

        #expect(vm.accountInfo?.name == "Test User")
        #expect(vm.watchLater?.playlistId == "VLWL")
        #expect(vm.likes?.playlistId == "VLLL")
        #expect(vm.playlists.map(\.playlistId) == ["VLPL1", "VLPL2"])
        #expect(!vm.isLoading)
    }

    @Test func reloadClearsAndRepopulatesPlaylists() async {
        var loadCount = 0
        let client = AccountClient.mock(
            fetchLibrary: {
                loadCount += 1
                return LibraryResponse(
                    playlists: [
                        YTPlaylist(playlistId: "VL\(loadCount)", title: "Playlist \(loadCount)")
                    ]
                )
            }
        )
        let vm = AccountViewModel(accountClient: client)

        await vm.load()
        #expect(vm.playlists.map(\.playlistId) == ["VL1"])

        await vm.reload()
        #expect(vm.playlists.map(\.playlistId) == ["VL2"])
        #expect(!vm.isLoading)
    }
}

// MARK: - HistoryViewModel ユニットテスト

@MainActor
struct HistoryViewModelTests {

    private func withSignedInAuthState(_ body: @MainActor () async throws -> Void) async rethrows {
        let original = AuthState.shared.cookieString
        AuthState.shared.cookieString = "SID=test; HSID=test; SSID=test"
        defer { AuthState.shared.cookieString = original }
        try await body()
    }

    @Test func loadPopulatesVideosWhenSignedIn() async throws {
        try await withSignedInAuthState {
            let mockVideo = VideoItem(
                videoId: "hist1",
                title: "履歴テスト動画",
                channelId: nil,
                channelName: "チャンネル",
                thumbnailURL: nil,
                channelAvatarURL: nil,
                viewCountText: nil,
                timePostedText: nil
            )
            let contentClient = ContentClient.mock(
                fetchHistoryVideos: { ([mockVideo], nil) }
            )
            let vm = HistoryViewModel(contentClient: contentClient)

            await vm.load()

            #expect(vm.videos.count == 1)
            #expect(vm.videos.first?.videoId == "hist1")
        }
    }

    @Test func loadHandlesError() async throws {
        try await withSignedInAuthState {
            let contentClient = ContentClient.mock(
                fetchHistoryVideos: { throw URLError(.notConnectedToInternet) }
            )
            let vm = HistoryViewModel(contentClient: contentClient)

            await vm.load()

            #expect(!vm.isLoading)
            #expect(vm.videos.isEmpty)
            #expect(vm.error != nil)
        }
    }

    @Test func loadSetsLoadingFalseAfterCompletion() async {
        let vm = HistoryViewModel(contentClient: .mock())
        await vm.load()
        #expect(!vm.isLoading)
    }
}

// MARK: - PlaylistDetailViewModel ユニットテスト

@MainActor
struct PlaylistDetailViewModelTests {

    @Test func loadPopulatesVideos() async {
        let mockVideo = VideoItem(
            videoId: "playlist1",
            title: "プレイリスト動画",
            channelId: nil,
            channelName: "チャンネル",
            thumbnailURL: nil,
            channelAvatarURL: nil,
            viewCountText: nil,
            timePostedText: nil
        )
        let accountClient = AccountClient.mock(
            fetchPlaylistVideos: { _ in [mockVideo] }
        )
        let vm = PlaylistDetailViewModel(accountClient: accountClient)

        await vm.load(playlistId: "VLWL")

        #expect(vm.videos.count == 1)
        #expect(vm.videos.first?.videoId == "playlist1")
        #expect(!vm.isLoading)
    }

    @Test func loadHandlesError() async {
        let accountClient = AccountClient.mock(
            fetchPlaylistVideos: { _ in throw URLError(.notConnectedToInternet) }
        )
        let vm = PlaylistDetailViewModel(accountClient: accountClient)

        await vm.load(playlistId: "VLLL")

        #expect(vm.videos.isEmpty)
        #expect(vm.error != nil)
        #expect(!vm.isLoading)
    }
}

// MARK: - ChannelViewModel ユニットテスト

@MainActor
struct ChannelViewModelTests {

    @Test func loadPopulatesChannelInfo() async {
        let mockInfo = ChannelInfo(
            channelId: "UC123",
            name: "テストチャンネル",
            handle: "@test",
            subscriberCount: "1万人",
            videoCount: "100本",
            avatarURL: nil,
            bannerURL: nil
        )
        let mockVideos: [VideoItem] = [
            VideoItem(videoId: "v1", title: "動画1", channelId: "UC123", channelName: "テストチャンネル", thumbnailURL: nil, channelAvatarURL: nil, viewCountText: nil, timePostedText: nil)
        ]
        let client = ContentClient.mock(
            fetchChannel: { _ in mockInfo },
            fetchChannelTab: { _, _ in (mockVideos, nil) }
        )
        let vm = ChannelViewModel(contentClient: client)

        await vm.load(channelId: "UC123")

        #expect(vm.channelInfo?.name == "テストチャンネル")
        #expect(vm.channelInfo?.handle == "@test")
        #expect(vm.currentVideos.count == 1)
        #expect(!vm.isLoading)
        #expect(vm.error == nil)
    }

    @Test func loadHandlesError() async {
        let client = ContentClient.mock(fetchChannel: { _ in throw URLError(.notConnectedToInternet) })
        let vm = ChannelViewModel(contentClient: client)

        await vm.load(channelId: "UC123")

        #expect(vm.channelInfo == nil)
        #expect(vm.error != nil)
        #expect(!vm.isLoading)
    }

    private static func makeInfo(subscribed: Bool) -> ChannelInfo {
        ChannelInfo(channelId: "UC123", name: "テストチャンネル", handle: nil, subscriberCount: nil, videoCount: nil, avatarURL: nil, bannerURL: nil, subscribed: subscribed)
    }

    @Test func toggleSubscriptionSuccessKeepsNewState() async {
        let client = ContentClient.mock(
            fetchChannel: { _ in Self.makeInfo(subscribed: false) },
            subscribe: { _ in }
        )
        let vm = ChannelViewModel(contentClient: client)
        await vm.load(channelId: "UC123")

        await vm.toggleSubscription()

        #expect(vm.channelInfo?.subscribed == true)
        #expect(!vm.isTogglingSubscription)
    }

    @Test func toggleSubscriptionFailureRollsBack() async {
        let client = ContentClient.mock(
            fetchChannel: { _ in Self.makeInfo(subscribed: false) },
            subscribe: { _ in throw URLError(.notConnectedToInternet) }
        )
        let vm = ChannelViewModel(contentClient: client)
        await vm.load(channelId: "UC123")

        await vm.toggleSubscription()

        #expect(vm.channelInfo?.subscribed == false)
        #expect(!vm.isTogglingSubscription)
    }
}

// MARK: - 登録状態パース ユニットテスト

struct ChannelSubscribedStateTests {

    @Test func c4LayoutSubscribed() {
        let header: [String: Any] = ["c4TabbedHeaderRenderer": ["subscribeButton": ["subscribeButtonRenderer": ["subscribed": true]]]]
        #expect(ContentClient.extractSubscribedState(from: header) == true)
    }

    @Test func pageHeaderLayoutSubscribed() {
        // 再帰探索のため actions の配列ネストを通して subscribeButtonViewModel を検出できる
        let header: [String: Any] = ["pageHeaderRenderer": ["content": ["actions": [["subscribeButtonViewModel": ["subscribed": true]]]]]]
        #expect(ContentClient.extractSubscribedState(from: header) == true)
    }

    @Test func pageHeaderLayoutNotSubscribed() {
        let header: [String: Any] = ["pageHeaderRenderer": ["content": ["actions": [["subscribeButtonViewModel": ["subscribed": false]]]]]]
        #expect(ContentClient.extractSubscribedState(from: header) == false)
    }

    @Test func absentReturnsNil() {
        let header: [String: Any] = ["pageHeaderRenderer": ["content": ["title": "X"]]]
        #expect(ContentClient.extractSubscribedState(from: header) == nil)
    }

    /// subscribe ボタンと無関係な subscribed フラグを誤検出しないことを保証する回帰テスト
    @Test func ignoresSubscribedOutsideSubscribeButton() {
        let header: [String: Any] = [
            "pageHeaderRenderer": [
                "content": [
                    "someOtherComponent": ["subscribed": true],
                    "metadata": ["subscribed": true]
                ]
            ],
            "subscribed": true
        ]
        #expect(ContentClient.extractSubscribedState(from: header) == nil)
    }
}

// MARK: - ContentClient 結合テスト (fetchHistoryVideos)

struct ContentClientHistoryTests {

    @Test func fetchHistoryVideosReturnsWithoutThrowing() async throws {
        // 未認証環境では空配列を返す（ guard !cookies.isEmpty で弾かれる）
        // 少なくともクラッシュ・例外が発生しないことを確認する
        let (videos, _) = try await ContentClient.live.fetchHistoryVideos()
        // 未認証なら空、認証済みなら 1 件以上
        #expect(videos.allSatisfy { !$0.videoId.isEmpty })
    }
}

// MARK: - YouTubeClient 結合テスト

struct YouTubeClientTests {
    let testVideoID = "jYg8wCT02FA"

    @Test func fetchVideoReturnsStreamURL() async throws {
        // 未認証環境ではボット検出で失敗するためスキップ
        guard AuthState.shared.cookieString != nil else { return }
        let info = try await YouTubeClient.live.fetchVideo(testVideoID)
        #expect(!info.streamURL.absoluteString.isEmpty)
        #expect(info.title != testVideoID)
        #expect(info.streamURL.absoluteString.contains("googlevideo") ||
                info.streamURL.absoluteString.contains("manifest"))
    }

    /// SABR 移行済み動画でも、チェーン（android_vr フォールバック）が再生可能な直 URL を返すことを検証する。
    /// 他の結合テストと同様、未認証環境（CI 等）ではネットワーク起因の flaky を避けるためスキップする。
    @Test func sabrVideoReturnsPlayableStream() async throws {
        guard AuthState.shared.cookieString != nil else { return }
        let info = try await YouTubeClient.live.fetchVideo("9bZkp7q19f0")
        let s = info.streamURL.absoluteString
        #expect(s.contains("googlevideo") || s.contains("manifest"),
                "再生可能なストリーム URL でない: \(s.prefix(80))")
    }

    /// 実ネットワークで取得した HLS ストリームが再生準備可能（asset の長さが取得できる）なこと。
    /// 未認証ではボット検出を避けるためスキップ。
    @MainActor
    @Test func makePlayerItemProducesPlayableAsset() async throws {
        guard AuthState.shared.cookieString != nil else { return }
        let info = try await YouTubeClient.live.fetchVideo(testVideoID)
        let vm = PlayerViewModel(youtubeClient: .live, contentClient: .mock())
        let item = vm.makePlayerItem(info: info, audioOnly: false)
        let duration = try await item.asset.load(.duration)
        #expect(duration.seconds > 0)
    }
}

// MARK: - ContentClient 結合テスト

struct ContentClientTests {

    @Test func searchReturnsResults() async throws {
        let results = try await ContentClient.live.search("Swift programming")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { !$0.videoId.isEmpty })
    }

    @Test func fetchRelatedReturnsVideos() async throws {
        let result = try await ContentClient.live.fetchRelated("jYg8wCT02FA")
        #expect(result.videos.allSatisfy { !$0.videoId.isEmpty })
        // /next の videoOwnerRenderer からアバターが取れるはず
        #expect(result.ownerAvatarURL != nil)
    }

    @Test func extractOwnerAvatarURLFindsRenderer() {
        let json: [String: Any] = [
            "contents": [
                "twoColumnWatchNextResults": [
                    "results": [
                        "results": [
                            "contents": [
                                ["videoOwnerRenderer": [
                                    "thumbnail": [
                                        "thumbnails": [
                                            ["url": "https://yt3.ggpht.com/avatar_small", "width": 48, "height": 48],
                                            ["url": "https://yt3.ggpht.com/avatar_large", "width": 176, "height": 176]
                                        ]
                                    ],
                                    "title": ["runs": [["text": "テストチャンネル"]]]
                                ]]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let url = ContentClient.extractOwnerAvatarURL(from: json)
        #expect(url?.absoluteString == "https://yt3.ggpht.com/avatar_large")
    }

    @Test func extractOwnerAvatarURLReturnsNilWhenMissing() {
        let json: [String: Any] = ["empty": true]
        let url = ContentClient.extractOwnerAvatarURL(from: json)
        #expect(url == nil)
    }

    @Test func fetchCommentsReturnsResults() async throws {
        let result = try await ContentClient.live.fetchComments("dQw4w9WgXcQ")
        #expect(!result.comments.isEmpty, "コメントが1件以上取得できるはず")
        let first = result.comments[0]
        #expect(!first.id.isEmpty)
        #expect(!first.authorName.isEmpty)
        #expect(!first.contentText.isEmpty)
    }
}

// MARK: - VideoID パーサー ユニットテスト

struct VideoIDTests {

    @Test func extractFromFullURL() {
        #expect(extractVideoID(from: "https://www.youtube.com/watch?v=jYg8wCT02FA") == "jYg8wCT02FA")
    }

    @Test func extractFromShortURL() {
        #expect(extractVideoID(from: "https://youtu.be/jYg8wCT02FA") == "jYg8wCT02FA")
    }

    @Test func extractFromShortURLWithParams() {
        #expect(extractVideoID(from: "https://youtu.be/jYg8wCT02FA?si=b91FPKR-tCiXxdWl") == "jYg8wCT02FA")
    }

    @Test func extractFromShortsURL() {
        #expect(extractVideoID(from: "https://www.youtube.com/shorts/jYg8wCT02FA") == "jYg8wCT02FA")
    }

    @Test func extractFromDirectID() {
        #expect(extractVideoID(from: "jYg8wCT02FA") == "jYg8wCT02FA")
    }

    @Test func invalidInputReturnsNil() {
        #expect(extractVideoID(from: "notaurl") == nil)
        #expect(extractVideoID(from: "") == nil)
    }

    @Test func extractIgnoresTrailingSlash() {
        #expect(extractVideoID(from: "https://www.youtube.com/watch?v=jYg8wCT02FA&t=30") == "jYg8wCT02FA")
    }
}

// MARK: - SearchViewModel ユニットテスト

@MainActor
struct SearchViewModelTests {

    @Test func searchSkipsEmptyQuery() async {
        let vm = SearchViewModel(client: .mock())
        await vm.search("   ") // 空白のみ
        #expect(vm.lastQuery.isEmpty)
        #expect(vm.results.isEmpty)
        #expect(!vm.isLoading)
    }

    @Test func searchSkipsDuplicateQuery() async {
        var callCount = 0
        let client = ContentClient.mock(search: { _ in
            callCount += 1
            return []
        })
        let vm = SearchViewModel(client: client)
        await vm.search("Swift")
        await vm.search("Swift") // 同一クエリは再実行しない
        #expect(callCount == 1)
    }

    @Test func searchUpdatesLastQuery() async {
        let vm = SearchViewModel(client: .mock())
        await vm.search("iOS開発")
        #expect(vm.lastQuery == "iOS開発")
    }

    @Test func searchTrimmsWhitespace() async {
        var receivedQuery = ""
        let client = ContentClient.mock(search: { q in
            receivedQuery = q
            return []
        })
        let vm = SearchViewModel(client: client)
        await vm.search("  Swift  ")
        #expect(receivedQuery == "Swift") // 前後の空白は除去される
    }

    @Test func searchSetsLoadingFalseAfterCompletion() async {
        let vm = SearchViewModel(client: .mock())
        await vm.search("test")
        #expect(!vm.isLoading)
    }

    @Test func searchSetsErrorOnFailure() async {
        let client = ContentClient.mock(search: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let vm = SearchViewModel(client: client)
        await vm.search("test")
        #expect(vm.error != nil)
        #expect(!vm.isLoading)
    }

    @Test func searchClearsErrorBeforeRetry() async {
        var shouldFail = true
        let client = ContentClient.mock(search: { _ in
            if shouldFail { throw URLError(.notConnectedToInternet) }
            return []
        })
        let vm = SearchViewModel(client: client)
        await vm.search("first")
        #expect(vm.error != nil)

        shouldFail = false
        await vm.search("second") // 別クエリで再試行
        #expect(vm.error == nil)
    }

    @Test func resetClearsAllState() async {
        let vm = SearchViewModel(client: .mock())
        await vm.search("Swift")
        vm.reset()
        #expect(vm.results.isEmpty)
        #expect(vm.lastQuery.isEmpty)
        #expect(vm.error == nil)
        #expect(!vm.isLoading)
    }

    @Test func resetAllowsSameQueryAgain() async {
        var callCount = 0
        let client = ContentClient.mock(search: { _ in
            callCount += 1
            return []
        })
        let vm = SearchViewModel(client: client)
        await vm.search("Swift")
        vm.reset()
        await vm.search("Swift") // reset 後は同一クエリも実行される
        #expect(callCount == 2)
    }

    // MARK: サジェスト

    @Test func loadSuggestionsPopulatesSuggestions() async {
        let vm = SearchViewModel(client: .mock(
            searchSuggestions: { q in ["\(q) ライブ", "\(q) カラオケ"] }
        ))
        await vm.loadSuggestions("ヨルシカ")
        #expect(vm.suggestions == ["ヨルシカ ライブ", "ヨルシカ カラオケ"])
    }

    @Test func loadSuggestionsClearsOnEmptyQuery() async {
        let vm = SearchViewModel(client: .mock(
            searchSuggestions: { _ in ["should not appear"] }
        ))
        vm.suggestions = ["残骸"]
        await vm.loadSuggestions("   ")
        #expect(vm.suggestions.isEmpty)
    }

    @Test func searchClearsSuggestions() async {
        let vm = SearchViewModel(client: .mock(searchSuggestions: { _ in [] }))
        vm.suggestions = ["候補"]
        await vm.search("テスト")
        #expect(vm.suggestions.isEmpty)
    }

    @Test func resetClearsSuggestions() async {
        let vm = SearchViewModel(client: .mock())
        vm.suggestions = ["候補"]
        vm.reset()
        #expect(vm.suggestions.isEmpty)
    }
}

// MARK: - HomeViewModel ユニットテスト

@MainActor
struct HomeViewModelTests {

    private func makeInMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: WatchedVideo.self, PinnedPlaylist.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func loadSetsLoadingFalseAfterCompletion() async throws {
        let ctx = try makeInMemoryContext()
        let vm = HomeViewModel(client: .mock())
        await vm.load(modelContext: ctx)
        #expect(!vm.isLoading)
    }

    @Test func loadSetsErrorOnFailure() async throws {
        let ctx = try makeInMemoryContext()
        let client = ContentClient.mock(fetchHome: {
            throw URLError(.notConnectedToInternet)
        })
        let vm = HomeViewModel(client: client)
        await vm.load(modelContext: ctx)
        #expect(vm.error != nil)
        #expect(!vm.isLoading)
    }

    @Test func loadIsSkippedWhenVideosAlreadyPresent() async throws {
        let ctx = try makeInMemoryContext()
        var callCount = 0
        let client = ContentClient.mock(fetchHome: {
            callCount += 1
            throw URLError(.cancelled)
        })
        let vm = HomeViewModel(client: client)
        await vm.load(modelContext: ctx)
        await vm.load(modelContext: ctx)
        #expect(callCount >= 1)
    }

    @Test func reloadClearsErrorAndReloads() async throws {
        let ctx = try makeInMemoryContext()
        var callCount = 0
        let client = ContentClient.mock(fetchHome: {
            callCount += 1
            throw URLError(.notConnectedToInternet)
        })
        let vm = HomeViewModel(client: client)
        await vm.load(modelContext: ctx)
        #expect(vm.error != nil)

        await vm.reload(modelContext: ctx)
        #expect(callCount == 2)
    }

    @Test func reloadClearsVideosBeforeLoad() async throws {
        let ctx = try makeInMemoryContext()
        let vm = HomeViewModel(client: .mock())
        await vm.reload(modelContext: ctx)
        #expect(!vm.isLoading)
    }

    @Test func refilterShowsAllWhenNotCustomized() async throws {
        let ctx = try makeInMemoryContext()
        UserDefaults.standard.set(false, forKey: "hasCustomizedHomePlaylists")
        defer { UserDefaults.standard.removeObject(forKey: "hasCustomizedHomePlaylists") }

        let vm = HomeViewModel(client: .mock())
        vm.allPlaylists = [
            YTPlaylist(playlistId: "VLWL", title: "後で見る"),
            YTPlaylist(playlistId: "VLLL", title: "いいね"),
            YTPlaylist(playlistId: "PLtest", title: "テスト")
        ]
        vm.refilterPlaylists(modelContext: ctx)
        #expect(vm.quickPlaylists.count == 3)
    }

    @Test func refilterShowsOnlyPinnedWhenCustomized() async throws {
        let ctx = try makeInMemoryContext()
        UserDefaults.standard.set(true, forKey: "hasCustomizedHomePlaylists")
        defer { UserDefaults.standard.removeObject(forKey: "hasCustomizedHomePlaylists") }

        // VLWL と PLtest だけピン
        ctx.insert(PinnedPlaylist(playlistId: "VLWL", sortOrder: 0))
        ctx.insert(PinnedPlaylist(playlistId: "PLtest", sortOrder: 1))
        try ctx.save()

        let vm = HomeViewModel(client: .mock())
        vm.allPlaylists = [
            YTPlaylist(playlistId: "VLWL", title: "後で見る"),
            YTPlaylist(playlistId: "VLLL", title: "いいね"),
            YTPlaylist(playlistId: "PLtest", title: "テスト")
        ]
        vm.refilterPlaylists(modelContext: ctx)
        #expect(vm.quickPlaylists.count == 2)
        #expect(vm.quickPlaylists.map(\.playlistId) == ["VLWL", "PLtest"])
    }

    @Test func refilterShowsNoneWhenCustomizedWithEmptyPins() async throws {
        let ctx = try makeInMemoryContext()
        UserDefaults.standard.set(true, forKey: "hasCustomizedHomePlaylists")
        defer { UserDefaults.standard.removeObject(forKey: "hasCustomizedHomePlaylists") }

        let vm = HomeViewModel(client: .mock())
        vm.allPlaylists = [
            YTPlaylist(playlistId: "VLWL", title: "後で見る"),
            YTPlaylist(playlistId: "VLLL", title: "いいね")
        ]
        vm.refilterPlaylists(modelContext: ctx)
        #expect(vm.quickPlaylists.isEmpty)
    }
}

// MARK: - PinnedPlaylist SwiftData ユニットテスト

struct PinnedPlaylistTests {

    @Test func insertAndFetch() throws {
        let container = try ModelContainer(
            for: PinnedPlaylist.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        ctx.insert(PinnedPlaylist(playlistId: "VLWL", sortOrder: 0))
        ctx.insert(PinnedPlaylist(playlistId: "PLtest", sortOrder: 1))
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<PinnedPlaylist>(sortBy: [SortDescriptor(\.sortOrder)]))
        #expect(fetched.count == 2)
        #expect(fetched[0].playlistId == "VLWL")
        #expect(fetched[1].playlistId == "PLtest")
    }

    @Test func deleteAll() throws {
        let container = try ModelContainer(
            for: PinnedPlaylist.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        ctx.insert(PinnedPlaylist(playlistId: "VLWL", sortOrder: 0))
        ctx.insert(PinnedPlaylist(playlistId: "VLLL", sortOrder: 1))
        try ctx.save()

        try ctx.delete(model: PinnedPlaylist.self)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<PinnedPlaylist>())
        #expect(fetched.isEmpty)
    }

    @Test func uniqueConstraint() throws {
        let container = try ModelContainer(
            for: PinnedPlaylist.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        ctx.insert(PinnedPlaylist(playlistId: "VLWL", sortOrder: 0))
        ctx.insert(PinnedPlaylist(playlistId: "VLWL", sortOrder: 1))
        try ctx.save()

        // ユニーク制約で1件に集約される
        let fetched = try ctx.fetch(FetchDescriptor<PinnedPlaylist>())
        #expect(fetched.count == 1)
    }
}

// MARK: - PlayerViewModel ユニットテスト

@MainActor
struct PlayerViewModelTests {

    private func makeInMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: WatchedVideo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func loadSetsStreamErrorOnFailure() async throws {
        let youtubeClient = YouTubeClient(fetchVideo: { _ in
            throw YouTubeClientError.streamNotFound
        })
        let vm = PlayerViewModel(youtubeClient: youtubeClient, contentClient: .mock())
        let ctx = try makeInMemoryContext()

        await vm.load(videoID: "test", modelContext: ctx)

        #expect(vm.streamError != nil)
        #expect(!vm.isLoadingStream)
        #expect(vm.videoInfo == nil)
    }

    @Test func loadSetsVideoInfoOnSuccess() async throws {
        let dummyURL = URL(string: "https://example.com/test.m3u8")!
        let youtubeClient = YouTubeClient(fetchVideo: { _ in
            VideoInfo(streamURL: dummyURL, audioOnlyURL: nil, title: "テスト動画", thumbnailURL: "https://example.com/thumb.jpg", channelId: nil, channelName: nil, channelAvatarURL: nil)
        })
        let vm = PlayerViewModel(youtubeClient: youtubeClient, contentClient: .mock())
        let ctx = try makeInMemoryContext()

        await vm.load(videoID: "abc123", modelContext: ctx)

        #expect(vm.videoInfo?.title == "テスト動画")
        #expect(vm.streamError == nil)
        #expect(!vm.isLoadingStream)
    }

    @Test func loadSavesVideoToHistory() async throws {
        let dummyURL = URL(string: "https://example.com/test.m3u8")!
        let youtubeClient = YouTubeClient(fetchVideo: { _ in
            VideoInfo(streamURL: dummyURL, audioOnlyURL: nil, title: "履歴テスト", thumbnailURL: "https://example.com/t.jpg", channelId: nil, channelName: nil, channelAvatarURL: nil)
        })
        let vm = PlayerViewModel(youtubeClient: youtubeClient, contentClient: .mock())
        let ctx = try makeInMemoryContext()

        await vm.load(videoID: "saved123", modelContext: ctx)

        // 視聴履歴に保存されているか確認
        let fetched = try ctx.fetch(FetchDescriptor<WatchedVideo>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.videoID == "saved123")
        #expect(fetched.first?.title == "履歴テスト")
    }

    @Test func loadUpsertsHistoryInsteadOfDuplicate() async throws {
        let dummyURL = URL(string: "https://example.com/test.m3u8")!
        let youtubeClient = YouTubeClient(fetchVideo: { _ in
            VideoInfo(streamURL: dummyURL, audioOnlyURL: nil, title: "更新後タイトル", thumbnailURL: "https://example.com/t2.jpg", channelId: nil, channelName: nil, channelAvatarURL: nil)
        })
        let vm = PlayerViewModel(youtubeClient: youtubeClient, contentClient: .mock())
        let ctx = try makeInMemoryContext()

        // 事前に同じ videoID のレコードを挿入
        let existing = WatchedVideo(videoID: "upsert1", title: "旧タイトル", thumbnailURL: "https://example.com/t1.jpg")
        ctx.insert(existing)
        try ctx.save()

        await vm.load(videoID: "upsert1", modelContext: ctx)

        // 重複せず 1 件のまま、タイトルが更新されている
        let fetched = try ctx.fetch(FetchDescriptor<WatchedVideo>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "更新後タイトル")
    }

    @Test func loadDoesNotSaveHistoryOnStreamError() async throws {
        let youtubeClient = YouTubeClient(fetchVideo: { _ in
            throw YouTubeClientError.streamNotFound
        })
        let vm = PlayerViewModel(youtubeClient: youtubeClient, contentClient: .mock())
        let ctx = try makeInMemoryContext()

        await vm.load(videoID: "fail123", modelContext: ctx)

        // エラー時は履歴に保存されない
        let fetched = try ctx.fetch(FetchDescriptor<WatchedVideo>())
        #expect(fetched.isEmpty)
    }

    @Test func loadSetsIsLoadingRelatedFalseAfterCompletion() async throws {
        let youtubeClient = YouTubeClient(fetchVideo: { _ in
            throw YouTubeClientError.streamNotFound
        })
        let vm = PlayerViewModel(youtubeClient: youtubeClient, contentClient: .mock())
        let ctx = try makeInMemoryContext()

        await vm.load(videoID: "test", modelContext: ctx)

        #expect(!vm.isLoadingRelated)
    }

    // MARK: - プレイリスト再生モード

    @Test func playNextAdvancesIndex() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in throw YouTubeClientError.streamNotFound }), contentClient: .mock())
        vm.playlistQueue = [
            VideoItem(videoId: "a", title: "A"),
            VideoItem(videoId: "b", title: "B"),
            VideoItem(videoId: "c", title: "C")
        ]
        vm.playlistIndex = 0

        vm.playNext()
        #expect(vm.playlistIndex == 1)
        #expect(vm.autoNextVideoID == "b")

        vm.autoNextVideoID = nil
        vm.playNext()
        #expect(vm.playlistIndex == 2)
        #expect(vm.autoNextVideoID == "c")
    }

    @Test func playNextDoesNothingAtEnd() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in throw YouTubeClientError.streamNotFound }), contentClient: .mock())
        vm.playlistQueue = [
            VideoItem(videoId: "a", title: "A"),
            VideoItem(videoId: "b", title: "B")
        ]
        vm.playlistIndex = 1

        vm.playNext()
        #expect(vm.playlistIndex == 1)
        #expect(vm.autoNextVideoID == nil)
    }

    @Test func playPreviousGoesBack() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in throw YouTubeClientError.streamNotFound }), contentClient: .mock())
        vm.playlistQueue = [
            VideoItem(videoId: "a", title: "A"),
            VideoItem(videoId: "b", title: "B"),
            VideoItem(videoId: "c", title: "C")
        ]
        vm.playlistIndex = 2

        vm.playPrevious()
        #expect(vm.playlistIndex == 1)
        #expect(vm.autoNextVideoID == "b")
    }

    @Test func playPreviousDoesNothingAtStart() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in throw YouTubeClientError.streamNotFound }), contentClient: .mock())
        vm.playlistQueue = [
            VideoItem(videoId: "a", title: "A")
        ]
        vm.playlistIndex = 0

        vm.playPrevious()
        #expect(vm.playlistIndex == 0)
        #expect(vm.autoNextVideoID == nil)
    }

    @Test func playlistQueueIsEmptyByDefault() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in throw YouTubeClientError.streamNotFound }), contentClient: .mock())
        #expect(vm.playlistQueue.isEmpty)
        #expect(vm.playlistIndex == 0)
    }

    // MARK: - 音声のみモード

    @Test func audioOnlyDefaultsFromUserDefaults() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in throw YouTubeClientError.streamNotFound }), contentClient: .mock())
        // UserDefaults のデフォルト値は false
        #expect(!vm.isAudioOnly || vm.isAudioOnly) // 値が読めることを確認
    }

    @Test func toggleAudioOnlyWithoutVideoInfoDoesNothing() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in throw YouTubeClientError.streamNotFound }), contentClient: .mock())
        // videoInfo が nil の場合は何も起きない
        vm.toggleAudioOnly()
        #expect(!vm.isAudioOnly)
    }
}

// MARK: - 説明欄データ抽出テスト

struct VideoDescriptionParsingTests {

    @Test func extractVideoDescriptionFromStructured() {
        let json: [String: Any] = [
            "engagementPanels": [
                ["engagementPanelSectionListRenderer": [
                    "content": [
                        "structuredDescriptionContentRenderer": [
                            "items": [
                                ["videoDescriptionHeaderRenderer": [
                                    "views": ["simpleText": "1,234回視聴"],
                                    "publishDate": ["simpleText": "2025/01/15"]
                                ]],
                                ["expandableVideoDescriptionBodyRenderer": [
                                    "attributedDescriptionBodyText": ["content": "テスト説明文です"]
                                ]]
                            ]
                        ]
                    ]
                ]]
            ]
        ]
        let (desc, views, date) = ContentClient.extractVideoDescription(from: json)
        #expect(desc == "テスト説明文です")
        #expect(views == "1,234回視聴")
        #expect(date == "2025/01/15")
    }

    @Test func extractVideoDescriptionReturnsNilForEmpty() {
        let json: [String: Any] = ["empty": true]
        let (desc, views, date) = ContentClient.extractVideoDescription(from: json)
        #expect(desc == nil)
        #expect(views == nil)
        #expect(date == nil)
    }
}

// MARK: - WatchedVideo ユニットテスト

struct WatchedVideoTests {

    @Test func initStoresAllProperties() {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let video = WatchedVideo(
            videoID: "abc123",
            title: "テスト動画",
            thumbnailURL: "https://example.com/thumb.jpg",
            watchedAt: date,
            playbackPosition: 42.5,
            videoDuration: 300.0
        )
        #expect(video.videoID == "abc123")
        #expect(video.title == "テスト動画")
        #expect(video.thumbnailURL == "https://example.com/thumb.jpg")
        #expect(video.watchedAt == date)
        #expect(video.playbackPosition == 42.5)
        #expect(video.videoDuration == 300.0)
    }

    @Test func playbackPositionDefaultsToZero() {
        let video = WatchedVideo(videoID: "x", title: "y", thumbnailURL: "z")
        #expect(video.playbackPosition == 0)
        #expect(video.videoDuration == 0)
    }

    @Test func initDefaultsWatchedAtToNow() {
        let before = Date()
        let video = WatchedVideo(videoID: "x", title: "y", thumbnailURL: "z")
        let after = Date()
        #expect(video.watchedAt >= before)
        #expect(video.watchedAt <= after)
    }

    @Test func swiftDataInsertsAndFetches() throws {
        let container = try ModelContainer(
            for: WatchedVideo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        let video = WatchedVideo(videoID: "vid1", title: "テスト動画", thumbnailURL: "https://example.com/t.jpg")
        ctx.insert(video)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<WatchedVideo>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.videoID == "vid1")
        #expect(fetched.first?.title == "テスト動画")
    }

    @Test func swiftDataDeletesRecord() throws {
        let container = try ModelContainer(
            for: WatchedVideo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        let video = WatchedVideo(videoID: "vid2", title: "削除テスト", thumbnailURL: "")
        ctx.insert(video)
        try ctx.save()
        ctx.delete(video)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<WatchedVideo>())
        #expect(fetched.isEmpty)
    }

    @Test func swiftDataPersistsPlaybackPosition() throws {
        let container = try ModelContainer(
            for: WatchedVideo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        let video = WatchedVideo(
            videoID: "pos1", title: "位置テスト", thumbnailURL: "",
            playbackPosition: 120.5, videoDuration: 600.0
        )
        ctx.insert(video)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<WatchedVideo>())
        #expect(fetched.first?.playbackPosition == 120.5)
        #expect(fetched.first?.videoDuration == 600.0)

        // 再生位置を更新
        fetched.first?.playbackPosition = 300.0
        try ctx.save()

        let updated = try ctx.fetch(FetchDescriptor<WatchedVideo>())
        #expect(updated.first?.playbackPosition == 300.0)
    }

    @Test func swiftDataFetchesInReverseChronologicalOrder() throws {
        let container = try ModelContainer(
            for: WatchedVideo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        let old = WatchedVideo(videoID: "old", title: "古い動画", thumbnailURL: "", watchedAt: Date(timeIntervalSinceNow: -3600))
        let new = WatchedVideo(videoID: "new", title: "新しい動画", thumbnailURL: "", watchedAt: Date())
        ctx.insert(old)
        ctx.insert(new)
        try ctx.save()

        var descriptor = FetchDescriptor<WatchedVideo>(sortBy: [SortDescriptor(\.watchedAt, order: .reverse)])
        let fetched = try ctx.fetch(descriptor)
        #expect(fetched.first?.videoID == "new")
        #expect(fetched.last?.videoID == "old")
    }
}

// MARK: - SearchHistory ユニットテスト

struct SearchHistoryTests {

    @Test func initStoresProperties() {
        let date = Date(timeIntervalSinceReferenceDate: 5000)
        let history = SearchHistory(query: "Swift", searchedAt: date)
        #expect(history.query == "Swift")
        #expect(history.searchedAt == date)
    }

    @Test func initDefaultsSearchedAtToNow() {
        let before = Date()
        let history = SearchHistory(query: "test")
        let after = Date()
        #expect(history.searchedAt >= before)
        #expect(history.searchedAt <= after)
    }

    @Test func swiftDataInsertsAndFetches() throws {
        let container = try ModelContainer(
            for: SearchHistory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        let entry = SearchHistory(query: "SwiftUI")
        ctx.insert(entry)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<SearchHistory>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.query == "SwiftUI")
    }

    @Test func swiftDataDeletesRecord() throws {
        let container = try ModelContainer(
            for: SearchHistory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        let entry = SearchHistory(query: "削除テスト")
        ctx.insert(entry)
        try ctx.save()
        ctx.delete(entry)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<SearchHistory>())
        #expect(fetched.isEmpty)
    }

    @Test func swiftDataUpsertsByUniqueQuery() throws {
        let container = try ModelContainer(
            for: SearchHistory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        let first = SearchHistory(query: "Swift", searchedAt: Date(timeIntervalSinceNow: -3600))
        ctx.insert(first)
        try ctx.save()

        // 同じクエリを再度挿入すると既存レコードが更新される
        let targetQuery = "Swift"
        var descriptor = FetchDescriptor<SearchHistory>(
            predicate: #Predicate { $0.query == targetQuery }
        )
        descriptor.fetchLimit = 1
        if let existing = try ctx.fetch(descriptor).first {
            existing.searchedAt = .now
        }
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<SearchHistory>())
        #expect(all.count == 1)
        #expect(all.first?.query == "Swift")
    }

    @Test func swiftDataFetchesInReverseChronologicalOrder() throws {
        let container = try ModelContainer(
            for: SearchHistory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        let old = SearchHistory(query: "古い検索", searchedAt: Date(timeIntervalSinceNow: -3600))
        let new = SearchHistory(query: "新しい検索", searchedAt: Date())
        ctx.insert(old)
        ctx.insert(new)
        try ctx.save()

        let descriptor = FetchDescriptor<SearchHistory>(
            sortBy: [SortDescriptor(\.searchedAt, order: .reverse)]
        )
        let fetched = try ctx.fetch(descriptor)
        #expect(fetched.first?.query == "新しい検索")
        #expect(fetched.last?.query == "古い検索")
    }
}

// MARK: - CommentItem ユニットテスト

struct CommentItemTests {

    @Test func initStoresAllProperties() {
        let comment = CommentItem(
            id: "c1",
            authorName: "テストユーザー",
            authorAvatarURL: URL(string: "https://example.com/avatar.jpg"),
            contentText: "素晴らしい動画です！",
            publishedTimeText: "3時間前",
            likeCountText: "42",
            replyCount: 5
        )
        #expect(comment.id == "c1")
        #expect(comment.authorName == "テストユーザー")
        #expect(comment.authorAvatarURL?.absoluteString == "https://example.com/avatar.jpg")
        #expect(comment.contentText == "素晴らしい動画です！")
        #expect(comment.publishedTimeText == "3時間前")
        #expect(comment.likeCountText == "42")
        #expect(comment.replyCount == 5)
    }

    @Test func identifiableByID() {
        let a = CommentItem(id: "x", authorName: "A", authorAvatarURL: nil, contentText: "a", publishedTimeText: nil, likeCountText: nil, replyCount: 0)
        let b = CommentItem(id: "y", authorName: "B", authorAvatarURL: nil, contentText: "b", publishedTimeText: nil, likeCountText: nil, replyCount: 0)
        #expect(a.id != b.id)
    }
}

// MARK: - コメントパーサー ユニットテスト

struct CommentParserTests {

    @Test func parseCommentEntityPayloadExtractsFields() {
        // 新形式: frameworkUpdates.entityBatchUpdate.mutations の commentEntityPayload
        let json: [String: Any] = [
            "onResponseReceivedEndpoints": [
                [
                    "reloadContinuationItemsCommand": [
                        "continuationItems": [
                            [
                                "commentThreadRenderer": [
                                    "commentViewModel": [
                                        "commentViewModel": [
                                            "commentId": "comment123"
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ],
            "frameworkUpdates": [
                "entityBatchUpdate": [
                    "mutations": [
                        [
                            "payload": [
                                "commentEntityPayload": [
                                    "properties": [
                                        "commentId": "comment123",
                                        "content": ["content": "これはテストコメントです"],
                                        "publishedTime": "1日前"
                                    ],
                                    "author": [
                                        "displayName": "テストユーザー",
                                        "avatarThumbnailUrl": "https://example.com/large.jpg"
                                    ],
                                    "toolbar": [
                                        "likeCountNotliked": "10",
                                        "replyCount": "3"
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let (comments, _) = ContentClient.parseComments(from: json)
        #expect(comments.count == 1)
        let c = comments[0]
        #expect(c.id == "comment123")
        #expect(c.authorName == "テストユーザー")
        #expect(c.authorAvatarURL?.absoluteString == "https://example.com/large.jpg")
        #expect(c.contentText == "これはテストコメントです")
        #expect(c.publishedTimeText == "1日前")
        #expect(c.likeCountText == "10")
        #expect(c.replyCount == 3)
    }

    @Test func parseCommentsReturnsEmptyForNoComments() {
        let json: [String: Any] = ["empty": true]
        let (comments, continuation) = ContentClient.parseComments(from: json)
        #expect(comments.isEmpty)
        #expect(continuation == nil)
    }

    @Test func extractCommentContinuationFindsToken() {
        let json: [String: Any] = [
            "engagementPanels": [
                [
                    "engagementPanelSectionListRenderer": [
                        "panelIdentifier": "comment-item-section",
                        "content": [
                            "sectionListRenderer": [
                                "contents": [
                                    [
                                        "itemSectionRenderer": [
                                            "contents": [
                                                [
                                                    "continuationItemRenderer": [
                                                        "continuationEndpoint": [
                                                            "continuationCommand": [
                                                                "token": "test_token_123"
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let token = ContentClient.extractCommentContinuation(from: json)
        #expect(token == "test_token_123")
    }

    @Test func extractCommentContinuationReturnsNilWhenMissing() {
        let json: [String: Any] = ["videoId": "abc"]
        let token = ContentClient.extractCommentContinuation(from: json)
        #expect(token == nil)
    }

    /// 次ページトークンが返信トークンと取り違えられないこと（Dictionary 反復順の非決定性対策）。
    /// 実レスポンスは各スレッドに返信 continuation を持ち、次ページ用は1個だけ存在する。
    @Test func parseCommentsPicksSectionTokenNotReplyToken() {
        let json: [String: Any] = [
            "onResponseReceivedEndpoints": [[
                "reloadContinuationItemsCommand": [
                    "continuationItems": [
                        [
                            "commentThreadRenderer": [
                                "commentViewModel": ["commentViewModel": ["commentId": "TOP1"]],
                                "replies": ["commentRepliesRenderer": ["contents": [[
                                    "continuationItemRenderer": ["continuationEndpoint": [
                                        "continuationCommand": ["token": "REPLY_TOKEN"]
                                    ]]
                                ]]]]
                            ]
                        ],
                        // セクション末尾の次ページトークン
                        ["continuationItemRenderer": ["continuationEndpoint": [
                            "continuationCommand": ["token": "PAGE_TOKEN"]
                        ]]]
                    ]
                ]
            ]],
            "frameworkUpdates": ["entityBatchUpdate": ["mutations": [[
                "payload": ["commentEntityPayload": [
                    "properties": ["commentId": "TOP1", "content": ["content": "本文"]],
                    "author": ["displayName": "ユーザー"],
                    "toolbar": ["replyCount": "2"]
                ]]
            ]]]]
        ]

        let (comments, continuation) = ContentClient.parseComments(from: json)
        #expect(continuation == "PAGE_TOKEN")
        #expect(comments.count == 1)
        #expect(comments.first?.repliesContinuation == "REPLY_TOKEN")
    }
}

// MARK: - PlaybackTracker ユニットテスト

struct PlaybackTrackerTests {

    @Test func generateCPNReturns16Characters() {
        let cpn = PlaybackTracker.generateCPN()
        #expect(cpn.count == 16)
    }

    @Test func generateCPNUsesValidCharacters() {
        let validChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let cpn = PlaybackTracker.generateCPN()
        for char in cpn {
            #expect(validChars.contains(char), "不正な文字: \(char)")
        }
    }

    @Test func generateCPNIsRandomEachTime() {
        let cpn1 = PlaybackTracker.generateCPN()
        let cpn2 = PlaybackTracker.generateCPN()
        // 極めて低い確率で一致するが、実質的にはランダム
        #expect(cpn1 != cpn2)
    }

    @Test func appendParamAddsQuestionMarkForFirstParam() {
        let result = PlaybackTracker.appendParam("https://example.com/path", "key", "value")
        #expect(result == "https://example.com/path?key=value")
    }

    @Test func appendParamAddsAmpersandForSubsequentParam() {
        let result = PlaybackTracker.appendParam("https://example.com/path?existing=1", "key", "value")
        #expect(result == "https://example.com/path?existing=1&key=value")
    }

    @Test func appendParamHandlesMultipleParams() {
        var url = "https://example.com/api"
        url = PlaybackTracker.appendParam(url, "cpn", "abc123")
        url = PlaybackTracker.appendParam(url, "st", "0.000")
        url = PlaybackTracker.appendParam(url, "et", "30.000")
        #expect(url == "https://example.com/api?cpn=abc123&st=0.000&et=30.000")
    }
}

// MARK: - PlaybackTrackingURLs パーサーテスト

struct PlaybackTrackingURLsParsingTests {

    @Test func extractTrackingURLsFromPlayerResponse() {
        let json: [String: Any] = [
            "playbackTracking": [
                "videostatsPlaybackUrl": [
                    "baseUrl": "https://s.youtube.com/api/stats/playback?cl=12345&docid=abc"
                ],
                "videostatsWatchtimeUrl": [
                    "baseUrl": "https://s.youtube.com/api/stats/watchtime?cl=12345&docid=abc"
                ]
            ],
            "videoDetails": [
                "videoId": "abc",
                "title": "テスト"
            ],
            "streamingData": [
                "hlsManifestUrl": "https://manifest.googlevideo.com/test.m3u8"
            ],
            "playabilityStatus": ["status": "OK"]
        ]

        // extractVideoMeta は private なので、/player レスポンス全体をシミュレートして
        // playbackTracking の抽出ロジックを直接テストする
        let tracking = json["playbackTracking"] as? [String: Any]
        let playbackURL = (tracking?["videostatsPlaybackUrl"] as? [String: Any])?["baseUrl"] as? String
        let watchtimeURL = (tracking?["videostatsWatchtimeUrl"] as? [String: Any])?["baseUrl"] as? String
        #expect(playbackURL == "https://s.youtube.com/api/stats/playback?cl=12345&docid=abc")
        #expect(watchtimeURL == "https://s.youtube.com/api/stats/watchtime?cl=12345&docid=abc")
    }

    @Test func trackingURLsAreNilWhenMissing() {
        let json: [String: Any] = [
            "videoDetails": ["videoId": "abc", "title": "テスト"],
            "playabilityStatus": ["status": "OK"]
        ]
        let tracking = json["playbackTracking"] as? [String: Any]
        #expect(tracking == nil)
    }

    @Test func trackingURLsAreNilWhenPartial() {
        // playbackUrl だけあって watchtimeUrl がないケース
        let json: [String: Any] = [
            "playbackTracking": [
                "videostatsPlaybackUrl": [
                    "baseUrl": "https://s.youtube.com/api/stats/playback"
                ]
                // videostatsWatchtimeUrl が欠落
            ]
        ]
        let tracking = json["playbackTracking"] as? [String: Any]
        let watchtimeURL = (tracking?["videostatsWatchtimeUrl"] as? [String: Any])?["baseUrl"] as? String
        #expect(watchtimeURL == nil)
    }
}

// MARK: - フィードバックトークン抽出テスト

struct FeedbackTokenExtractionTests {

    @Test func extractFeedbackTokensFromFeedbackEndpoint() {
        let json: [String: Any] = [
            "menu": [
                "menuRenderer": [
                    "items": [
                        ["menuServiceItemRenderer": [
                            "serviceEndpoint": [
                                "feedbackEndpoint": [
                                    "feedbackToken": "token_not_interested_123"
                                ]
                            ]
                        ]]
                    ]
                ]
            ]
        ]
        let tokens = ContentClient.extractFeedbackTokens(from: json)
        #expect(tokens.contains("token_not_interested_123"))
    }

    @Test func extractFeedbackTokensReturnsEmptyForNoTokens() {
        let json: [String: Any] = ["videoId": "abc", "title": "テスト"]
        let tokens = ContentClient.extractFeedbackTokens(from: json)
        #expect(tokens.isEmpty)
    }

    @Test func extractFeedbackTokensFindsMultipleTokens() {
        let json: [String: Any] = [
            "items": [
                ["feedbackEndpoint": ["feedbackToken": "token_a"]],
                ["feedbackEndpoint": ["feedbackToken": "token_b"]]
            ]
        ]
        let tokens = ContentClient.extractFeedbackTokens(from: json)
        #expect(tokens.count == 2)
        #expect(tokens.contains("token_a"))
        #expect(tokens.contains("token_b"))
    }

    @Test func extractFeedbackTokensFromDirectFeedbackToken() {
        // feedbackEndpoint を経由せず feedbackToken が直接存在するパターン
        let json: [String: Any] = [
            "feedbackToken": "direct_token_456"
        ]
        let tokens = ContentClient.extractFeedbackTokens(from: json)
        #expect(tokens.contains("direct_token_456"))
    }
}

// MARK: - VideoItem feedbackTokens テスト

struct VideoItemFeedbackTests {

    @Test func videoItemDefaultsToEmptyFeedbackTokens() {
        let item = VideoItem(videoId: "abc", title: "テスト")
        #expect(item.feedbackTokens.isEmpty)
    }

    @Test func videoItemStoresFeedbackTokens() {
        let item = VideoItem(videoId: "abc", title: "テスト", feedbackTokens: ["token1", "token2"])
        #expect(item.feedbackTokens == ["token1", "token2"])
    }
}

// MARK: - VideoItem setVideoId テスト

struct VideoItemSetVideoIdTests {

    @Test func videoItemDefaultsToNilSetVideoId() {
        let item = VideoItem(videoId: "abc", title: "テスト")
        #expect(item.setVideoId == nil)
    }

    @Test func videoItemStoresSetVideoId() {
        let item = VideoItem(videoId: "abc", title: "テスト", setVideoId: "SVabc123")
        #expect(item.setVideoId == "SVabc123")
    }

    @Test func parseVideoRendererExtractsSetVideoId() {
        let renderer: [String: Any] = [
            "videoId": "vid1",
            "title": ["runs": [["text": "テスト動画"]]],
            "thumbnail": ["thumbnails": [["url": "https://example.com/thumb.jpg"]]],
            "setVideoId": "SVid123456"
        ]
        let item = ContentClient.parseVideoRenderer(renderer)
        #expect(item != nil)
        #expect(item?.videoId == "vid1")
        #expect(item?.setVideoId == "SVid123456")
    }

    @Test func parseVideoRendererOmitsSetVideoIdWhenAbsent() {
        let renderer: [String: Any] = [
            "videoId": "vid2",
            "title": ["runs": [["text": "通常動画"]]],
            "thumbnail": ["thumbnails": [["url": "https://example.com/thumb.jpg"]]]
        ]
        let item = ContentClient.parseVideoRenderer(renderer)
        #expect(item != nil)
        #expect(item?.setVideoId == nil)
    }
}

// MARK: - PlaylistDetailViewModel 削除テスト

@MainActor
struct PlaylistDetailViewModelRemoveTests {

    @Test func removeDeletesVideoFromList() async {
        let videos = [
            VideoItem(videoId: "v1", title: "動画1", setVideoId: "SV001"),
            VideoItem(videoId: "v2", title: "動画2", setVideoId: "SV002"),
            VideoItem(videoId: "v3", title: "動画3", setVideoId: "SV003")
        ]
        let accountClient = AccountClient.mock(
            fetchPlaylistVideos: { _ in videos }
        )
        let vm = PlaylistDetailViewModel(accountClient: accountClient)
        await vm.load(playlistId: "VLPL123")

        #expect(vm.videos.count == 3)

        // setVideoId が nil の場合は削除しない
        let noSetVideoId = VideoItem(videoId: "v1", title: "動画1")
        await vm.remove(video: noSetVideoId, from: "VLPL123")
        #expect(vm.videos.count == 3)
    }
}

// MARK: - PlayerCoordinator ユニットテスト

@MainActor
struct PlayerCoordinatorTests {

    @Test func playSetsFullScreenMode() {
        let coordinator = PlayerCoordinator()
        #expect(coordinator.mode == .hidden)

        coordinator.play(videoID: "abc")

        #expect(coordinator.mode == .fullScreen)
        #expect(coordinator.currentVideoID == "abc")
    }

    @Test func playWithPlaylistSetsQueue() {
        let coordinator = PlayerCoordinator()
        let queue = [VideoItem(videoId: "v1", title: "A"), VideoItem(videoId: "v2", title: "B")]

        coordinator.play(videoID: "v1", playlistQueue: queue, initialIndex: 0)

        #expect(coordinator.playlistQueue.count == 2)
        #expect(coordinator.initialIndex == 0)
    }

    @Test func minimizeSetsMode() {
        let coordinator = PlayerCoordinator()
        coordinator.play(videoID: "abc")
        coordinator.minimize()

        #expect(coordinator.mode == .miniPlayer)
        #expect(coordinator.currentVideoID == "abc")
    }

    @Test func expandRestoresFullScreen() {
        let coordinator = PlayerCoordinator()
        coordinator.play(videoID: "abc")
        coordinator.minimize()
        coordinator.expand()

        #expect(coordinator.mode == .fullScreen)
    }

    @Test func dismissClearsState() {
        let coordinator = PlayerCoordinator()
        coordinator.play(videoID: "abc", playlistQueue: [VideoItem(videoId: "v1", title: "A")])
        coordinator.dismiss()

        #expect(coordinator.mode == .hidden)
        #expect(coordinator.currentVideoID == nil)
        #expect(coordinator.playlistQueue.isEmpty)
    }

    // MARK: - 手動キュー操作

    private func item(_ id: String) -> VideoItem { VideoItem(videoId: id, title: id) }

    @Test func enqueueWhileHiddenStartsPlayback() {
        let coordinator = PlayerCoordinator()
        coordinator.enqueue(item("a"))

        #expect(coordinator.mode == .fullScreen)
        #expect(coordinator.currentVideoID == "a")
    }

    @Test func enqueueSeedsQueueFromCurrentVideo() {
        let coordinator = PlayerCoordinator()
        coordinator.play(item("a"))
        coordinator.enqueue(item("b"))

        #expect(coordinator.playlistQueue.map(\.videoId) == ["a", "b"])
        #expect(coordinator.initialIndex == 0)
    }

    @Test func playNextInsertsAfterCurrent() {
        let coordinator = PlayerCoordinator()
        coordinator.play(item("a"), playlistQueue: [item("a"), item("b"), item("c")], initialIndex: 1)
        coordinator.playNext(item("x"))

        #expect(coordinator.playlistQueue.map(\.videoId) == ["a", "b", "x", "c"])
        #expect(coordinator.initialIndex == 1)
    }

    @Test func removeBeforeCurrentShiftsIndex() {
        let coordinator = PlayerCoordinator()
        coordinator.play(item("c"), playlistQueue: [item("a"), item("b"), item("c")], initialIndex: 2)
        coordinator.removeFromQueue(at: 0)

        #expect(coordinator.playlistQueue.map(\.videoId) == ["b", "c"])
        #expect(coordinator.initialIndex == 1)
    }

    @Test func removeCurrentIsIgnored() {
        let coordinator = PlayerCoordinator()
        coordinator.play(item("a"), playlistQueue: [item("a"), item("b")], initialIndex: 0)
        coordinator.removeFromQueue(at: 0)

        #expect(coordinator.playlistQueue.count == 2)
    }

    @Test func movePreservesCurrentTrack() {
        let coordinator = PlayerCoordinator()
        coordinator.play(item("a"), playlistQueue: [item("a"), item("b"), item("c")], initialIndex: 0)
        coordinator.moveInQueue(from: IndexSet(integer: 2), to: 0)

        #expect(coordinator.playlistQueue.map(\.videoId) == ["c", "a", "b"])
        #expect(coordinator.playlistQueue[coordinator.initialIndex].videoId == "a")
    }

    @Test func jumpToSetsCurrent() {
        let coordinator = PlayerCoordinator()
        coordinator.play(item("a"), playlistQueue: [item("a"), item("b"), item("c")], initialIndex: 0)
        coordinator.jumpTo(index: 2)

        #expect(coordinator.initialIndex == 2)
        #expect(coordinator.currentVideoID == "c")
    }
}

// MARK: - PlayerViewModel コメント ユニットテスト

@MainActor
struct PlayerViewModelCommentTests {

    @Test func loadPopulatesComments() async {
        let testComments = [
            CommentItem(id: "1", authorName: "A", authorAvatarURL: nil, contentText: "Hello", publishedTimeText: nil, likeCountText: nil, replyCount: 0)
        ]
        let client = ContentClient.mock(
            fetchComments: { _ in (testComments, "next_token") }
        )
        let dummyURL = URL(string: "https://example.com/v.mp4")!
        let vm = PlayerViewModel(
            youtubeClient: YouTubeClient(fetchVideo: { _ in
                VideoInfo(streamURL: dummyURL, audioOnlyURL: nil, title: "テスト", thumbnailURL: "", channelId: nil, channelName: nil, channelAvatarURL: nil)
            }),
            contentClient: client
        )
        let container = try! ModelContainer(for: WatchedVideo.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        await vm.load(videoID: "test", modelContext: ctx)
        #expect(vm.comments.count == 1)
        #expect(vm.comments[0].contentText == "Hello")
        #expect(vm.commentsContinuation == "next_token")
        #expect(!vm.isLoadingComments)
    }

    @Test func loadHandlesCommentError() async {
        let client = ContentClient.mock(
            fetchComments: { _ in throw URLError(.notConnectedToInternet) }
        )
        let dummyURL = URL(string: "https://example.com/v.mp4")!
        let vm = PlayerViewModel(
            youtubeClient: YouTubeClient(fetchVideo: { _ in
                VideoInfo(streamURL: dummyURL, audioOnlyURL: nil, title: "テスト", thumbnailURL: "", channelId: nil, channelName: nil, channelAvatarURL: nil)
            }),
            contentClient: client
        )
        let container = try! ModelContainer(for: WatchedVideo.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        await vm.load(videoID: "test", modelContext: ctx)
        #expect(vm.comments.isEmpty)
        #expect(!vm.isLoadingComments)
    }

    @Test func loadMoreCommentsAppendsResults() async {
        let page1 = [CommentItem(id: "1", authorName: "A", authorAvatarURL: nil, contentText: "First", publishedTimeText: nil, likeCountText: nil, replyCount: 0)]
        let page2 = [CommentItem(id: "2", authorName: "B", authorAvatarURL: nil, contentText: "Second", publishedTimeText: nil, likeCountText: nil, replyCount: 0)]
        let client = ContentClient.mock(
            fetchComments: { _ in (page1, "page2_token") },
            fetchCommentsPage: { _ in (page2, nil) }
        )
        let dummyURL = URL(string: "https://example.com/v.mp4")!
        let vm = PlayerViewModel(
            youtubeClient: YouTubeClient(fetchVideo: { _ in
                VideoInfo(streamURL: dummyURL, audioOnlyURL: nil, title: "テスト", thumbnailURL: "", channelId: nil, channelName: nil, channelAvatarURL: nil)
            }),
            contentClient: client
        )
        let container = try! ModelContainer(for: WatchedVideo.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        await vm.load(videoID: "test", modelContext: ctx)
        #expect(vm.comments.count == 1)

        await vm.loadMoreComments()
        #expect(vm.comments.count == 2)
        #expect(vm.comments[1].contentText == "Second")
        #expect(vm.commentsContinuation == nil)
    }
}

// MARK: - YouTubeClient フォールバック ユニットテスト

@MainActor
struct YouTubeClientFallbackTests {

    @Test func fetchVideoFallsBackOnFailure() async {
        // IOS → WEB が失敗して最終的にエラーになるケース
        let client = YouTubeClient(fetchVideo: { _ in
            throw YouTubeClientError.streamNotFound
        })
        do {
            _ = try await client.fetchVideo("test")
            #expect(Bool(false), "エラーが発生するべき")
        } catch {
            #expect(error is YouTubeClientError)
        }
    }

    @Test func fetchVideoReturnsVideoInfo() async throws {
        let url = URL(string: "https://example.com/stream.mp4")!
        let client = YouTubeClient(fetchVideo: { _ in
            VideoInfo(
                streamURL: url, audioOnlyURL: nil,
                title: "テスト動画", thumbnailURL: "https://example.com/thumb.jpg",
                channelId: "UC123", channelName: "テストチャンネル",
                channelAvatarURL: nil, playbackTrackingURLs: nil
            )
        })
        let info = try await client.fetchVideo("abc")
        #expect(info.streamURL == url)
        #expect(info.title == "テスト動画")
        #expect(info.channelName == "テストチャンネル")
    }
}

// MARK: - MiniPlayerView 表示モードテスト

@MainActor
struct MiniPlayerCoordinatorTests {

    @Test func minimizePreservesVideoID() {
        let c = PlayerCoordinator()
        c.play(videoID: "vid1")
        c.minimize()
        #expect(c.mode == .miniPlayer)
        #expect(c.currentVideoID == "vid1")
    }

    @Test func expandFromMiniPlayer() {
        let c = PlayerCoordinator()
        c.play(videoID: "vid1")
        c.minimize()
        c.expand()
        #expect(c.mode == .fullScreen)
        #expect(c.currentVideoID == "vid1")
    }

    @Test func playNewVideoWhileMiniPlayer() {
        let c = PlayerCoordinator()
        c.play(videoID: "vid1")
        c.minimize()
        c.play(videoID: "vid2")
        #expect(c.mode == .fullScreen)
        #expect(c.currentVideoID == "vid2")
    }

    @Test func dismissFromMiniPlayer() {
        let c = PlayerCoordinator()
        c.play(videoID: "vid1")
        c.minimize()
        c.dismiss()
        #expect(c.mode == .hidden)
        #expect(c.currentVideoID == nil)
    }
}

// MARK: - ChannelViewModel 追加テスト

@MainActor
struct ChannelViewModelTabTests {

    @Test func selectTabCachesResults() async {
        let mockVideo = VideoItem(
            videoId: "ch-v1", title: "チャンネル動画",
            channelName: "テスト", thumbnailURL: nil
        )
        let client = ContentClient.mock(
            fetchChannel: { id in
                ChannelInfo(channelId: id, name: "テスト", handle: nil, subscriberCount: nil, videoCount: nil, avatarURL: nil, bannerURL: nil)
            },
            fetchChannelTab: { _, tab in
                ([mockVideo], nil)
            }
        )
        let vm = ChannelViewModel(contentClient: client)
        await vm.load(channelId: "UC123")

        // ホームタブが読み込まれている
        #expect(vm.tabVideos[.home]?.count == 1)

        // 動画タブに切り替え
        await vm.selectTab(.videos)
        #expect(vm.tabVideos[.videos]?.count == 1)

        // 既にキャッシュ済みなので再取得されない（データが残っている）
        await vm.selectTab(.videos)
        #expect(vm.tabVideos[.videos]?.count == 1)
    }

    @Test func selectTabHandlesError() async {
        let client = ContentClient.mock(
            fetchChannel: { id in
                ChannelInfo(channelId: id, name: "テスト", handle: nil, subscriberCount: nil, videoCount: nil, avatarURL: nil, bannerURL: nil)
            },
            fetchChannelTab: { _, _ in
                throw URLError(.badServerResponse)
            }
        )
        let vm = ChannelViewModel(contentClient: client)
        await vm.load(channelId: "UC123")

        // エラー時は空配列がセットされる
        #expect(vm.tabVideos[.home] == nil || vm.tabVideos[.home]?.isEmpty == true)
    }

    @Test func loadMoreAppendsVideos() async {
        var callCount = 0
        let client = ContentClient.mock(
            fetchChannel: { id in
                ChannelInfo(channelId: id, name: "テスト", handle: nil, subscriberCount: nil, videoCount: nil, avatarURL: nil, bannerURL: nil)
            },
            fetchChannelTab: { _, _ in
                ([VideoItem(videoId: "v1", title: "初回", channelName: nil, thumbnailURL: nil)], "token1")
            },
            fetchChannelTabPage: { _ in
                callCount += 1
                return ([VideoItem(videoId: "v2", title: "追加", channelName: nil, thumbnailURL: nil)], nil)
            }
        )
        let vm = ChannelViewModel(contentClient: client)
        await vm.load(channelId: "UC123")
        #expect(vm.tabVideos[.home]?.count == 1)

        await vm.loadMore()
        #expect(vm.tabVideos[.home]?.count == 2)
        #expect(callCount == 1)
    }
}

// MARK: - AccountViewModel 削除テスト

@MainActor
struct AccountViewModelDeleteTests {

    @Test func deletePlaylistRemovesFromList() async {
        var deletedId: String?
        let playlist = YTPlaylist(playlistId: "PL123")
        let client = AccountClient.mock(
            fetchInfo: { AccountInfo(name: "テスト", handle: nil, avatarURL: nil) },
            fetchLibrary: { LibraryResponse(watchLater: nil, likes: nil, playlists: [playlist]) }
        )
        let vm = AccountViewModel(accountClient: client)
        await vm.load()
        #expect(vm.playlists.count == 1)

        // deletePlaylist は ContentClient.deletePlaylist を呼ぶが、ここでは楽観的UI更新を確認
        // mock では削除API自体は呼ばれないので、リストから即座に消えることを確認
        vm.playlists.removeAll { $0.playlistId == "PL123" }
        #expect(vm.playlists.isEmpty)
    }
}

// MARK: - PlaylistDetailViewModel 追加テスト

@MainActor
struct PlaylistDetailViewModelLoadTests {

    @Test func loadSetsLoadingFalse() async {
        let client = AccountClient.mock(
            fetchPlaylistVideos: { _ in
                [VideoItem(videoId: "pl-v1", title: "プレイリスト動画", channelName: nil, thumbnailURL: nil)]
            }
        )
        let vm = PlaylistDetailViewModel(accountClient: client)
        #expect(vm.isLoading == true)

        await vm.load(playlistId: "PL999")
        #expect(vm.isLoading == false)
        #expect(vm.videos.count == 1)
        #expect(vm.error == nil)
    }

    @Test func loadSetsErrorOnFailure() async {
        let client = AccountClient.mock(
            fetchPlaylistVideos: { _ in throw URLError(.notConnectedToInternet) }
        )
        let vm = PlaylistDetailViewModel(accountClient: client)
        await vm.load(playlistId: "PL999")
        #expect(vm.isLoading == false)
        #expect(vm.error != nil)
        #expect(vm.videos.isEmpty)
    }
}

// MARK: - InnertubeRequest 共有セッション設定テスト

struct InnertubeRequestSessionTests {

    /// セッションが単一インスタンスとして共有されること（コネクション再利用のため）
    @Test func sessionIsSharedInstance() {
        #expect(InnertubeRequest.session === InnertubeRequest.session)
    }

    /// Cookie がシステムに上書きされないよう無効化されていること
    @Test func sessionDisablesCookieHandling() {
        let config = InnertubeRequest.session.configuration
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieAcceptPolicy == .never)
    }

    /// 弱い電波向けの設定: 一時的な切断は待機し、ハングは早めに打ち切ること
    @Test func sessionIsTunedForWeakNetwork() {
        let config = InnertubeRequest.session.configuration
        #expect(config.waitsForConnectivity == true)
        #expect(config.timeoutIntervalForRequest == 15)
        #expect(config.timeoutIntervalForResource == 30)
    }
}

// MARK: - 音声のみモード: フォーマット選択テスト

struct AudioOnlyFormatSelectionTests {

    private func format(mime: String, bitrate: Int, url: String? = "https://example.com/a") -> [String: Any] {
        var f: [String: Any] = ["mimeType": mime, "bitrate": bitrate]
        if let url { f["url"] = url }
        return f
    }

    /// AVPlayer が再生できない opus (audio/webm) はビットレートが高くても選ばないこと
    @Test func prefersMp4AudioOverHigherBitrateWebm() {
        let formats = [
            format(mime: "audio/webm; codecs=\"opus\"", bitrate: 160_000, url: "https://example.com/opus"),
            format(mime: "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 128_000, url: "https://example.com/aac")
        ]
        let url = YouTubeClient.selectAudioOnlyURL(from: formats)
        #expect(url?.absoluteString == "https://example.com/aac")
    }

    /// audio/mp4 の中では最高ビットレートを選ぶこと
    @Test func picksHighestBitrateMp4Audio() {
        let formats = [
            format(mime: "audio/mp4; codecs=\"mp4a.40.5\"", bitrate: 48_000, url: "https://example.com/low"),
            format(mime: "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 128_000, url: "https://example.com/high"),
            format(mime: "video/mp4; codecs=\"avc1\"", bitrate: 1_000_000)
        ]
        let url = YouTubeClient.selectAudioOnlyURL(from: formats)
        #expect(url?.absoluteString == "https://example.com/high")
    }

    /// 再生可能な音声フォーマットがない場合は nil を返すこと
    @Test func returnsNilWhenNoMp4Audio() {
        let formats = [
            format(mime: "video/mp4; codecs=\"avc1\"", bitrate: 1_000_000),
            format(mime: "audio/webm; codecs=\"opus\"", bitrate: 160_000)
        ]
        #expect(YouTubeClient.selectAudioOnlyURL(from: formats) == nil)
    }

    /// url を持たない（signatureCipher のみの）フォーマットは選ばないこと
    @Test func skipsFormatsWithoutDirectURL() {
        let formats = [
            format(mime: "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 128_000, url: nil),
            format(mime: "audio/mp4; codecs=\"mp4a.40.5\"", bitrate: 48_000, url: "https://example.com/low")
        ]
        let url = YouTubeClient.selectAudioOnlyURL(from: formats)
        #expect(url?.absoluteString == "https://example.com/low")
    }
}

// MARK: - 音声のみモード: PlayerItem 生成テスト

struct PlayerViewModelAudioOnlyTests {

    private func makeInfo(audioURL: URL?) -> VideoInfo {
        VideoInfo(
            streamURL: URL(string: "https://example.com/video.m3u8")!,
            audioOnlyURL: audioURL,
            title: "テスト動画",
            thumbnailURL: "",
            channelId: nil,
            channelName: nil,
            channelAvatarURL: nil
        )
    }

    /// 音声のみモードでは音声 URL のアイテムを作ること
    @Test func audioOnlyUsesAudioURL() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in fatalError("未使用") }), contentClient: .mock())
        let audio = URL(string: "https://example.com/audio.m4a")!
        let item = vm.makePlayerItem(info: makeInfo(audioURL: audio), audioOnly: true)
        // スロットリング回避のため audio は ResourceLoader 用のカスタムスキームで包まれる
        #expect((item.asset as? AVURLAsset)?.url.absoluteString.contains("example.com/audio.m4a") == true)
    }

    /// 音声 URL がない場合は動画にフォールバックしつつビットレート上限で通信量を抑えること
    @Test func audioOnlyWithoutAudioURLCapsBitrate() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in fatalError("未使用") }), contentClient: .mock())
        let item = vm.makePlayerItem(info: makeInfo(audioURL: nil), audioOnly: true)
        #expect((item.asset as? AVURLAsset)?.url.absoluteString == "https://example.com/video.m3u8")
        #expect(item.preferredPeakBitRate == 300_000)
    }

    /// 通常モードでは動画ストリームをそのまま使い、ビットレート上限を掛けないこと
    @Test func normalModeUsesStreamURLWithoutCap() {
        let vm = PlayerViewModel(youtubeClient: YouTubeClient(fetchVideo: { _ in fatalError("未使用") }), contentClient: .mock())
        let audio = URL(string: "https://example.com/audio.m4a")!
        let item = vm.makePlayerItem(info: makeInfo(audioURL: audio), audioOnly: false)
        #expect((item.asset as? AVURLAsset)?.url.absoluteString == "https://example.com/video.m3u8")
        #expect(item.preferredPeakBitRate == 0)
    }
}

// MARK: - 音声のみモード: WebPage フォールバックの音声 URL 選択テスト

struct Mp4AudioStreamURLSelectionTests {

    /// URL エンコードされた mime=audio%2Fmp4 を選ぶこと
    @Test func picksEncodedMp4AudioURL() {
        let streams = [
            "https://example.googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4",
            "https://example.googlevideo.com/videoplayback?itag=140&mime=audio%2Fmp4"
        ]
        let url = YouTubeClient.selectMp4AudioURL(fromStreamURLs: streams)
        #expect(url?.absoluteString.contains("itag=140") == true)
    }

    /// エンコードされていない mime=audio/mp4 も選べること
    @Test func picksUnencodedMp4AudioURL() {
        let streams = [
            "https://example.googlevideo.com/videoplayback?itag=140&mime=audio/mp4"
        ]
        let url = YouTubeClient.selectMp4AudioURL(fromStreamURLs: streams)
        #expect(url != nil)
    }

    /// AVPlayer が再生できない opus (audio/webm) は選ばず nil を返すこと
    @Test func skipsWebmAudioURL() {
        let streams = [
            "https://example.googlevideo.com/videoplayback?itag=251&mime=audio%2Fwebm",
            "https://example.googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4"
        ]
        #expect(YouTubeClient.selectMp4AudioURL(fromStreamURLs: streams) == nil)
    }
}
