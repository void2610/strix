//
//  InnertubeRequest.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/24.
//

import Foundation

/// Innertube API リクエストの共通ビルダー。
/// ヘッダー設定・セッション構成・認証適用・リクエスト送信を一元化する。
enum InnertubeRequest {

    /// Cookie をシステムに上書きされないよう設定した ephemeral セッションを返す
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }

    /// WEB クライアント用の POST リクエストを構築する
    static func webRequest(url: URL, body: [String: Any], authenticated: Bool = true) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(YouTubeConstants.origin, forHTTPHeaderField: "Origin")
        request.setValue(YouTubeConstants.referer, forHTTPHeaderField: "Referer")
        request.setValue(YouTubeConstants.webUserAgent, forHTTPHeaderField: "User-Agent")

        if authenticated {
            ContentClient.applyAuth(to: &request)
        }

        // context が未設定なら自動付与
        var finalBody = body
        if finalBody["context"] == nil {
            finalBody["context"] = YouTubeConstants.webClientContext
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: finalBody)
        return request
    }

    /// WEB クライアント用リクエストを送信し、JSON を返す
    static func fetchWeb(url: URL, body: [String: Any], authenticated: Bool = true) async throws -> [String: Any] {
        let request = try webRequest(url: url, body: body, authenticated: authenticated)
        let (data, _) = try await makeSession().data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// WEB クライアント用リクエストを送信（レスポンス不要のアクション用）
    static func performWeb(url: URL, body: [String: Any]) async throws {
        let request = try webRequest(url: url, body: body)
        let _ = try await makeSession().data(for: request)
    }

    /// X-YouTube-Client-Name/Version ヘッダー付きの WEB リクエストを構築する（AccountClient 用）
    static func webRequestWithClientHeaders(url: URL, body: [String: Any]) throws -> URLRequest {
        var request = try webRequest(url: url, body: body)
        request.setValue(YouTubeConstants.webClientNameValue, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(YouTubeConstants.webClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        return request
    }

    /// X-YouTube-Client-Name/Version ヘッダー付きの WEB リクエストを送信し、JSON を返す
    static func fetchWebWithClientHeaders(url: URL, body: [String: Any]) async throws -> [String: Any] {
        let request = try webRequestWithClientHeaders(url: url, body: body)
        let (data, _) = try await makeSession().data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
