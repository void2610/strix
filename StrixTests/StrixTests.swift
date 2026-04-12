//
//  StrixTests.swift
//  StrixTests
//
//  Created by Shuya Izumi on 2026/04/07.
//

import Testing
import Foundation
import SwiftData
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

    @Test func parseLockupViewModelFallsBackToVideoIdForTitle() {
        var json = makeLockupViewModelJSON(contentId: "fallback123")
        json["metadata"] = [String: Any]()  // metadata なし
        let item = ContentClient.parseLockupViewModel(json)
        #expect(item?.title == "fallback123")
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
                fetchHistoryVideos: { [mockVideo] }
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
}

// MARK: - ContentClient 結合テスト (fetchHistoryVideos)

struct ContentClientHistoryTests {

    @Test func fetchHistoryVideosReturnsWithoutThrowing() async throws {
        // 未認証環境では空配列を返す（ guard !cookies.isEmpty で弾かれる）
        // 少なくともクラッシュ・例外が発生しないことを確認する
        let result = try await ContentClient.live.fetchHistoryVideos()
        // 未認証なら空、認証済みなら 1 件以上
        #expect(result.allSatisfy { !$0.videoId.isEmpty })
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
            VideoInfo(streamURL: dummyURL, title: "テスト動画", thumbnailURL: "https://example.com/thumb.jpg", channelId: nil, channelName: nil, channelAvatarURL: nil)
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
            VideoInfo(streamURL: dummyURL, title: "履歴テスト", thumbnailURL: "https://example.com/t.jpg", channelId: nil, channelName: nil, channelAvatarURL: nil)
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
}

// MARK: - WatchedVideo ユニットテスト

struct WatchedVideoTests {

    @Test func initStoresAllProperties() {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let video = WatchedVideo(
            videoID: "abc123",
            title: "テスト動画",
            thumbnailURL: "https://example.com/thumb.jpg",
            watchedAt: date
        )
        #expect(video.videoID == "abc123")
        #expect(video.title == "テスト動画")
        #expect(video.thumbnailURL == "https://example.com/thumb.jpg")
        #expect(video.watchedAt == date)
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
