# 実装済み機能一覧

## コア機能

- **広告なし動画再生**: Innertube API 直接呼び出しによるストリーム取得
- **バックグラウンド再生**: `AVAudioSession(.playback)` + `UIBackgroundModes: audio`
- **PiP（ピクチャ・イン・ピクチャ）**: AVPlayerViewController subclass で実装
- **音声専用モード**: IOS クライアントの `adaptiveFormats` から音声ストリームのみ取得

## 検索・ブラウジング

- **ホームフィード**: Innertube `/browse` API（認証済み）
- **動画検索**: YouTubeKit `SearchResponse`
- **関連動画**: Innertube `/next` API
- **チャンネルページ**: ホーム・動画・ライブ・再生リストタブ

## プレイリスト

- **クイックアクセス**: ホーム画面上部にピン留めプレイリストを表示
- **プレイリスト再生**: 連続再生・ミックスリスト対応
- **プレイリスト編集**: `HomePlaylistEditView` でホーム表示プレイリストを選択

## アカウント

- **Google ログイン**: WKWebView（永続ストア）による Cookie 認証
- **ライブラリ表示**: 後で見る・高評価・自作プレイリスト一覧
- **視聴履歴**: SwiftData でローカル保存

## 再生コントロール

- **倍速再生**: UserDefaults に永続化（動画切り替え・アプリ再起動でも維持）
- **ループ再生**
- **共有ボタン**
- **動画説明パネル**
- **コントロールセンター**: `NowPlayingManager` でメタデータ・操作を表示

## Live Activity

- **ダイナミックアイランド**: 再生中の曲名・サムネ・進捗を表示
- **ロック画面バナー**: Live Activity として表示

## セキュリティ

- **ボット検出対策**: WebPage フォールバック + `BotVerifyView` で CAPTCHA 解決
- **3段フォールバック**: IOS → WEB → WebPage でストリーム取得の耐障害性を確保
