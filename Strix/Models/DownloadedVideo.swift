//
//  DownloadedVideo.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/07/10.
//

import Foundation
import SwiftData

/// ダウンロードの状態
enum DownloadState: Int, Codable, Sendable {
    /// ダウンロード中
    case downloading = 0
    /// 完了（オフライン再生可能）
    case completed = 1
    /// 失敗
    case failed = 2
}

/// オフライン再生用にローカル保存した動画を表すモデル。
/// 動画ファイル・サムネイルは Application Support/Downloads に保存し、
/// 絶対パスはアプリ再インストールで無効化するため相対ファイル名だけを保持する。
@Model
final class DownloadedVideo {
    @Attribute(.unique) var videoID: String
    var title: String
    var channelName: String?
    /// 表示用リモートサムネイル URL（ローカルサムネイルが無い場合のフォールバック）
    var remoteThumbnailURL: String
    /// 保存済み動画ファイル名（Downloads ディレクトリ相対）
    var fileName: String
    /// 保存済みサムネイルファイル名（nil ならリモート URL を使う）
    var thumbnailFileName: String?
    /// `DownloadState` の生値
    var stateRaw: Int
    /// ダウンロード進捗（0.0〜1.0）
    var progress: Double
    /// 保存済みファイルサイズ（バイト）
    var fileSize: Int64
    /// 動画の総再生時間（秒）
    var videoDuration: Double
    var downloadedAt: Date

    var state: DownloadState {
        get { DownloadState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    init(videoID: String,
         title: String,
         channelName: String? = nil,
         remoteThumbnailURL: String = "",
         fileName: String,
         thumbnailFileName: String? = nil,
         state: DownloadState = .downloading,
         progress: Double = 0,
         fileSize: Int64 = 0,
         videoDuration: Double = 0,
         downloadedAt: Date = .now) {
        self.videoID = videoID
        self.title = title
        self.channelName = channelName
        self.remoteThumbnailURL = remoteThumbnailURL
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.stateRaw = state.rawValue
        self.progress = progress
        self.fileSize = fileSize
        self.videoDuration = videoDuration
        self.downloadedAt = downloadedAt
    }
}

extension DownloadedVideo {
    /// 再生・リスト表示に使う VideoItem へ変換する
    var toVideoItem: VideoItem {
        VideoItem(
            videoId: videoID,
            title: title,
            channelName: channelName,
            thumbnailURL: URL(string: remoteThumbnailURL)
        )
    }
}
