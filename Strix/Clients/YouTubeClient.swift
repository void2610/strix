//
//  YouTubeClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/07.
//

import Foundation

/// Innertube API を iOS クライアントとして呼び出して動画ストリームを取得するクライアント。
/// iOS クライアントは通常動画にも hlsManifestUrl（M3U8）を返すため AVPlayer で直接再生可能。
struct YouTubeClient {
    var fetchVideo: (String) async throws -> VideoInfo
}

struct VideoInfo {
    let streamURL: URL
    let title: String
    let thumbnailURL: String
}

enum YouTubeClientError: LocalizedError {
    case streamNotFound
    case notPlayable(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .streamNotFound:       return "再生可能なストリームが見つかりませんでした"
        case .notPlayable(let msg): return "再生不可: \(msg)"
        case .networkError(let e):  return "ネットワークエラー: \(e.localizedDescription)"
        }
    }
}

extension YouTubeClient {
    static let live = YouTubeClient(
        fetchVideo: { videoID in
            // IOS クライアント（v21.13.6）で Innertube /player を呼ぶ。
            // iOS クライアントは通常動画でも hlsManifestUrl を返す。
            let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "com.google.ios.youtube/21.13.6 (iPhone16,2; U; CPU iOS 26_4 like Mac OS X;)",
                forHTTPHeaderField: "User-Agent"
            )
            // クライアント識別ヘッダー（IOS = 5）
            request.setValue("5",        forHTTPHeaderField: "X-Youtube-Client-Name")
            request.setValue("21.13.6",  forHTTPHeaderField: "X-Youtube-Client-Version")

            let body: [String: Any] = [
                "videoId": videoID,
                "contentCheckOk": true,
                "racyCheckOk": true,
                "context": [
                    "client": [
                        "clientName": "IOS",
                        "clientVersion": "21.13.6",
                        "deviceMake": "Apple",
                        "deviceModel": "iPhone16,2",
                        "osName": "iPhone",
                        "osVersion": "26.4.23E246",
                        "userAgent": "com.google.ios.youtube/21.13.6 (iPhone16,2; U; CPU iOS 26_4 like Mac OS X;)",
                        "timeZone": "UTC",
                        "utcOffsetMinutes": 0
                    ]
                ],
                "playbackContext": [
                    "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let data: Data
            do {
                let (d, _) = try await URLSession.shared.data(for: request)
                data = d
            } catch {
                throw YouTubeClientError.networkError(error)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YouTubeClientError.streamNotFound
            }

            // 再生可否を確認
            let playability = json["playabilityStatus"] as? [String: Any]
            let status = playability?["status"] as? String ?? ""
            if status != "OK" {
                let reason = playability?["reason"] as? String ?? status
                throw YouTubeClientError.notPlayable(reason)
            }

            // タイトルとサムネイルを取得
            let videoDetails = json["videoDetails"] as? [String: Any]
            let title = videoDetails?["title"] as? String ?? videoID
            let thumbnails = (videoDetails?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let thumbnailURL = thumbnails?.last?["url"] as? String ?? ""

            // HLS manifest URL（iOS クライアントは通常動画でもこれを返す）
            let streamingData = json["streamingData"] as? [String: Any]
            guard let hlsString = streamingData?["hlsManifestUrl"] as? String,
                  let streamURL = URL(string: hlsString) else {
                throw YouTubeClientError.streamNotFound
            }

            return VideoInfo(streamURL: streamURL, title: title, thumbnailURL: thumbnailURL)
        }
    )
}
