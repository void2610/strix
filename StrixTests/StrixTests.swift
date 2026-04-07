//
//  StrixTests.swift
//  StrixTests
//
//  Created by Shuya Izumi on 2026/04/07.
//

import Testing
import Foundation
@testable import Strix

struct YouTubeClientTests {

    // テスト用動画 ID（公式 YouTube）
    let testVideoID = "jYg8wCT02FA"

    @Test func fetchVideoReturnsStreamURL() async throws {
        let info = try await YouTubeClient.live.fetchVideo(testVideoID)
        print("✅ streamURL: \(info.streamURL)")
        print("✅ title: \(info.title)")
        print("✅ thumbnailURL: \(info.thumbnailURL)")
        #expect(!info.streamURL.absoluteString.isEmpty)
        #expect(info.title != testVideoID) // タイトルが取れているか
    }

    @Test func intertubRawResponseDebug() async throws {
        // Innertube の生レスポンスを確認するデバッグ用テスト
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X)",
            forHTTPHeaderField: "User-Agent"
        )
        let body: [String: Any] = [
            "videoId": testVideoID,
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "19.29.1",
                    "deviceModel": "iPhone16,2",
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("📡 HTTP status: \(httpStatus)")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // playabilityStatus を確認
        let playability = json?["playabilityStatus"] as? [String: Any]
        print("▶️ playabilityStatus: \(playability?["status"] ?? "nil")")
        print("▶️ reason: \(playability?["reason"] ?? "なし")")

        // streamingData の有無を確認
        let streamingData = json?["streamingData"] as? [String: Any]
        print("📦 streamingData keys: \(streamingData?.keys.sorted() ?? [])")

        let formats = streamingData?["formats"] as? [[String: Any]] ?? []
        print("🎬 formats count: \(formats.count)")
        for (i, f) in formats.enumerated() {
            print("  [\(i)] mimeType=\(f["mimeType"] ?? "nil") quality=\(f["quality"] ?? "nil") url=\(((f["url"] as? String) != nil) ? "あり" : "なし（cipher?）")")
        }

        let adaptive = streamingData?["adaptiveFormats"] as? [[String: Any]] ?? []
        print("🔊 adaptiveFormats count: \(adaptive.count)")

        #expect(httpStatus == 200)
        #expect(streamingData != nil, "streamingData が nil - API レスポンス異常")
    }
}

struct VideoIDTests {

    @Test func extractFromFullURL() {
        let id = extractVideoID(from: "https://www.youtube.com/watch?v=jYg8wCT02FA")
        #expect(id == "jYg8wCT02FA")
    }

    @Test func extractFromShortURL() {
        let id = extractVideoID(from: "https://youtu.be/jYg8wCT02FA")
        #expect(id == "jYg8wCT02FA")
    }

    @Test func extractFromShortURLWithParams() {
        let id = extractVideoID(from: "https://youtu.be/jYg8wCT02FA?si=b91FPKR-tCiXxdWl")
        #expect(id == "jYg8wCT02FA")
    }

    @Test func extractFromShortsURL() {
        let id = extractVideoID(from: "https://www.youtube.com/shorts/jYg8wCT02FA")
        #expect(id == "jYg8wCT02FA")
    }

    @Test func extractFromDirectID() {
        let id = extractVideoID(from: "jYg8wCT02FA")
        #expect(id == "jYg8wCT02FA")
    }

    @Test func invalidInputReturnsNil() {
        #expect(extractVideoID(from: "notaurl") == nil)
        #expect(extractVideoID(from: "") == nil)
    }
}
