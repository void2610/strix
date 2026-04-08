//
//  AccountClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import YouTubeKit

/// アカウント情報・ライブラリ・視聴履歴・プレイリスト動画を取得するクライアント。
struct AccountClient {
    var fetchInfo: () async throws -> AccountInfosResponse
    var fetchLibrary: () async throws -> AccountLibraryResponse
    var fetchHistory: () async throws -> HistoryResponse
    var fetchPlaylistVideos: (_ playlistId: String) async throws -> [VideoItem]
}

// MARK: - モック（テスト用）

extension AccountClient {
    static func mock(
        fetchInfo: @escaping () async throws -> AccountInfosResponse = { AccountInfosResponse.decodeData(data: Data()) },
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
                model.cookies = AuthState.shared.cookieString ?? ""
                let (response, error) = await AccountInfosResponse.sendRequest(
                    youtubeModel: model, data: [:]
                )
                if let error { throw error }
                return response ?? AccountInfosResponse.decodeData(data: Data())
            },
            fetchLibrary: {
                model.cookies = AuthState.shared.cookieString ?? ""
                let (response, error) = await AccountLibraryResponse.sendRequest(
                    youtubeModel: model, data: [:]
                )
                if let error { throw error }
                return response ?? AccountLibraryResponse.decodeData(data: Data())
            },
            fetchHistory: {
                model.cookies = AuthState.shared.cookieString ?? ""
                let (response, error) = await HistoryResponse.sendRequest(
                    youtubeModel: model, data: [:]
                )
                if let error { throw error }
                return response ?? HistoryResponse.decodeData(data: Data())
            },
            fetchPlaylistVideos: { playlistId in
                model.cookies = AuthState.shared.cookieString ?? ""
                let (response, error) = await PlaylistInfosResponse.sendRequest(
                    youtubeModel: model,
                    data: [.browseId: playlistId]
                )
                if let error { throw error }
                return (response?.results ?? [])
                    .compactMap { $0 as? YTVideo }
                    .map { $0.toVideoItem }
            }
        )
    }()
}
