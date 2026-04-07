//
//  StrixTests.swift
//  StrixTests
//
//  Created by Shuya Izumi on 2026/04/07.
//

import Testing
import Foundation
import YouTubeKit
@testable import Strix

// MARK: - YouTubeClient テスト

struct YouTubeClientTests {
    let testVideoID = "jYg8wCT02FA"

    @Test func fetchVideoReturnsStreamURL() async throws {
        let info = try await YouTubeClient.live.fetchVideo(testVideoID)
        #expect(!info.streamURL.absoluteString.isEmpty)
        #expect(info.title != testVideoID)
        #expect(info.streamURL.absoluteString.contains("googlevideo") ||
                info.streamURL.absoluteString.contains("manifest"))
    }
}

// MARK: - ContentClient テスト

struct ContentClientTests {

    @Test func searchReturnsResults() async throws {
        let results = try await ContentClient.live.search("Swift programming")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { !$0.videoId.isEmpty })
    }

    @Test func fetchRelatedReturnsVideos() async throws {
        let results = try await ContentClient.live.fetchRelated("jYg8wCT02FA")
        // 関連動画は取れる場合と取れない場合がある（エラーにはならない）
        #expect(results.allSatisfy { !$0.videoId.isEmpty })
    }
}

// MARK: - VideoID パーサー テスト

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
}
