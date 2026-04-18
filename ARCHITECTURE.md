# Strix アーキテクチャドキュメント

## 目次

1. [プロジェクト概要](#1-プロジェクト概要)
2. [ディレクトリ構成](#2-ディレクトリ構成)
3. [データモデル](#3-データモデル)
4. [クライアント層（Clients）](#4-クライアント層)
5. [機能層（Features）](#5-機能層)
6. [ユーティリティ（Utilities）](#6-ユーティリティ)
7. [Widget Extension](#7-widget-extension)
8. [ナビゲーション構造](#8-ナビゲーション構造)
9. [認証フロー](#9-認証フロー)
10. [データフロー](#10-データフロー)

---

## 1. プロジェクト概要

iOS向け広告なし YouTube クライアント。

| 項目 | 内容 |
|------|------|
| ターゲット | iOS 26.2+ |
| 言語 | Swift 6（strict concurrency 有効） |
| UI フレームワーク | SwiftUI |
| アーキテクチャ | MVVM（`@Observable` ViewModel） |
| 主要ライブラリ | YouTubeKit 1.3.0、Nuke/NukeUI 12.9.0 |
| データ永続化 | SwiftData（視聴履歴）、Keychain（認証クッキー） |

### エントリーポイント（StrixApp.swift）

アプリ起動時に以下を実行する：

1. `AVAudioSession.sharedInstance().setCategory(.playback)` — バックグラウンド再生・消音モード無視
2. `AuthState.shared.loadFromKeychain()` — Keychain から保存済みクッキーを復元
3. `ModelContainer` の初期化 — SwiftData スキーマ（`WatchedVideo`）の設定

---

## 2. ディレクトリ構成

```
Strix/
├── StrixApp.swift                    # エントリーポイント
├── Models/
│   ├── VideoItem.swift               # 共通軽量動画モデル（+ YTVideo変換拡張）
│   └── WatchedVideo.swift            # SwiftData モデル（視聴履歴）
├── Clients/
│   ├── AuthClient.swift              # 認証状態・Keychain 管理
│   ├── YouTubeClient.swift           # ストリーム URL 取得（Innertube /player）
│   ├── ContentClient.swift           # ホーム/検索/関連動画（YouTubeKit + WKWebView）
│   └── AccountClient.swift           # アカウント情報・ライブラリ・履歴・プレイリスト
├── Features/
│   ├── RootTabView.swift             # タブバー（ホーム・検索・アカウント）
│   ├── Home/
│   │   └── HomeView.swift            # ホームフィード・URL入力・視聴履歴
│   ├── Search/
│   │   └── SearchView.swift          # キーワード検索・結果表示
│   ├── Player/
│   │   ├── PlayerView.swift          # 動画再生・関連動画・速度切り替え
│   │   ├── PlayerCoordinator.swift   # アプリ全体のプレイヤー状態管理（@Observable）
│   │   ├── PlayerContainerView.swift # フルスクリーン/ミニプレイヤーのオーバーレイ管理
│   │   └── MiniPlayerBar.swift       # ミニプレイヤー（AVPlayerLayer 小窓映像）
│   ├── Auth/
│   │   ├── AccountView.swift         # アカウント情報・ライブラリ・プレイリスト
│   │   ├── LoginView.swift           # Google/YouTube ログイン（WKWebView）
│   │   ├── LogView.swift             # デバッグログビューア
│   │   ├── HistoryView.swift         # YouTube 視聴履歴（日付グループ）
│   │   └── PlaylistDetailView.swift  # プレイリスト動画一覧
│   └── Components/
│       ├── VideoCardView.swift       # VideoCardView / VideoRowView 共通コンポーネント
│       └── AddToPlaylistMenu.swift   # コンテキストメニュー用プレイリスト追加サブメニュー
└── Utilities/
    ├── AppLogger.swift               # アプリ内ログシステム
    ├── VideoID.swift                 # YouTube URL/動画 ID パーサー
    ├── NowPlayingManager.swift       # コントロールセンター・ロック画面 Now Playing
    ├── LiveActivityManager.swift     # ダイナミックアイランド Live Activity
    └── StrixActivityAttributes.swift # Live Activity 属性定義（アプリ・Widget 共有）

StrixWidgetExtension/
└── StrixLiveActivity.swift           # ダイナミックアイランド・ロック画面 UI
```

---

## 3. データモデル

### 3.1 VideoItem — 共通軽量動画モデル

各 Feature 間でデータを受け渡す共通構造体。YouTubeKit の `YTVideo` と Innertube 直叩きレスポンスの両方をここに統一する。

```swift
struct VideoItem: Identifiable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let channelName: String?
    let thumbnailURL: URL?
    let channelAvatarURL: URL?
    let viewCountText: String?
    let timePostedText: String?
    let feedbackTokens: [String]   // フィードバック用トークン
    let setVideoId: String?        // プレイリストエントリ固有ID（削除用）
}
```

YouTubeKit の `YTVideo` から変換する拡張は `VideoItem.swift` に定義：

```swift
extension YTVideo {
    var toVideoItem: VideoItem { ... }
}
```

---

### 3.2 WatchedVideo — 視聴履歴（SwiftData）

再生した動画を端末に永続化するモデル。

```swift
@Model
final class WatchedVideo {
    var videoID: String
    var title: String
    var thumbnailURL: String
    var watchedAt: Date
}
```

**書き込み（PlayerView）:** 再生開始時に `modelContext.insert()` で記録する。

**読み込み（HomeView）:** `@Query(sort: \WatchedVideo.watchedAt, order: .reverse)` で最新10件を取得してサムネイル一覧表示する。

---

## 4. クライアント層

クライアントはすべてクロージャベースの構造体 DI パターンを採用している。テスト時は `mock()` で差し替え、本番は `.live` を使用する。

### 4.1 AuthClient — 認証状態管理

```
AuthClient.swift
├── AuthState（@Observable シングルトン）
│   ├── cookieString: String?          YouTube セッションクッキー文字列
│   ├── dataStore: WKWebsiteDataStore? ログイン時の WKWebsiteDataStore（メモリのみ）
│   ├── isSignedIn: Bool               cookieString != nil
│   ├── save(cookies:dataStore:)       クッキーを Keychain + メモリに保存
│   ├── loadFromKeychain()             起動時に Keychain から復元
│   └── signOut()                      全クッキーを削除
└── KeychainHelper
    ├── save(key:value:)               kSecClassGenericPassword でデータ保存
    ├── load(key:)                     Keychain から文字列を取得
    └── delete(key:)                   Keychain からエントリを削除
```

---

### 4.2 YouTubeClient — ストリーム URL 取得

```swift
struct YouTubeClient {
    var fetchVideo: (String) async throws -> VideoInfo
}

struct VideoInfo {
    let streamURL: URL        // HLS manifest URL（.m3u8）
    let title: String
    let thumbnailURL: String
}
```

**3段フォールバック:**

1. **IOS クライアント** — HLS manifest URL を取得。Cookie + SAPISIDHASH 認証
2. **WEB クライアント** — combined formats / HLS を取得。Cookie + SAPISIDHASH 認証
3. **WebPage（WKWebView）** — モバイル版 YouTube を読み込み、JS で再生を開始。`fetch()` / `XMLHttpRequest.open()` をフックして `googlevideo.com/videoplayback` への署名デコード済み URL をインターセプト。combined format（itag 18/22）を優先選択

**エラー種別:**
```swift
enum YouTubeClientError: LocalizedError {
    case streamNotFound        // hlsManifestUrl が存在しない
    case notPlayable(String)   // playabilityStatus.reason（地域制限等）
    case networkError(Error)
}
```

---

### 4.3 ContentClient — ホーム/検索/関連動画

```swift
struct ContentClient {
    var fetchHome: () async throws -> [VideoItem]
    var search: (String) async throws -> [VideoItem]
    var fetchRelated: (String) async throws -> [VideoItem]
}
```

#### ホームフィード取得フロー

```
fetchHome()
├── ログイン済み
│   ├── [1] browseHome(cookies:) — WKWebView で youtube.com を読み込み
│   │       ytInitialData を JS で取得 → videoRenderer をパース
│   │       （タイムアウト: 30秒）
│   ├── 失敗時 → [2] YouTubeKit HomeScreenResponse（cookies 付き）
│   └── 両方失敗 → 空配列を返す（trending で偽装しない）
└── 未ログイン
    ├── [1] YouTubeKit HomeScreenResponse（cookies=""）
    └── 失敗時 → [2] SearchResponse("trending music 2025")
```

#### WKWebView ベースのホームフィード取得（browseHome）

ログイン済みセッションで youtube.com を読み込み、JavaScript で `window.ytInitialData` を取得する。

```
browseHome(cookies:)
├── AuthState.shared.dataStore が存在する（同一セッション）
│   └── そのまま使用（クッキー自動付与）
└── dataStore が nil（アプリ再起動後）
    └── makeDataStore(from: cookieString) でクッキーを注入した非永続ストアを作成
         └── __Host-/セキュリティ属性を考慮してドメインを設定

YouTubeWebLoader.load(dataStore:)
├── WKWebView(configuration: cfg) を生成
├── https://www.youtube.com/?hl=ja&gl=JP を読み込む
├── didFinish: evaluateJavaScript("JSON.stringify(window.ytInitialData || null)")
└── パース: findVideoRenderers(in:) → parseVideoRenderer(_:)
```

#### videoRenderer の JSON パース対応

**旧形式（videoRenderer / compactVideoRenderer）:**
```json
{
  "videoRenderer": {
    "videoId": "...",
    "title": { "runs": [{"text": "タイトル"}] },
    "ownerText": { "runs": [{"text": "チャンネル名"}] },
    "thumbnail": { "thumbnails": [{"url": "..."}] }
  }
}
```

**新形式（elementRenderer → videoWithContextModel）:**
```json
{
  "elementRenderer": {
    "newElement": {
      "type": {
        "componentType": {
          "model": {
            "videoWithContextModel": {
              "videoWithContextData": {
                "onTap": { "innertubeCommand": { "watchEndpoint": { "videoId": "..." } } },
                "videoData": {
                  "metadata": { "title": "..." },
                  "thumbnail": { "image": { "sources": [{"url": "..."}] } }
                }
              }
            }
          }
        }
      }
    }
  }
}
```

#### 検索・関連動画

```
search(query:)
└── YouTubeKit SearchResponse（cookies 付き）

fetchRelated(videoID:)
└── YouTubeKit MoreVideoInfosResponse（data: [.query: videoID]）
```

---

### 4.4 AccountClient — アカウント・ライブラリ

```swift
struct AccountClient {
    var fetchInfo: () async throws -> AccountInfosResponse
    var fetchLibrary: () async throws -> AccountLibraryResponse
    var fetchHistory: () async throws -> HistoryResponse
    var fetchPlaylistVideos: (_ playlistId: String) async throws -> [VideoItem]
}
```

| メソッド | YouTubeKit API | 取得内容 |
|---------|---------------|---------|
| `fetchInfo` | `AccountInfosResponse` | 名前・チャンネルハンドル・アバター |
| `fetchLibrary` | `AccountLibraryResponse` | watchLater・likes・playlists[] |
| `fetchHistory` | `HistoryResponse` | 日付グループ別の視聴履歴 |
| `fetchPlaylistVideos` | `PlaylistInfosResponse` | プレイリスト内動画一覧 |

すべてのリクエストで `model.cookies = AuthState.shared.cookieString` を付与する。

---

## 5. 機能層（Features）

### 5.1 RootTabView

```swift
TabView {
    Tab("ホーム",  systemImage: "house.fill")      { HomeView() }
    Tab("検索",    systemImage: "magnifyingglass")  { SearchView() }
    Tab("アカウント", systemImage: "person.crop.circle") { AccountView() }
}
```

---

### 5.2 HomeView — ホームフィード

**HomeViewModel:**

```swift
@Observable
final class HomeViewModel {
    var videos: [VideoItem] = []
    var isLoading = false
    var error: String?

    func load() async    // 初回ロード（videos.isEmpty のときのみ）
    func reload() async  // 強制リロード（videos = [] から開始）
}
```

**HomeView のレイアウト（上から）:**

1. **URL 入力セクション:** TextField + 再生ボタン。`extractVideoID(from:)` で URL/ID をパースして `path.append(videoID)`
2. **視聴履歴セクション:** `@Query` で最新10件を横スクロール表示（`HistoryThumbnailView`）
3. **ホームフィード:** `VideoCardView` の `LazyVStack`
4. `refreshable` 修飾子で pull-to-refresh 対応

**ログイン状態変化への追従:**

```swift
.task(id: AuthState.shared.isSignedIn) {
    // isSignedIn が変化するたびにリロード
    // ログイン・ログアウト・初回起動すべてに対応
    await vm.reload()
}
```

---

### 5.3 SearchView — キーワード検索

**SearchViewModel:**

```swift
@Observable
final class SearchViewModel {
    var results: [VideoItem] = []
    var isLoading = false
    var error: String?
    var lastQuery = ""   // 重複検索防止

    func search(_ query: String) async  // 前回と同じクエリなら無視
    func reset() async
}
```

**SearchView の状態分岐:**

| 状態 | 表示 |
|------|------|
| `isLoading == true` | `ProgressView` |
| `error != nil` | `ContentUnavailableView` |
| 検索済みで `results.isEmpty` | `ContentUnavailableView(.search)` |
| 未検索 | "キーワードを入力してください" |
| 結果あり | `VideoRowView` の `List` |

---

### 5.4 PlayerView — 動画再生

**PlayerViewModel:**

```swift
@Observable
final class PlayerViewModel {
    var player: AVPlayer?
    var videoInfo: VideoInfo?
    var relatedVideos: [VideoItem] = []
    var isLoadingStream = true
    var isLoadingRelated = true
    var streamError: Error?
    var playbackRate: Float = 1.0

    func load(videoID:modelContext:) async  // ストリームと関連動画を並列取得
    func togglePlaybackRate()               // 1.0 ↔ 2.0 切り替え
}
```

**並列取得:**

```swift
async let streamTask: Void = loadStream(videoID:modelContext:)
async let relatedTask: Void = loadRelated(videoID:)
_ = await (streamTask, relatedTask)
```

**PlayerView のレイアウト（上から）:**

1. **プレイヤーセクション:** `VideoPlayer(player:)` + 右上オーバーレイ（速度ボタン）
   - 16:9 アスペクト比（`Color.black.aspectRatio(16/9, contentMode: .fit)`）
   - 読み込み中: `ProgressView`
   - エラー: `ContentUnavailableView`
2. **タイトル・メタ情報:** ストリーム読み込み中はスケルトン
3. **関連動画:** `LazyVStack` の `VideoRowView`

**速度切り替えボタン（SpeedToggleButton）:**

```
[1×] ← タップ → [2×] ← タップ → [1×] ...
```

プレイヤー右上に半透明カプセル型で表示。タップごとに `AVPlayer.rate` を変更する。

**再生開始時の副作用:**

```swift
NowPlayingManager.shared.start(player:title:thumbnailURL:)
LiveActivityManager.shared.start(title:channelName:thumbnailURL:player:)
saveToHistory(videoID:info:modelContext:)
```

**画面離脱時（onDisappear）:**

```swift
vm.player?.pause()
NowPlayingManager.shared.stop()
LiveActivityManager.shared.stop()
```

---

### 5.5 AccountView — アカウント・ライブラリ

**AccountViewModel:**

```swift
@Observable
final class AccountViewModel {
    var accountInfo: AccountInfosResponse?
    var library: AccountLibraryResponse?
    var isLoading = true

    func load() async  // fetchInfo + fetchLibrary を並列取得
}
```

**ログイン済み時のレイアウト（List セクション）:**

```
┌──────────────────────────────┐
│ [アバター]  アカウント名      │  ← AccountInfosResponse
│             @channelhandle   │
├──────────────────────────────┤
│ ライブラリ                   │
│   時計  視聴履歴           → │  ← HistoryView へ遷移
│   栞    後で見る     (N本) → │  ← PlaylistDetailView(watchLater)
│   👍    いいねした動画 (N本) →│  ← PlaylistDetailView(likes)
├──────────────────────────────┤
│ プレイリスト                 │
│   [サムネ] プレイリスト名  → │  ← PlaylistDetailView(playlist)
│   ...                        │
├──────────────────────────────┤
│ [ログアウト]                 │
│ デバッグ: デバッグログ       │
└──────────────────────────────┘
```

未ログイン時: アイコン + 説明文 + "Googleでログイン" ボタン（`LoginView` Sheet を表示）

---

### 5.6 LoginView — Google ログイン

`WKWebView` で Google/YouTube の認証フローを実行する。

```
WKWebsiteDataStore.nonPersistent()  ← 非永続ストア（アプリ独自セッション）
    ↓
WKWebView.load("https://accounts.google.com/ServiceLogin?service=youtube")
    ↓
ユーザーが Google アカウントでログイン
    ↓
Coordinator.webView(_:didFinish:)
├── URL に "youtube.com" を含む → ログイン完了と判定
├── HTTPCookieStore.getAllCookies()
│   └── youtube.com / google.com のクッキーを抽出
│       → "name1=value1; name2=value2; ..." の文字列を生成
└── AuthState.shared.save(cookies:dataStore:)
    ├── Keychain に "yt_cookies" として保存
    └── dataStore を AuthState に保持（次回 browseHome で再利用）
```

---

### 5.7 HistoryView — 視聴履歴

YouTube のサーバーサイド視聴履歴（ログイン必須）。SwiftData の視聴履歴とは別物。

```swift
@Observable
final class HistoryViewModel {
    var blocks: [HistoryResponse.HistoryBlock] = []  // 日付グループのリスト
    var isLoading = true
    var error: Error?

    func load() async  // AccountClient.fetchHistory()
}
```

`HistoryBlock` の構造：

```swift
struct HistoryBlock {
    let groupTitle: String        // "今日" / "昨日" / "先週" 等
    var videosArray: [VideoWithToken]
}
```

表示: `List` の `Section` でグループタイトルを使い、各動画を `VideoRowView` で表示する。

---

### 5.8 PlaylistDetailView — プレイリスト動画一覧

後で見る・いいね・ユーザー作成プレイリストを共通で表示する。

```swift
@Observable
final class PlaylistDetailViewModel {
    var videos: [VideoItem] = []
    var isLoading = true
    var error: Error?

    func load(playlistId: String) async  // AccountClient.fetchPlaylistVideos(playlistId)
}
```

`YTPlaylist` を受け取り、`playlist.playlistId` でコンテンツを取得する。

**コンテキストメニュー:** 各動画を長押しすると以下の操作が可能：
- **プレイリストから削除**: `ContentClient.removeFromPlaylist()` で Innertube `edit_playlist` API（`ACTION_REMOVE_VIDEO`）を呼び出す。`setVideoId` が必要。
- **プレイリストに追加**: `AddToPlaylistMenu` サブメニューからアカウント内の任意プレイリストに追加。

---

### 5.9 AddToPlaylistMenu — プレイリスト追加サブメニュー

コンテキストメニュー内に配置するサブメニューコンポーネント。`PlaylistMenuState`（シングルトン）がアカウントのプレイリスト一覧を60秒キャッシュで保持する。

```swift
AddToPlaylistMenu(videoId: video.videoId)
```

ホームフィード・関連動画・プレイリスト詳細の全コンテキストメニューで使用。

---

### 5.10 共通コンポーネント（VideoCardView.swift）

#### VideoCardView（ホームフィード用）

```
┌──────────────────────────────┐
│                              │  ← サムネイル（16:9、LazyImage）
│                              │
└──────────────────────────────┘
[アバター] タイトル（2行）
           チャンネル名 • 視聴回数 • 投稿日時
```

#### VideoRowView（検索/プレイリスト/関連動画用）

```
[サムネイル 160×90]  タイトル（2行）
                     チャンネル名
                     視聴回数 • 投稿日時
```

---

## 6. ユーティリティ

### 6.1 AppLogger — アプリ内ログシステム

```swift
@Observable
final class AppLogger {
    static let shared = AppLogger()
    private(set) var entries: [Entry] = []  // 最大500件

    func append(_ message: String)
    func clear()
}

func strixLog(_ message: String) {
    print("[Strix] \(message)")
    Task { @MainActor in AppLogger.shared.append(message) }
}
```

`LogView` でリアルタイム表示・クリア・全コピーが可能。

---

### 6.2 VideoID — YouTube URL パーサー

```swift
func extractVideoID(from input: String) -> String?
```

対応フォーマット:

| 入力形式 | 例 |
|---------|-----|
| 動画 ID 直接入力 | `dQw4w9WgXcQ` |
| 通常 URL | `https://www.youtube.com/watch?v=dQw4w9WgXcQ` |
| 短縮 URL | `https://youtu.be/dQw4w9WgXcQ` |
| Shorts | `https://www.youtube.com/shorts/dQw4w9WgXcQ` |

---

### 6.3 NowPlayingManager — コントロールセンター・ロック画面

```swift
@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    func start(player: AVPlayer, title: String, thumbnailURL: String)
    func stop()
}
```

**内部動作:**

| 処理 | 詳細 |
|------|------|
| `MPNowPlayingInfoCenter` | タイトル・再生時間・現在位置・サムネイルを設定 |
| 位置更新 | 0.5秒ごとに `Task` で再生位置を更新 |
| サムネイル取得 | `URLSession` で非同期取得 → `MPMediaItemArtwork` に変換 |
| `MPRemoteCommandCenter` | play / pause / toggle / スキップ±15秒 / シークバー操作 |

`setupRemoteCommands()` は `init()` 時に一度だけ実行し、`weak self` で `AVPlayer` を操作する。

---

### 6.4 LiveActivityManager — ダイナミックアイランド

```swift
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    func start(title:channelName:thumbnailURL:player:)
    func update(isPlaying:player:)
    func stop()
}
```

**ライフサイクル:**

```
start() → ActivityAuthorizationInfo().areActivitiesEnabled を確認
       → 既存 Activity があれば end()
       → Activity<StrixActivityAttributes>.request() で開始

update() → activity.content.state を更新して activity.update()

stop()  → activity.end(dismissalPolicy: .immediate)
```

---

### 6.5 StrixActivityAttributes — Live Activity 属性定義

```swift
struct StrixActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var channelName: String
        var thumbnailURL: String
        var isPlaying: Bool
        var elapsedSeconds: Double
        var durationSeconds: Double
    }
}
```

メインアプリと Widget Extension の両ターゲットに含める必要がある。

---

## 7. Widget Extension

### StrixLiveActivity.swift

```
ActivityConfiguration(for: StrixActivityAttributes.self)
├── LockScreenView（ロック画面・バナー）
│   ├── サムネイル（56×56 角丸）
│   ├── タイトル・チャンネル名
│   ├── ProgressView（シークバー）
│   └── 再生/一時停止アイコン
│
└── DynamicIsland
    ├── compactLeading: サムネイル円形（24×24）
    ├── compactTrailing: play/pause アイコン
    ├── minimal: play.rectangle.fill アイコン
    └── expanded
        ├── leading: サムネイル（52×52 角丸）
        ├── trailing: 再生/一時停止アイコン（.title2）
        └── bottom: タイトル・チャンネル名・シークバー
```

> **注意:** Widget Extension ターゲットの追加は Xcode UI から手動で行う必要がある。`TODO_XCODE_SETUP.md` を参照。

---

## 8. ナビゲーション構造

```
RootTabView（TabView）
├── HomeView
│   └── NavigationStack(path: NavigationPath)
│       └── .navigationDestination(for: String.self)
│           └── PlayerView(videoID:)
│               └── 関連動画 NavigationLink(value: videoId)
│                   └── PlayerView（再帰的スタック）
│
├── SearchView
│   └── NavigationStack(path: NavigationPath)
│       └── .navigationDestination(for: String.self)
│           └── PlayerView(videoID:)
│
└── AccountView
    └── NavigationStack
        ├── NavigationLink → HistoryView
        │   └── NavigationLink(value: videoId) → PlayerView
        │
        ├── NavigationLink → PlaylistDetailView（後で見る）
        │   └── NavigationLink(value: videoId) → PlayerView
        │
        ├── NavigationLink → PlaylistDetailView（いいね）
        │   └── NavigationLink(value: videoId) → PlayerView
        │
        ├── NavigationLink → PlaylistDetailView（ユーザープレイリスト）
        │   └── NavigationLink(value: videoId) → PlayerView
        │
        ├── Sheet → LoginView（YouTubeLoginWebView）
        └── Sheet → LogView
```

---

## 9. 認証フロー

### 9.1 初回ログイン

```
[アプリ起動]
    └── AuthState.shared.loadFromKeychain()
        └── Keychain に "yt_cookies" がなければ isSignedIn = false

[AccountView 未ログイン画面]
    └── "Googleでログイン" タップ

[LoginView（Sheet）]
    └── WKWebView（nonPersistent DataStore）で
        https://accounts.google.com/ServiceLogin?service=youtube を開く

[ユーザーが Google 認証を完了]
    └── Coordinator.webView(_:didFinish:)
        ├── URL が youtube.com → ログイン完了と判定
        ├── getAllCookies() → youtube.com / google.com クッキーを抽出
        └── AuthState.shared.save(cookies:dataStore:)
            ├── KeychainHelper.save(key: "yt_cookies", value: cookieString)
            └── AuthState.dataStore = webView.configuration.websiteDataStore

[Sheet dismiss → HomeView]
    └── .task(id: AuthState.shared.isSignedIn) が発火
        └── vm.reload() → browseHome() でパーソナライズドフィード取得
```

### 9.2 アプリ再起動後

```
[アプリ起動]
    └── AuthState.shared.loadFromKeychain()
        ├── Keychain から "yt_cookies" を読み込み → cookieString に設定
        └── dataStore は nil（メモリ保持のため再起動後は消える）

[HomeView.fetchHome()]
    └── browseHome(cookies: cookieString)
        ├── AuthState.shared.dataStore が nil
        └── makeDataStore(from: cookieString)
            ├── WKWebsiteDataStore.nonPersistent() を作成
            └── cookieString をパースして HTTPCookie を注入
                ├── __Host- プレフィックス → domain なし・secure 必須
                └── それ以外 → domain: ".youtube.com"
```

### 9.3 ログアウト

```
[AccountView "ログアウト" タップ]
    └── AuthState.shared.signOut()
        ├── cookieString = nil
        ├── dataStore = nil
        ├── KeychainHelper.delete(key: "yt_cookies")
        └── WKWebsiteDataStore.default().removeData(...)

[HomeView]
    └── .task(id: AuthState.shared.isSignedIn) が発火（false に変化）
        └── vm.reload() → 未ログイン用フォールバック
```

---

## 10. データフロー

### 10.1 動画再生までのデータフロー

```
ユーザーが動画をタップ
    │
    ├── VideoItem.videoId
    │
    ▼
path.append(videoID)  または  NavigationLink(value: videoId)
    │
    ▼
PlayerView(videoID: videoID)
    │
    ├── [並列]
    │   ├── YouTubeClient.fetchVideo(videoID)
    │   │   └── Innertube /player → VideoInfo { streamURL, title, thumbnailURL }
    │   │       └── AVPlayer(url: streamURL)
    │   │           ├── avPlayer.play()
    │   │           ├── NowPlayingManager.shared.start(...)
    │   │           ├── LiveActivityManager.shared.start(...)
    │   │           └── saveToHistory(...)  → SwiftData
    │   │
    │   └── ContentClient.fetchRelated(videoID)
    │       └── YouTubeKit MoreVideoInfosResponse → [VideoItem]
    │
    └── 画面表示:
        ├── VideoPlayer(player: avPlayer)  — ネイティブ再生コントロール
        ├── SpeedToggleButton              — 1× / 2× 切り替え
        └── VideoRowView × N              — 関連動画リスト
```

### 10.2 ホームフィードのデータフロー

```
HomeView.task(id: isSignedIn)
    │
    ▼
ContentClient.fetchHome()
    │
    ├── ログイン済み
    │   ├── browseHome(cookies:)
    │   │   ├── YouTubeWebLoader.load(dataStore:)
    │   │   │   ├── WKWebView で youtube.com を読み込み
    │   │   │   └── JS: JSON.stringify(window.ytInitialData)
    │   │   └── findVideoRenderers(in:) → parseVideoRenderer(_:) → [VideoItem]
    │   └── 失敗時: YouTubeKit HomeScreenResponse → [VideoItem]
    │
    └── 未ログイン
        └── YouTubeKit HomeScreenResponse → [VideoItem]
                   └── 失敗時: SearchResponse("trending music 2025") → [VideoItem]
    │
    ▼
HomeViewModel.videos: [VideoItem]
    │
    ▼
LazyVStack { VideoCardView × N }
```

### 10.3 アカウントのデータフロー

```
AccountView.task
    │
    ├── [並列]
    │   ├── AccountClient.fetchInfo()
    │   │   └── YouTubeKit AccountInfosResponse → accountInfo
    │   └── AccountClient.fetchLibrary()
    │       └── YouTubeKit AccountLibraryResponse → library
    │           ├── library.watchLater: YTPlaylist
    │           ├── library.likes: YTPlaylist
    │           └── library.playlists: [YTPlaylist]
    │
    ├── NavigationLink → HistoryView
    │   └── AccountClient.fetchHistory()
    │       └── YouTubeKit HistoryResponse
    │           └── videosAndTime: [HistoryBlock]
    │               └── HistoryBlock { groupTitle, videosArray: [VideoWithToken] }
    │
    └── NavigationLink → PlaylistDetailView(playlist:)
        └── AccountClient.fetchPlaylistVideos(playlist.playlistId)
            └── YouTubeKit PlaylistInfosResponse → [VideoItem]
```
