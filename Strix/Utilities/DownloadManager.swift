//
//  DownloadManager.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/07/10.
//

import Foundation
import SwiftData

/// 動画のダウンロードとオフライン保存を管理する。
/// ストリーム取得（`fetchStream`）と実ファイル取得（`downloadFile`）を注入可能にし、
/// テスト時はネットワーク不要のフェイクへ差し替えられる。
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    /// 進行中ダウンロードの進捗（videoID → 0.0〜1.0）。UI がリアルタイム表示に使う。
    private(set) var progress: [String: Double] = [:]

    /// 実行中のダウンロードタスク（videoID → Task）
    private var tasks: [String: Task<Void, Never>] = [:]

    /// 保存先のベースディレクトリ（テストで差し替え可能）
    private let baseDirectory: URL
    /// ダウンロード用ストリーム情報の取得
    private let fetchStream: (String) async throws -> DownloadStream
    /// 実ファイルのダウンロード（進捗コールバック付き、一時ファイル URL を返す）
    private let downloadFile: (DownloadStream, @escaping @Sendable @MainActor (Double) -> Void) async throws -> URL

    init(baseDirectory: URL = DownloadManager.defaultBaseDirectory,
         fetchStream: @escaping (String) async throws -> DownloadStream = DownloadManager.liveFetchStream,
         downloadFile: @escaping (DownloadStream, @escaping @Sendable @MainActor (Double) -> Void) async throws -> URL = DownloadManager.liveDownloadFile) {
        self.baseDirectory = baseDirectory
        self.fetchStream = fetchStream
        self.downloadFile = downloadFile
    }

    // MARK: - 保存先

    /// Application Support/StrixDownloads
    nonisolated static var defaultBaseDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("StrixDownloads", isDirectory: true)
    }

    /// baseDirectory を用意して返す
    private func downloadsDirectory() -> URL {
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory
    }

    /// 保存済みファイル名から絶対 URL を解決する（オフライン再生用、shared の保存先基準）
    nonisolated static func localFileURL(fileName: String) -> URL {
        defaultBaseDirectory.appendingPathComponent(fileName)
    }

    // MARK: - 状態照会

    /// 指定動画がダウンロード中か
    func isDownloading(_ videoID: String) -> Bool { tasks[videoID] != nil }

    /// SwiftData から既存レコードを取得する
    static func record(for videoID: String, in modelContext: ModelContext) -> DownloadedVideo? {
        let targetID = videoID
        var descriptor = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.videoID == targetID }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - ダウンロード開始・キャンセル

    /// ダウンロードを開始する（既にダウンロード中・完了済みなら何もしない）
    func startDownload(video: VideoItem, modelContext: ModelContext) {
        let videoID = video.videoId
        guard tasks[videoID] == nil else { return }
        if let existing = Self.record(for: videoID, in: modelContext), existing.state == .completed { return }

        progress[videoID] = 0
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(video: video, modelContext: modelContext)
        }
        tasks[videoID] = task
    }

    /// ダウンロード済み・進行中いずれの動画も削除する。
    /// 進行中の場合はタスクを中断し、実際のレコード削除はタスクの中断ハンドラに委ねて二重削除を防ぐ。
    func delete(_ record: DownloadedVideo, modelContext: ModelContext) {
        let videoID = record.videoID
        if let task = tasks[videoID] {
            // 進行中: 中断すると runDownload の CancellationError ハンドラが removeRecordAndFiles を呼ぶ
            task.cancel()
            return
        }
        removeRecordAndFiles(record, modelContext: modelContext)
    }

    /// videoID 指定で削除する（進行中ダウンロードのキャンセル用）
    func cancelDownload(videoID: String, modelContext: ModelContext) {
        if let record = Self.record(for: videoID, in: modelContext) {
            delete(record, modelContext: modelContext)
        } else {
            tasks[videoID]?.cancel()
        }
    }

    /// レコードと関連ファイルを実際に削除する（削除経路を 1 本化するための内部ヘルパー）
    private func removeRecordAndFiles(_ record: DownloadedVideo, modelContext: ModelContext) {
        let dir = downloadsDirectory()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(record.fileName))
        if let thumb = record.thumbnailFileName {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(thumb))
        }
        modelContext.delete(record)
        try? modelContext.save()
    }

    // MARK: - ダウンロード本体

    /// ダウンロードを実行する（`startDownload` から Task で呼ばれる。テストからは直接 await 可能）
    func runDownload(video: VideoItem, modelContext: ModelContext) async {
        let videoID = video.videoId
        defer {
            tasks[videoID] = nil
            progress[videoID] = nil
        }

        // 進行中レコードを upsert
        let record: DownloadedVideo
        if let existing = Self.record(for: videoID, in: modelContext) {
            record = existing
        } else {
            record = DownloadedVideo(videoID: videoID, title: video.title,
                                     channelName: video.channelName,
                                     remoteThumbnailURL: video.thumbnailURL?.absoluteString ?? "",
                                     fileName: "\(videoID).mp4")
            modelContext.insert(record)
        }
        record.state = .downloading
        record.progress = 0
        try? modelContext.save()

        do {
            let stream = try await fetchStream(videoID)
            let fileName = "\(videoID).\(stream.fileExtension)"

            // メタ情報を最新化（context menu の VideoItem では欠けている場合がある）
            record.title = stream.title.isEmpty ? record.title : stream.title
            if let ch = stream.channelName { record.channelName = ch }
            if record.remoteThumbnailURL.isEmpty { record.remoteThumbnailURL = stream.thumbnailURL }
            record.fileName = fileName
            record.videoDuration = stream.lengthSeconds

            let tempURL = try await downloadFile(stream) { [weak self] p in
                self?.progress[videoID] = p
                record.progress = p
            }
            try Task.checkCancellation()

            // 保存先へ移動
            let dir = downloadsDirectory()
            let dest = dir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)

            // サムネイルもオフライン用に保存（失敗しても致命的ではない）
            if let thumbName = await Self.downloadThumbnail(from: stream.thumbnailURL, videoID: videoID, into: dir) {
                record.thumbnailFileName = thumbName
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            record.fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            record.progress = 1
            record.state = .completed
            record.downloadedAt = .now
            try? modelContext.save()
        } catch is CancellationError {
            removeRecordAndFiles(record, modelContext: modelContext)
        } catch {
            strixLog("ダウンロード失敗: \(error.localizedDescription)")
            record.state = .failed
            try? modelContext.save()
        }
    }

    // MARK: - Live 実装

    /// 本番のストリーム取得
    nonisolated static func liveFetchStream(_ videoID: String) async throws -> DownloadStream {
        try await YouTubeClient.fetchDownloadStream(videoID: videoID)
    }

    /// 本番のファイルダウンロード。googlevideo の open-ended GET はスロットリングされるため、
    /// Range リクエストでチャンク分割して取得し、一時ファイルに書き出す。
    nonisolated static func liveDownloadFile(_ stream: DownloadStream,
                                             progress: @escaping @Sendable @MainActor (Double) -> Void) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        let chunkSize: Int64 = 5_000_000
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)

        do {
            var offset: Int64 = 0
            var total: Int64 = -1
            while total < 0 || offset < total {
                try Task.checkCancellation()
                var request = URLRequest(url: stream.url)
                request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("bytes=\(offset)-\(offset + chunkSize - 1)", forHTTPHeaderField: "Range")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                if total < 0 {
                    if let range = http.value(forHTTPHeaderField: "Content-Range"),
                       let totalStr = range.components(separatedBy: "/").last, let t = Int64(totalStr) {
                        total = t
                    } else {
                        total = http.expectedContentLength
                    }
                }
                if data.isEmpty { break }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
                let fraction = total > 0 ? min(Double(offset) / Double(total), 1.0) : 0
                await progress(fraction)
                // サーバがチャンク上限より小さく返した（＝末尾）なら終了
                if Int64(data.count) < chunkSize { break }
            }
            try? handle.close()
            return tempURL
        } catch {
            // 中断・失敗時は書きかけの一時ファイルを残さない
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// サムネイルをダウンロードして保存する。保存できたらファイル名を返す。
    nonisolated private static func downloadThumbnail(from urlString: String, videoID: String, into dir: URL) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        let fileName = "\(videoID)_thumb.jpg"
        let dest = dir.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: dest)
            try data.write(to: dest)
            return fileName
        } catch {
            return nil
        }
    }
}
