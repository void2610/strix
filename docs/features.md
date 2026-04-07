# 機能一覧

## 基本機能（初期実装）

- 広告なし動画再生（YouTubeKit / Innertube）
- バックグラウンド再生
- PiP（ピクチャーインピクチャー）
- 動画検索・ホームフィード表示

---

## 追加機能（後から実装）

### 1. クイック再生プレイリスト

トップページ上部に、設定済みプレイリストをインスタグラムのストーリー風の丸いアイコンで横並び表示。タップ1回で即再生。

- プレイリスト登録・並び替えは設定画面から
- アイコンにはプレイリストのサムネを使用
- 長押しで削除・編集メニュー

### 2. 音声専用モード

動画ストリームを取得せず音声のみをストリーミングする省データ・省電力モード。

- 音声専用ボタンでトグル切り替え
- 音声品質を優先した bitrate 選択（128kbps / 256kbps）
- 画面オフ時に自動で音声専用に切り替えるオプション

### 3. おすすめ欄サムネ非表示

ホームのフィード・おすすめ欄でサムネイルを非表示にしてタイトルとチャンネル名のみ表示。

- 設定でオン/オフ切り替え
- 「見たいものだけ選ぶ」集中モードとして使用可能

### 4. Spotify 級のバックグラウンド復帰耐性

タスクキルや長時間放置後もイヤホンのメディアコントロールボタンで確実に復帰できる。

| 対策 | 詳細 |
|---|---|
| `AVAudioSession` 常時保持 | `.playback` カテゴリを維持し、セッションを手放さない |
| `MPRemoteCommandCenter` 登録 | play / pause / nextTrack コマンドを必ず登録 |
| `BGProcessingTask` / `BGAppRefreshTask` | バックグラウンドタスクを定期的にスケジュールし、プロセスを生かす |
| `NowPlayingInfo` 更新 | ロック画面・コントロールセンターの情報を常に最新に保つ |
| `UIApplication.beginBackgroundTask` | 一時的な処理中断に備えたバックグラウンド時間確保 |

```swift
try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
try AVAudioSession.sharedInstance().setActive(true)

MPRemoteCommandCenter.shared().playCommand.addTarget { _ in
    player.play(); return .success
}
MPRemoteCommandCenter.shared().pauseCommand.addTarget { _ in
    player.pause(); return .success
}
```

### 5. ホーム画面ウィジェット

WidgetKit を使ったホーム画面・ロック画面ウィジェット。

| サイズ | 内容 |
|---|---|
| Small | 再生中の曲名 + 再生/一時停止ボタン |
| Medium | 再生中情報 + 次の曲 + クイックプレイリスト 2〜3件 |
| Lock Screen（iOS 16+） | 再生中タイトル + コントロール |

- `WidgetKit` + `AppIntents`（iOS 17+ のインタラクティブウィジェット）
- `App Group` で本体アプリとデータ共有
- ウィジェットのボタンタップで `AppIntent` を通じて再生操作（アプリ起動不要）

```swift
struct PlayIntent: AppIntent {
    static var title: LocalizedStringResource = "再生"
    func perform() async throws -> some IntentResult {
        // PlayerClient 経由で再生
        return .result()
    }
}
```
