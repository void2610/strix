# アーキテクチャ

## 認証フロー

1. `LoginView` の WKWebView（`.default()` 永続ストア）で Google ログイン
2. YouTube セッション Cookie 取得
3. 必須 Cookie（SID/HSID/SSID）を `AuthClient` で検証後 Keychain 保存
4. デバイス信頼情報は `.default()` ストアで永続保持（再ログイン時 2FA 不要）
5. 起動時に `AuthState.shared.loadFromKeychain()` で復元

`AuthState`（`AuthClient.swift`）はアプリ全体で共有される `@Observable` シングルトン。

## API クライアント戦略

### コンテンツ取得（ContentClient）

Innertube WEB クライアント + Cookie + SAPISIDHASH 認証。

- **ホームフィード**: `/browse`（WEB client）を URLSession で直接呼ぶ
  - `httpShouldSetCookies = false` の ephemeral session でシステム Cookie 上書きを防止
- **検索**: YouTubeKit の `SearchResponse` を使用（唯一の YouTubeKit 依存）
- **関連動画**: `/next` API から lockupViewModel をパース
- **チャンネル**: `/browse` でチャンネルページ取得

認証ヘッダー: `Cookie` + `SAPISIDHASH`（`Authorization`）+ `X-Goog-AuthUser: 0`

### ストリーム取得（YouTubeClient）

3段フォールバック:
1. **IOS クライアント**（HLS） — `adaptiveFormats` から音声のみ/映像+音声を取得
2. **WEB クライアント**（combined formats）
3. **WebPage**（WKWebView で YouTube ページを読み込み `ytInitialPlayerResponse` を抽出）

### プレイリスト編集（ContentClient）

Innertube `/browse/edit_playlist` エンドポイントで以下の操作を実行：
- `addToPlaylist(playlistId:videoId:)` — 任意プレイリストへの動画追加（`ACTION_ADD_VIDEO`）
- `removeFromPlaylist(playlistId:videoId:setVideoId:)` — プレイリストからの動画削除（`ACTION_REMOVE_VIDEO`、`setVideoId` 必須）

### アカウント情報（AccountClient）

Innertube WEB client でライブラリ・プレイリスト一覧を取得。

## パーサー

| パーサー | 対象 | 関数 |
|---|---|---|
| lockupViewModel（WEB 新形式） | ホーム・関連動画 | `parseLockupViewModel` — チャンネル名/ID は `extractChannelInfo` で再帰探索 |
| videoRenderer（WEB 旧形式） | 検索結果等 | `parseVideoRenderer` |
| videoWithContextModel（IOS 形式） | IOS レスポンス | `parseVideoWithContextData` |
| プレイリスト | LOCKUP_CONTENT_TYPE_PLAYLIST/ALBUM | `parsePlaylistLockups` |
| ミックスリスト | `/next` の playlistPanelVideoRenderer | 専用パーサー |
| 画像 URL | プロトコル相対 URL 補正 | `imageURL(from:)` で `//` → `https:` |

## チャンネルアバター取得

取得元の優先順:
1. `/next` の `videoOwnerRenderer`
2. `/player` の endscreen
3. 関連動画の同一チャンネルから取得

## ボット検出対策

- WebPage フォールバック（WKWebView で YouTube ページを読み込み）
- `BotVerifyView` で手動 CAPTCHA 解決

## 永続化

| データ | 保存先 |
|---|---|
| 視聴履歴（`WatchedVideo`） | SwiftData |
| ホーム表示プレイリスト（`PinnedPlaylist`） | SwiftData |
| 認証 Cookie | Keychain |
| 再生速度設定 | UserDefaults |
| デバイス信頼情報 | WKWebsiteDataStore `.default()` |

## Live Activity / ダイナミックアイランド

- `StrixActivityAttributes`（`Utilities/`）: メインアプリと Widget Extension で共有される属性定義
- `LiveActivityManager`（`Utilities/`）: Activity の開始・更新・終了を制御
- `StrixWidgetExtension/`: ダイナミックアイランド・ロック画面の UI を実装
