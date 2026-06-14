//
//  YouTubeConstants.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/24.
//

import Foundation

/// YouTube / Innertube API で使用する定数を一元管理する。
enum YouTubeConstants {

    // MARK: - API エンドポイント

    static let browseURL = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
    static let nextURL = URL(string: "https://www.youtube.com/youtubei/v1/next?prettyPrint=false")!
    static let playerURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    static let feedbackURL = URL(string: "https://www.youtube.com/youtubei/v1/feedback?prettyPrint=false")!
    static let editPlaylistURL = URL(string: "https://www.youtube.com/youtubei/v1/browse/edit_playlist?prettyPrint=false")!
    static let subscribeURL = URL(string: "https://www.youtube.com/youtubei/v1/subscription/subscribe?prettyPrint=false")!
    static let unsubscribeURL = URL(string: "https://www.youtube.com/youtubei/v1/subscription/unsubscribe?prettyPrint=false")!

    /// API キー付きエンドポイント（AccountClient 用）
    static let browseWithKeyURL = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=\(apiKey)&prettyPrint=false")!
    static let accountMenuURL = URL(string: "https://www.youtube.com/youtubei/v1/account/account_menu?key=\(apiKey)&prettyPrint=false")!

    // MARK: - API キー

    static let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"

    // MARK: - WEB クライアント

    static let webClientName = "WEB"
    static let webClientVersion = "2.20250415.01.00"
    static let webClientNameValue = "1"
    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"

    // MARK: - IOS クライアント

    static let iosClientName = "IOS"
    static let iosClientVersion = "21.13.6"
    static let iosClientNameValue = "5"
    static let iosDeviceModel = "iPhone16,2"
    static let iosOSVersion = "18.4.0"
    static let iosUserAgent = "com.google.ios.youtube/\(iosClientVersion) (\(iosDeviceModel); U; CPU iOS 18_4 like Mac OS X;)"

    // MARK: - ANDROID_VR クライアント（PO Token 不要・visitorData 必須、再生可能な直 URL を返す）

    static let androidVrClientName = "ANDROID_VR"
    static let androidVrClientVersion = "1.65.10"
    static let androidVrClientNameValue = "28"
    static let androidVrUserAgent = "com.google.android.apps.youtube.vr.oculus/\(androidVrClientVersion) (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    // MARK: - ロケール

    static let language = "ja"
    static let region = "JP"

    // MARK: - Origin / Referer

    static let origin = "https://www.youtube.com"
    static let referer = "https://www.youtube.com/"

    // MARK: - コンテキスト生成

    /// WEB クライアントの context 辞書を返す
    static var webClientContext: [String: Any] {
        ["client": [
            "clientName": webClientName,
            "clientVersion": webClientVersion,
            "hl": language,
            "gl": region
        ]]
    }

    /// IOS クライアントの context 辞書を返す
    static var iosClientContext: [String: Any] {
        ["client": [
            "clientName": iosClientName,
            "clientVersion": iosClientVersion,
            "deviceMake": "Apple",
            "deviceModel": iosDeviceModel,
            "osName": "iPhone",
            "osVersion": iosOSVersion,
            "hl": language,
            "gl": region
        ]]
    }

    /// ANDROID_VR クライアントの context 辞書を返す（visitorData は呼び出し側で付与）
    static func androidVrClientContext(visitorData: String) -> [String: Any] {
        ["client": [
            "clientName": androidVrClientName,
            "clientVersion": androidVrClientVersion,
            "deviceMake": "Oculus",
            "deviceModel": "Quest 3",
            "androidSdkVersion": 32,
            "osName": "Android",
            "osVersion": "12L",
            "hl": language,
            "gl": region,
            "visitorData": visitorData
        ]]
    }
}
