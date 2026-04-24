# Strix コードベース設計レビュー・リファクタリング報告書

作成日: 2026-04-24

アーキテクチャ全体・コード品質・API層の3観点から調査した結果をまとめる。

---

## 1. 巨大ファイルの分割が必要

| ファイル | 行数 | 問題 |
|---------|------|------|
| `Clients/ContentClient.swift` | **1,306行** | browse / next / feedback / comments / playlist 操作が全て1ファイル |
| `Features/Player/PlayerView.swift` | **1,051行** | ViewModel + View + 複数のロジックが混在 |
| `Features/Player/CustomPlayer/CustomPlayerView.swift` | **577行** | UI制御とジェスチャー処理が密結合 |

### 提案

- ContentClient は機能ごとに extension ファイルへ分割
  - `ContentClient+Browse.swift` — fetchHome / fetchHomePage / fetchHistoryVideos 等
  - `ContentClient+Comments.swift` — fetchComments / fetchCommentsPage
  - `ContentClient+Playlist.swift` — addToPlaylist / removeFromPlaylist / deletePlaylist
  - `ContentClient+Feedback.swift` — sendFeedback
  - `ContentClient+Channel.swift` — fetchChannel / fetchChannelTab 等
- PlayerView は ViewModel（PlayerViewModel）を `PlayerViewModel.swift` へ切り出す
- CustomPlayerView はジェスチャー処理を別ファイルに抽出

---

## 2. API リクエストのボイラープレートが大量重複

`YouTubeClient`, `ContentClient`, `AccountClient` の3ファイルで、以下のパターンが **10箇所以上** コピペされている:

```swift
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
request.setValue("Mozilla/5.0 ...", forHTTPHeaderField: "User-Agent")

let sessionConfig = URLSessionConfiguration.ephemeral
sessionConfig.httpShouldSetCookies = false
sessionConfig.httpCookieAcceptPolicy = .never
let session = URLSession(configuration: sessionConfig)
```

### 提案

`InnertubeRequest` のようなビルダーを導入し、共通ヘッダー・セッション設定・認証適用を一元化する。

```swift
// 例: 共通リクエストビルダー
struct InnertubeRequest {
    static func build(
        endpoint: String,
        body: [String: Any],
        clientType: ClientType = .web,
        authenticated: Bool = false
    ) -> URLRequest { ... }

    static func session() -> URLSession { ... }
}
```

---

## 3. ハードコードされた定数の散在

以下の値が複数ファイルに直書きされている:

| 定数 | 出現ファイル数 |
|------|--------------|
| クライアントバージョン `"2.20250415.01.00"`, `"21.13.6"` | 3+ |
| User-Agent 文字列（フル） | 3+ |
| デバイス情報 `"iPhone16,2"`, `"iPhone OS 18_4"` | 2+ |
| ロケール `"hl": "ja"`, `"gl": "JP"` | 5+ |
| API キー `AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w` | 3+ |

### 提案

`YouTubeConstants.swift` にまとめる。バージョン更新時の変更箇所が1つになる。

```swift
enum YouTubeConstants {
    static let webClientVersion = "2.20250415.01.00"
    static let iosClientVersion = "21.13.6"
    static let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    static let webUserAgent = "Mozilla/5.0 ..."
    static let iosUserAgent = "com.google.ios.youtube/..."
    // ...
}
```

---

## 4. JSON パースの重複パターン

YouTube の `runs` 配列からテキストを結合するパターンが **20箇所以上** に散在:

```swift
.compactMap({ $0["text"] as? String }).joined()
```

### 提案

ヘルパーとして抽出する:

```swift
extension Array where Element == [String: Any] {
    /// runs 配列から text を結合して返す
    var joinedText: String {
        compactMap { $0["text"] as? String }.joined()
    }
}
```

---

## 5. Force Unwrap（強制アンラップ）

