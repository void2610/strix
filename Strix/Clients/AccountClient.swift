//
//  AccountClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import CryptoKit
import YouTubeKit

// MARK: - アカウント情報モデル

/// Innertube account_menu から取得するシンプルなアカウント情報。
struct AccountInfo {
    let name: String?
    let handle: String?
    let avatarURL: URL?
}

// MARK: - クライアント定義

/// アカウント情報・ライブラリ・視聴履歴・プレイリスト動画を取得するクライアント。
struct AccountClient {
    var fetchInfo: () async throws -> AccountInfo
    var fetchLibrary: () async throws -> AccountLibraryResponse
    var fetchHistory: () async throws -> HistoryResponse
    var fetchPlaylistVideos: (_ playlistId: String) async throws -> [VideoItem]
}

// MARK: - モック（テスト用）

extension AccountClient {
    static func mock(
        fetchInfo: @escaping () async throws -> AccountInfo = { AccountInfo(name: nil, handle: nil, avatarURL: nil) },
        fetchLibrary: @escaping () async throws -> AccountLibraryResponse = { AccountLibraryResponse.decodeData(data: Data()) },
        fetchHistory: @escaping () async throws -> HistoryResponse = { HistoryResponse.decodeData(data: Data()) },
        fetchPlaylistVideos: @escaping (String) async throws -> [VideoItem] = { _ in [] }
    ) -> AccountClient {
        AccountClient(
            fetchInfo: fetchInfo,
            fetchLibrary: fetchLibrary,
            fetchHistory: fetchHistory,
            fetchPlaylistVideos: fetchPlaylistVideos
        )
    }
}

// MARK: - 本番クライアント

extension AccountClient {
    static let live: AccountClient = {
        let model = YouTubeModel()

        return AccountClient(
            fetchInfo: {
                let cookies = AuthState.shared.cookieString ?? ""
                return try await AccountClient.fetchInfoViaInnertube(cookies: cookies)
            },
            fetchLibrary: {
                let cookies = ContentClient.deduplicateCookies(AuthState.shared.cookieString ?? "")
                model.cookies = cookies
                let (response, error) = await AccountLibraryResponse.sendRequest(
                    youtubeModel: model, data: [:]
                )
                if let error { throw error }
                return response ?? AccountLibraryResponse.decodeData(data: Data())
            },
            fetchHistory: {
                let cookies = ContentClient.deduplicateCookies(AuthState.shared.cookieString ?? "")
                model.cookies = cookies
                let (response, error) = await HistoryResponse.sendRequest(
                    youtubeModel: model, data: [:]
                )
                if let error { throw error }
                return response ?? HistoryResponse.decodeData(data: Data())
            },
            fetchPlaylistVideos: { playlistId in
                let cookies = ContentClient.deduplicateCookies(AuthState.shared.cookieString ?? "")
                model.cookies = cookies
                let (response, error) = await PlaylistInfosResponse.sendRequest(
                    youtubeModel: model,
                    data: [.browseId: playlistId]
                )
                if let error { throw error }
                guard var response else {
                    return try await ContentClient.live.fetchPlaylistVideos(playlistId)
                }

                while response.continuationToken != nil {
                    let (continuation, continuationError) = await response.fetchContinuation(youtubeModel: model)
                    if let continuationError { throw continuationError }
                    guard let continuation else { break }
                    response.mergeWithContinuation(continuation)
                }

                let videos = response.results
                    .compactMap { $0 as? YTVideo }
                    .map { $0.toVideoItem }
                if !videos.isEmpty { return videos }
                return try await ContentClient.live.fetchPlaylistVideos(playlistId)
            }
        )
    }()
}

// MARK: - Innertube account_menu によるアカウント情報取得

extension AccountClient {

    /// Innertube /account/account_menu (WEB client) でアカウント名・ハンドル・アバターを取得する。
    private static func fetchInfoViaInnertube(cookies: String) async throws -> AccountInfo {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/account/account_menu?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("2.20241201.01.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        if !cookies.isEmpty {
            let deduped = ContentClient.deduplicateCookies(cookies)
            request.setValue(deduped, forHTTPHeaderField: "Cookie")
            if let auth = ContentClient.buildSapisidHash(from: deduped) {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
        }

        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB",
                "clientVersion": "2.20241201.01.00",
                "hl": "ja",
                "gl": "JP"
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: sessionConfig)
        let (data, _) = try await session.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AccountInfo(name: nil, handle: nil, avatarURL: nil)
        }

        // actions[0].openPopupAction.popup.multiPageMenuRenderer.header.activeAccountHeaderRenderer
        let actions = json["actions"] as? [[String: Any]]
        let popup = (actions?.first?["openPopupAction"] as? [String: Any])?["popup"] as? [String: Any]
        let menuHeader = (popup?["multiPageMenuRenderer"] as? [String: Any])?["header"] as? [String: Any]
        let renderer = menuHeader?["activeAccountHeaderRenderer"] as? [String: Any]

        let name = (renderer?["accountName"] as? [String: Any])?["simpleText"] as? String
        let handle = (renderer?["channelHandle"] as? [String: Any])?["simpleText"] as? String
        let photos = (renderer?["accountPhoto"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let avatarURL = (photos?.last?["url"] as? String).flatMap { URL(string: $0) }

        return AccountInfo(name: name, handle: handle, avatarURL: avatarURL)
    }
}
