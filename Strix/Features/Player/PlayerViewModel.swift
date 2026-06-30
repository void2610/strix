//
//  PlayerViewModel.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import AVFoundation
import SwiftData

@Observable
final class PlayerViewModel {
    var player: AVPlayer?
    var videoInfo: VideoInfo?
    var relatedVideos: [VideoItem] = []
    var isLoadingStream = true
    var isLoadingRelated = true
    var streamError: Error?
    /// YouTube のボット検出エラーかどうか
    var isBotDetected = false
    /// 現在の再生速度（1.0 または 2.0）。UserDefaults に永続化してアプリ全体で維持する。
    var playbackRate: Float = {
        let v = UserDefaults.standard.float(forKey: "playbackRate")
        return v.isZero ? 1.0 : v
    }() {
        didSet { UserDefaults.standard.set(playbackRate, forKey: "playbackRate") }
    }
    /// 音声のみモード（UserDefaults に永続化）
    var isAudioOnly: Bool = UserDefaults.standard.bool(forKey: "isAudioOnly") {
        didSet { UserDefaults.standard.set(isAudioOnly, forKey: "isAudioOnly") }
    }
    /// ループ再生が有効かどうか
    var isLooping = false
    /// 次動画を自動再生するかどうか
    var autoPlayNext = true
    /// auto-next 時に View がセットした次動画 ID（View の onChange で消費される）
    var autoNextVideoID: String?
    /// /next API から取得したチャンネルオーナーのアバター URL
    var ownerAvatarURL: URL?
    /// 動画の説明欄データ
    var videoDescription: String?
    var viewCountText: String?
    var publishDateText: String?
    /// コメント一覧
    var comments: [CommentItem] = []
    var isLoadingComments = true
    var commentsContinuation: String?
    var isLoadingMoreComments = false
    /// 返信スレッド（キー: 親コメント ID、値: 返信コメント配列）
    var replies: [String: [CommentItem]] = [:]
    /// 返信読み込み中の親コメント ID
    var loadingRepliesFor: Set<String> = []
    /// 展開中の返信スレッドの親コメント ID
    var expandedReplies: Set<String> = []
    /// 返信の次ページ continuation（キー: 親コメント ID）
    var repliesContinuation: [String: String] = [:]
    /// 現在ロード済みの動画 ID（View の .task(id:) による二重ロードを防ぐ）
    private(set) var loadedVideoID: String?

    // MARK: - プレイリスト再生モード
    /// プレイリストの動画リスト（セット済みなら関連動画ではなくこのリスト順に再生する）
    var playlistQueue: [VideoItem] = []
    /// 現在再生中のプレイリスト内インデックス
    var playlistIndex: Int = 0

    /// 現在ロード済みの動画を VideoItem として返す（手動キューの種化用）
    var currentVideoItem: VideoItem? {
        guard let id = loadedVideoID, let info = videoInfo else { return nil }
        return VideoItem(videoId: id, title: info.title, channelId: info.channelId,
                         channelName: info.channelName, thumbnailURL: URL(string: info.thumbnailURL),
                         channelAvatarURL: info.channelAvatarURL)
    }

    private let youtubeClient: YouTubeClient
    private let contentClient: ContentClient
    /// rate 変更監視トークン（再生再開時に playbackRate を復元するため）
    private var rateObserver: Any?
    /// 動画終端監視トークン（ループ・自動再生で使用）
    private var endObserver: Any?
    /// 再生位置の定期監視トークン（バックアップの終端検出用）
    private var timeObserver: Any?
    /// YouTube に視聴履歴を報告するトラッカー
    private let playbackTracker = PlaybackTracker()

    init(youtubeClient: YouTubeClient = .live, contentClient: ContentClient = .live) {
        self.youtubeClient = youtubeClient
        self.contentClient = contentClient
    }

