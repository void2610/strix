# Strix - CLAUDE.md

## プロジェクト概要

iOS 向け広告なし YouTube クライアント。
Swift 6 + SwiftUI + YouTubeKit（Innertube API）で構築。

## ビルドコマンド

```bash
# シミュレータ向けビルド（通常の開発時）
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# ビルド（エラーのみ表示）
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# SPM パッケージの解決のみ
xcodebuild -resolvePackageDependencies -project Strix.xcodeproj

# 利用可能なシミュレータ一覧
xcodebuild -project Strix.xcodeproj -scheme Strix -showdestinations
```

## テスト実行

```bash
# ユニットテスト
xcodebuild test -project Strix.xcodeproj -scheme StrixTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## ディレクトリ構成

```
strix/
├── Strix.xcodeproj
├── Strix/
│   ├── StrixApp.swift          # エントリポイント・ModelContainer 設定
│   ├── Assets.xcassets/
│   ├── Models/
│   │   └── WatchedVideo.swift  # SwiftData モデル（視聴履歴）
│   ├── Features/
│   │   ├── Home/
│   │   │   └── HomeView.swift  # URL/ID 入力・視聴履歴表示
│   │   └── Player/
│   │       └── PlayerView.swift # AVPlayer 動画再生
│   ├── Clients/
│   │   └── YouTubeClient.swift # YouTubeKit（Innertube API）ラッパー
│   └── Utilities/
│       └── VideoID.swift       # URL・動画 ID パーサー
├── StrixTests/
└── StrixUITests/
```

## 主要ライブラリ（SPM）

| ライブラリ | バージョン | 用途 |
|---|---|---|
| YouTubeKit | 1.3.0 | Innertube API でストリーム URL 取得 |
| Nuke / NukeUI | 12.9.0 | サムネイル画像キャッシュ |

## 注意事項

- ターゲット: iOS 26.2+（Xcode 26.3 で作成）
- Swift 6 strict concurrency 有効（`@MainActor` デフォルト）
- YouTubeKit の `sendRequest` は `youtubeModel:` （小文字 t）
- `VideoInfosResponse.streamingURL` は HLS manifest URL
