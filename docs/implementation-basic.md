# 基本機能 実装計画

## ゴール

YouTube の動画 URL または動画 ID を入力し、広告なしで再生できる最小構成のアプリ。

---

## 画面構成

```
ContentView
└── NavigationStack
    ├── HomeView          # 動画 ID / URL 入力 + 最近見た動画
    └── PlayerView        # 動画再生
```

追加機能実装前は検索・フィードは持たない。入力欄から直接動画を開く形にする。

---

## UI デザイン

### HomeView

```
┌─────────────────────────────────────┐
│  Strix                              │  ← NavigationTitle
├─────────────────────────────────────┤
│  ┌───────────────────────────────┐  │
│  │ 🔗 YouTube URL / 動画 ID を入力 │  │  ← TextField
│  └───────────────────────────────┘  │
│  [ 再生 ]                            │  ← Button
│                                     │
│  最近再生した動画                      │  ← Section（任意）
│  ┌──────┐  ┌──────┐  ┌──────┐      │
│  │      │  │      │  │      │      │  ← サムネ横スクロール
│  └──────┘  └──────┘  └──────┘      │
└─────────────────────────────────────┘
```

- 背景：`Color(.systemBackground)`（ダークモード自動対応）
- テキストフィールドは `.searchable` ではなく通常の `TextField`（角丸、枠線）
- 「再生」ボタンは入力があるときのみアクティブ（`.disabled(videoID.isEmpty)`）

### PlayerView

```
┌─────────────────────────────────────┐
│  ← 戻る                              │  ← NavigationBar（透明）
│                                     │
│  ┌─────────────────────────────────┐│
│  │                                 ││
│  │         AVPlayer 映像            ││  ← 16:9
│  │                                 ││
│  └─────────────────────────────────┘│
│                                     │
│  動画タイトル                          │  ← .title2, bold
│  チャンネル名                          │  ← .subheadline, secondary
│                                     │
│  ──── コントロール ────                 │
│  |◀◀   ▶   ▶▶|   🔊────────        │  ← 再生/停止/シーク/音量
│  0:00 ─────────────────── 10:23    │  ← プログレスバー
│                                     │
└─────────────────────────────────────┘
```

- 映像エリアは `VideoPlayer(player:)` または `AVPlayerLayer` を `UIViewRepresentable` でラップ
- コントロールは AVKit デフォルトを使うか、SwiftUI で自作（最初は AVKit デフォルトで可）
- ロード中は `ProgressView()` をオーバーレイ

---

## データフロー

```
HomeView
  │  videoID: String
  ▼
YouTubeClient.fetchStreamURL(videoID:)
  │  Innertube API（YouTubeKit）
  │  → 音声付き動画ストリーム URL を取得
  ▼
PlayerView
  │  AVPlayer(url: streamURL)
  ▼
映像再生
```

---

## 実装ステップ

### Step 1: プロジェクトセットアップ

```
Xcode で新規プロジェクト作成
  - Template: App
  - Interface: SwiftUI
  - Language: Swift
  - Minimum Deployment: iOS 17.0

SPM パッケージ追加:
  - YouTubeKit: https://github.com/b5i/YouTubeKit
  - Nuke: https://github.com/kean/Nuke（サムネ用、後で使用）
```

### Step 2: YouTubeClient の実装

```swift
// Clients/YouTubeClient.swift

import YouTubeKit

struct YouTubeClient {
    var fetchStreamURL: (String) async throws -> URL
}

extension YouTubeClient {
    static let live = YouTubeClient(
        fetchStreamURL: { videoID in
            let response = try await VideoInfosResponse.sendRequest(
                youTubeModel: YouTubeModel(),
                data: [.query: videoID]
            )
            // 最高画質の音声付きストリームを選択
            guard let streamingURL = response.streamingURL else {
                throw YouTubeClientError.streamNotFound
            }
            return streamingURL
        }
    )
}

enum YouTubeClientError: Error {
    case streamNotFound
    case invalidVideoID
}
```

> YouTubeKit の API は実際のライブラリ仕様に合わせて調整が必要。

### Step 3: VideoID パース

URL と動画 ID の両方を受け付けるユーティリティ。

```swift
// Utilities/VideoID.swift

func extractVideoID(from input: String) -> String? {
    // 動画 ID 直接入力（11文字英数字）
    let idPattern = /^[a-zA-Z0-9_-]{11}$/
    if input.wholeMatch(of: idPattern) != nil { return input }

    // URL から抽出
    guard let url = URL(string: input),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }
    // https://www.youtube.com/watch?v=XXXXXXXXXXX
    if let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
        return v
    }
    // https://youtu.be/XXXXXXXXXXX
    if url.host == "youtu.be" {
        return url.pathComponents.dropFirst().first
    }
    return nil
}
```

### Step 4: HomeView の実装

```swift
// Features/Home/HomeView.swift

struct HomeView: View {
    @State private var input = ""
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 16) {
                TextField("YouTube URL または動画 ID", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal)

                Button("再生") {
                    if let id = extractVideoID(from: input) {
                        path.append(id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.isEmpty)

                Spacer()
            }
            .navigationTitle("Strix")
            .navigationDestination(for: String.self) { videoID in
                PlayerView(videoID: videoID)
            }
        }
    }
}
```

### Step 5: PlayerView の実装

```swift
// Features/Player/PlayerView.swift

struct PlayerView: View {
    let videoID: String
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var error: Error?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if isLoading {
                ProgressView("読み込み中...")
            } else if error != nil {
                ContentUnavailableView("再生できません", systemImage: "exclamationmark.triangle")
            }
        }
        .task {
            await loadStream()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func loadStream() async {
        do {
            let url = try await YouTubeClient.live.fetchStreamURL(videoID)
            player = AVPlayer(url: url)
            player?.play()
            isLoading = false
        } catch {
            self.error = error
            isLoading = false
        }
    }
}
```

### Step 6: Info.plist 設定

| Key | Value |
|---|---|
| `UIBackgroundModes` | `audio`（バックグラウンド再生、追加機能実装前でも設定しておく） |
| `NSAppTransportSecurity` | 必要に応じて設定（ストリーム URL が http の場合） |

---

## ファイル構成

```
Strix/
├── StrixApp.swift
├── Features/
│   ├── Home/
│   │   └── HomeView.swift
│   └── Player/
│       └── PlayerView.swift
├── Clients/
│   └── YouTubeClient.swift
└── Utilities/
    └── VideoID.swift
```

---

## 確認事項・リスク

| 項目 | 内容 |
|---|---|
| YouTubeKit のストリーム取得 API | ライブラリの実際の使い方を README で確認してから実装する |
| Innertube の仕様変更 | 非公式 API のため突然使えなくなる可能性あり |
| ストリーム URL の有効期限 | 取得した URL には有効期限があるため、長時間再生時は再取得が必要になる場合あり |