    func load(videoID: String, modelContext: ModelContext) async {
        // 前の動画の再生位置を保存してから切り替える
        savePlaybackPosition(modelContext: modelContext)
        // 再ロード時: 前のプレイヤーを停止して状態をリセットする
        loadedVideoID = videoID
        if let obs = rateObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = timeObserver, let p = player { p.removeTimeObserver(obs) }
        rateObserver = nil
        endObserver = nil
        timeObserver = nil
        autoNextVideoID = nil
        playbackTracker.stop()
        player?.pause()
        player = nil
        videoInfo = nil
        relatedVideos = []
        ownerAvatarURL = nil
        videoDescription = nil
        viewCountText = nil
        publishDateText = nil
        comments = []
        isLoadingComments = true
        commentsContinuation = nil
        isLoadingMoreComments = false
        isLoadingStream = true
        isLoadingRelated = true
        streamError = nil
        isBotDetected = false

        // ストリームと関連動画とコメントを並列取得
        async let streamTask: Void = loadStream(videoID: videoID, modelContext: modelContext)
        async let relatedTask: Void = loadRelated(videoID: videoID)
        async let commentsTask: Void = loadComments(videoID: videoID)
        _ = await (streamTask, relatedTask, commentsTask)
    }

    private func loadStream(videoID: String, modelContext: ModelContext) async {
        do {
            let info = try await youtubeClient.fetchVideo(videoID)
            videoInfo = info
            let avPlayer = AVPlayer(playerItem: makePlayerItem(info: info, audioOnly: isAudioOnly))
            StreamResourceLoader.attachPlayer(avPlayer, to: avPlayer.currentItem)
            player = avPlayer
            // PiP コントロールで再生再開すると rate が 1.0 に戻るため、
            // rateDidChangeNotification で監視して playbackRate を復元する
            rateObserver = NotificationCenter.default.addObserver(
                forName: AVPlayer.rateDidChangeNotification,
                object: avPlayer,
                queue: .main
            ) { [weak self] _ in
                guard let self, let p = self.player, p.rate > 0 else { return }
                if p.rate != self.playbackRate {
                    p.rate = self.playbackRate
                }
            }
            // 動画終端: ループ or 次動画自動再生（通知ベース）
            registerEndObserver(for: avPlayer)
            // バックアップ: 再生位置の定期監視で終端を検出（通知が来ない場合の保険）
            let interval = CMTime(seconds: 1, preferredTimescale: 1)
            timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self, let item = self.player?.currentItem else { return }
                let duration = item.duration
                guard duration.isNumeric, duration.seconds > 0 else { return }
                let remaining = duration.seconds - time.seconds
                if remaining < 0.5, self.player?.rate == 0, self.player?.currentItem?.status == .readyToPlay {
                    self.handlePlaybackEnded()
                }
            }
            avPlayer.play()
            if playbackRate != 1.0 {
                avPlayer.rate = playbackRate
            }
            resumeIfNeeded(modelContext: modelContext)
            isLoadingStream = false
            NowPlayingManager.shared.start(
                player: avPlayer,
                title: info.title,
                thumbnailURL: info.thumbnailURL
            )
            LiveActivityManager.shared.start(
                title: info.title,
                channelName: "",
                thumbnailURL: info.thumbnailURL,
                player: avPlayer
            )
            playbackTracker.start(player: avPlayer, trackingURLs: info.playbackTrackingURLs)
            saveToHistory(videoID: videoID, info: info, modelContext: modelContext)
        } catch {
            streamError = error
            let desc = error.localizedDescription.lowercased()
            isBotDetected = desc.contains("bot") || desc.contains("ログイン") || desc.contains("sign in")
            isLoadingStream = false
        }
    }

    private func loadRelated(videoID: String) async {
        do {
            let result = try await contentClient.fetchRelated(videoID)
            relatedVideos = result.videos
            ownerAvatarURL = result.ownerAvatarURL
            videoDescription = result.description
            viewCountText = result.viewCount
            publishDateText = result.publishDate
        } catch {
            strixLog("関連動画取得エラー: \(error.localizedDescription)")
        }
        isLoadingRelated = false
    }

    private func loadComments(videoID: String) async {
        do {
            let result = try await contentClient.fetchComments(videoID)
            comments = result.comments
            commentsContinuation = result.continuation
        } catch {
            strixLog("コメント取得エラー: \(error.localizedDescription)")
        }
        isLoadingComments = false
    }

    /// コメントの次ページを読み込む
    func loadMoreComments() async {
        guard let token = commentsContinuation, !isLoadingMoreComments else { return }
        isLoadingMoreComments = true
        do {
            let result = try await contentClient.fetchCommentsPage(token)
            comments.append(contentsOf: result.comments)
            commentsContinuation = result.continuation
        } catch {
            strixLog("コメント次ページ取得エラー: \(error.localizedDescription)")
        }
        isLoadingMoreComments = false
    }

    /// 返信スレッドを展開/折りたたみする
    func toggleReplies(for comment: CommentItem) async {
        if expandedReplies.contains(comment.id) {
            expandedReplies.remove(comment.id)
            return
        }
        expandedReplies.insert(comment.id)
        // まだ読み込んでいなければ取得する
        if replies[comment.id] == nil {
            await loadReplies(for: comment)
        }
    }

    /// 返信を読み込む
    private func loadReplies(for comment: CommentItem) async {
        guard let token = comment.repliesContinuation else { return }
        loadingRepliesFor.insert(comment.id)
        do {
            let result = try await ContentClient.fetchReplies(continuation: token)
            replies[comment.id] = result.comments
            repliesContinuation[comment.id] = result.continuation
        } catch {
            strixLog("返信取得エラー: \(error.localizedDescription)")
        }
        loadingRepliesFor.remove(comment.id)
    }

    /// 返信の次ページを読み込む
    func loadMoreReplies(for commentId: String) async {
        guard let token = repliesContinuation[commentId],
              !loadingRepliesFor.contains(commentId) else { return }
        loadingRepliesFor.insert(commentId)
        do {
            let result = try await ContentClient.fetchReplies(continuation: token)
            replies[commentId, default: []].append(contentsOf: result.comments)
            repliesContinuation[commentId] = result.continuation
        } catch {
            strixLog("返信次ページ取得エラー: \(error.localizedDescription)")
        }
        loadingRepliesFor.remove(commentId)
    }

    /// 再生速度を 1.0 → 2.0 → 1.0 の順に切り替える
    func togglePlaybackRate() {
        playbackRate = (playbackRate == 1.0) ? 2.0 : 1.0
        player?.rate = playbackRate
    }

    /// 任意の再生速度を適用する（倍速メニュー用）
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if player?.rate ?? 0 > 0 {
            player?.rate = rate
        }
    }

    /// 現在位置から指定秒数だけ進める（正で前進、負で後退）
    func skip(by seconds: Double) {
        guard let player, let item = player.currentItem else { return }
        let now = player.currentTime().seconds
        let maxTime: Double = item.duration.isNumeric ? item.duration.seconds : .infinity
        let target = max(0, min(now + seconds, maxTime))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// ループ再生のオン/オフを切り替える
    func toggleLoop() {
        isLooping.toggle()
    }

    /// 次動画自動再生のオン/オフを切り替える
    func toggleAutoPlayNext() {
        autoPlayNext.toggle()
    }

    /// 通常モード ↔ 音声のみモードを切り替える。
    /// プレイヤーを作り直すと NowPlaying・トラッカー・各 observer が古いインスタンスを
    /// 参照したまま旧ストリームが流れ続ける（二重再生・通信量増）ため、
    /// 同じ AVPlayer のままアイテムだけ差し替える。
    func toggleAudioOnly() {
        guard let info = videoInfo, let player else { return }
        isAudioOnly.toggle()
        let currentTime = player.currentTime()
        let wasPlaying = player.rate != 0

        player.replaceCurrentItem(with: makePlayerItem(info: info, audioOnly: isAudioOnly))
        StreamResourceLoader.attachPlayer(player, to: player.currentItem)
        // 終端監視はアイテム単位のため貼り直す
        registerEndObserver(for: player)
        if currentTime.isValid {
            player.seek(to: currentTime)
        }
        if wasPlaying {
            player.play()
            if playbackRate != 1.0 { player.rate = playbackRate }
        }
    }

    /// 再生モードに応じた AVPlayerItem を作る。
    /// 音声のみモードで音声 URL が取得できなかった場合も動画をそのまま流さず、
    /// ビットレート上限を掛けて HLS の最低画質を選ばせることで通信量を抑える。
    func makePlayerItem(info: VideoInfo, audioOnly: Bool) -> AVPlayerItem {
        if audioOnly {
            if let audioURL = info.audioOnlyURL {
                // adaptive 音声は open-ended Range だとスロットリングされるため区切り付きで取得する
                let asset = StreamResourceLoader.makeAsset(realURL: audioURL, userAgent: YouTubeConstants.androidVrUserAgent)
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 60
                return item
            }
            let item = AVPlayerItem(url: info.streamURL)
            item.preferredPeakBitRate = 300_000
            return item
        }
        // HLS（マニフェスト）はネイティブにオンデマンド再生されるためそのまま。
        // progressive な直 URL は全体先読みされるため ResourceLoader でページングする。
        let s = info.streamURL.absoluteString
        if s.contains("manifest") || s.contains(".m3u8") {
            return AVPlayerItem(url: info.streamURL)
        }
        let asset = StreamResourceLoader.makeAsset(realURL: info.streamURL, userAgent: YouTubeConstants.androidVrUserAgent)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 60
        return item
    }

    /// 動画終端通知の監視を登録する（AVPlayerItem 単位のため、アイテム差し替え時に貼り直す）
    private func registerEndObserver(for player: AVPlayer) {
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnded()
        }
    }

    /// 再生終了時の処理（通知 + 定期監視の両方から呼ばれるため二重発火を防止）
    private func handlePlaybackEnded() {
        guard autoNextVideoID == nil else { return }
        let hideRelated = UserDefaults.standard.bool(forKey: "disableRecommendations")
        if isLooping {
            player?.seek(to: .zero)
            player?.play()
        } else if !playlistQueue.isEmpty {
            let nextIndex = playlistIndex + 1
            if nextIndex < playlistQueue.count {
                playlistIndex = nextIndex
                autoNextVideoID = playlistQueue[nextIndex].videoId
            } else if autoPlayNext, !hideRelated, let next = relatedVideos.first {
                autoNextVideoID = next.videoId
            }
        } else if autoPlayNext, !hideRelated, let next = relatedVideos.first {
            autoNextVideoID = next.videoId
        }
    }

    /// プレイリスト内の前のトラックへ戻る
    func playPrevious() {
        guard !playlistQueue.isEmpty, playlistIndex > 0 else { return }
        playlistIndex -= 1
        autoNextVideoID = playlistQueue[playlistIndex].videoId
    }

    /// プレイリスト内の次のトラックへ進む
    func playNext() {
        guard !playlistQueue.isEmpty, playlistIndex + 1 < playlistQueue.count else { return }
        playlistIndex += 1
        autoNextVideoID = playlistQueue[playlistIndex].videoId
    }

    /// 現在の再生位置を SwiftData に保存する
    func savePlaybackPosition(modelContext: ModelContext) {
        guard let videoID = loadedVideoID,
              let player,
              let item = player.currentItem,
              item.duration.isNumeric else { return }
        let position = player.currentTime().seconds
        let duration = item.duration.seconds
        guard position.isFinite, duration.isFinite else { return }

        let targetID = videoID
        var descriptor = FetchDescriptor<WatchedVideo>(
            predicate: #Predicate { $0.videoID == targetID }
        )
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first else { return }
        record.playbackPosition = position
        record.videoDuration = duration
    }

    /// 保存済みの再生位置があればシークして復帰する
    func resumeIfNeeded(modelContext: ModelContext) {
        guard let videoID = loadedVideoID else { return }
        let targetID = videoID
        var descriptor = FetchDescriptor<WatchedVideo>(
            predicate: #Predicate { $0.videoID == targetID }
        )
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first,
              record.playbackPosition > 5,
              record.videoDuration > 0 else { return }

        let ratio = record.playbackPosition / record.videoDuration
        let remaining = record.videoDuration - record.playbackPosition
        if ratio >= 0.95 || remaining < 10 { return }

        let target = CMTime(seconds: record.playbackPosition, preferredTimescale: 600)
        player?.seek(to: target)
    }

    /// 視聴履歴を保存する（既存レコードがあれば更新、なければ挿入）
    private func saveToHistory(videoID: String, info: VideoInfo, modelContext: ModelContext) {
        let targetID = videoID
        var descriptor = FetchDescriptor<WatchedVideo>(
            predicate: #Predicate { $0.videoID == targetID }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.watchedAt = .now
            existing.title = info.title
            existing.thumbnailURL = info.thumbnailURL
        } else {
            let video = WatchedVideo(
                videoID: videoID,
                title: info.title,
                thumbnailURL: info.thumbnailURL
            )
            modelContext.insert(video)
        }
    }
}