| ファイル | 行 | コード | リスク |
|---------|-----|------|--------|
| `PlayerView.swift` | 123 | `info.audioOnlyURL!` | nil チェック後だが if-let 推奨 |
| `PlayerLayerView.swift` | 18 | `layer as! AVPlayerLayer` | layerClass 指定済みだが安全側に倒すべき |
| `MiniPlayerBar.swift` | 29 | `layer as! AVPlayerLayer` | 同上 |
| `PlaybackTracker.swift` | 145 | `chars.randomElement()!` | chars が空でないことは自明だが統一性のため |

### 提案

if-let / guard-let / nil-coalescing に置き換える。

---

## 6. エラーハンドリングの不統一

### 問題点

- **サイレント無視**: 関連動画・コメント取得の失敗を `catch {}` で握り潰し、ログすら出さない箇所がある
- **HTTP ステータスコード未チェック**: `URLSession.data(for:)` の応答ステータスを検証していない
- **JSON パース失敗の区別なし**: `try? JSONSerialization` で空辞書を返し、データなしとパースエラーが区別できない

### 提案

- 最低限 `strixLog()` でログを残す
- HTTP ステータスチェックを追加する:

```swift
let (data, response) = try await session.data(for: request)
guard let httpResponse = response as? HTTPURLResponse,
      (200...299).contains(httpResponse.statusCode) else {
    throw InnertubeError.httpError(statusCode: ...)
}
```

---

## 7. キャッシュの不在

全 API リクエストが `URLSessionConfiguration.ephemeral` で、レスポンスキャッシュが一切ない。ホームフィードやチャンネル情報など、短期間変わらないデータも毎回フェッチしている。

### 提案

即座に対応不要だが、将来的にはインメモリキャッシュ（TTL付き）の導入を検討する価値がある。

```swift
actor ResponseCache<T> {
    private var store: [String: (value: T, expiry: Date)] = [:]

    func get(_ key: String) -> T? { ... }
    func set(_ key: String, value: T, ttl: TimeInterval) { ... }
}
```

---

## 8. Singleton の使い方

| Singleton | 用途 | 評価 |
|-----------|------|------|
| `AuthState.shared` | 認証状態 | 他の Client が直接参照 → テスト時にモック困難 |
| `AppLogger.shared` | ログ | 許容範囲 |
| `NowPlayingManager.shared` | Control Center | 許容範囲 |
| `LiveActivityManager.shared` | Dynamic Island | 許容範囲 |

### 提案

`AuthState.shared` は Client の closure 内でキャプチャされているため実用上は問題ないが、テスト可能性を高めるなら `cookieProvider: () -> String?` のような注入に変更できる。

---

## 9. テストカバレッジ

### カバーされている領域

- JSON パーサー（videoRenderer / lockupViewModel / videoWithContextModel / compactVideoRenderer）
- ViewModel ロジック（Search, Player, Home, History）
- SwiftData モデル（WatchedVideo, PinnedPlaylist, SearchHistory）

### カバーされていない領域

- HTTP ステータス異常系
- Pagination の境界ケース（空ページ、トークン切れ）
- AccountViewModel
- ChannelViewModel
- PlaylistDetailViewModel

---

## 優先度まとめ

| 優先度 | 項目 | 理由 |
|--------|------|------|
| **高** | API ボイラープレートの共通化 | 変更箇所が多く、バージョン更新時のリスク |
| **高** | 定数の一元管理 | 同上 |
| **高** | ContentClient の分割 | 1,300行は保守困難 |
| **中** | Force Unwrap 除去 | クラッシュリスク |
| **中** | エラーハンドリング統一 | デバッグ効率 |
| **中** | JSON パースヘルパー抽出 | 重複削減 |
| **低** | キャッシュ導入 | UX改善だが緊急性低 |
| **低** | AuthState の DI 化 | テスト品質向上 |

---

## 総評

全体的なアーキテクチャ（Closure-based DI、@Observable ViewModel、NavigationStack）は良く設計されている。主な課題は「巨大ファイル」と「コードの重複」に集中しており、機能追加の前にこれらを整理すると今後の開発効率が大きく改善する。
