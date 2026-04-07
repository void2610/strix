# Strix - CLAUDE.md

## プロジェクト概要

iOS 向け広告なし YouTube クライアント。
Swift 6 + SwiftUI + YouTubeKit（Innertube API）で構築。

## ビルドコマンド

```bash
# シミュレータ向けビルド（エラーのみ表示）
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# SPM パッケージの解決のみ
xcodebuild -resolvePackageDependencies -project Strix.xcodeproj

# 利用可能なシミュレータ一覧
xcodebuild -project Strix.xcodeproj -scheme Strix -showdestinations
```

## 実機ビルド＆インストール（iPhone 16）

```bash
# デバイス一覧確認
xcrun devicectl list devices --columns udid

# 実機向けビルド（USB or Tailscale 接続時）
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination "platform=iOS,id=00008140-001C61C436A2801C" \
  -configuration Debug \
  -allowProvisioningUpdates \
  build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED|CodeSign"

# インストール
xcrun devicectl device install app \
  --device 9C6866FC-D294-573E-BB8B-4106CC0E01F6 \
  $(find ~/Library/Developer/Xcode/DerivedData/Strix-*/Build/Products/Debug-iphoneos -name "Strix.app" -maxdepth 1 | head -1)

# ビルド＆インストール一括
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination "platform=iOS,id=00008140-001C61C436A2801C" \
  -configuration Debug -allowProvisioningUpdates build && \
xcrun devicectl device install app \
  --device 9C6866FC-D294-573E-BB8B-4106CC0E01F6 \
  $(find ~/Library/Developer/Xcode/DerivedData/Strix-*/Build/Products/Debug-iphoneos -name "Strix.app" -maxdepth 1 | head -1)
```

**デバイス情報（iPhone 16）**
- UDID: `00008140-001C61C436A2801C`
- CoreDevice ID: `9C6866FC-D294-573E-BB8B-4106CC0E01F6`
- 開発チーム: `8MDSKG4HM9`（Personal Team）

## テスト実行

```bash
# ユニットテスト（StrixTests のみ）
xcodebuild test -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:StrixTests \
  2>&1 | grep -E "passed|failed|error:"
```

## テスト方針

- **機能実装が完了したら必ずテストを実行すること。**
- 新しい ViewModel・ロジック・ユーティリティを追加したら、対応するテストを同時に実装すること。
- テストの分類：
  - **ユニットテスト**: ViewModel / ユーティリティ関数 → `ContentClient.mock()` / `YouTubeClient` のモックを使い、ネットワーク不要で検証する
  - **結合テスト**: API クライアント (`YouTubeClientTests`, `ContentClientTests`) → 実際のネットワークを叩いて疎通確認する
  - **SwiftData テスト**: `ModelConfiguration(isStoredInMemoryOnly: true)` でインメモリ DB を使う
- ViewModel への依存注入（DI）パターン：
  - `init(client: ContentClient = .live)` / `init(youtubeClient:contentClient:)` のように本番はデフォルト引数で `.live` を使う
  - テスト時は `ContentClient.mock(search: { ... })` で差し替える

## ディレクトリ構成

```
strix/
├── Strix.xcodeproj
├── Strix/
│   ├── StrixApp.swift               # エントリポイント・ModelContainer 設定
│   ├── Assets.xcassets/
│   ├── Models/
│   │   └── WatchedVideo.swift       # SwiftData モデル（視聴履歴）
│   ├── Features/
│   │   ├── RootTabView.swift        # タブ構成（ホーム・検索）
│   │   ├── Home/
│   │   │   └── HomeView.swift       # ホームフィード + URL入力 + 履歴
│   │   ├── Search/
│   │   │   └── SearchView.swift     # 動画検索
│   │   ├── Player/
│   │   │   └── PlayerView.swift     # AVPlayer 再生 + 関連動画
│   │   └── Components/
│   │       └── VideoCardView.swift  # 共通カード・行ビュー
│   ├── Clients/
│   │   ├── YouTubeClient.swift      # ストリーム URL 取得（Innertube IOS client）
│   │   └── ContentClient.swift      # ホーム/検索/関連動画（YouTubeKit）
│   └── Utilities/
│       └── VideoID.swift            # URL・動画 ID パーサー
├── StrixTests/
└── StrixUITests/
```

## 主要ライブラリ（SPM）

| ライブラリ | バージョン | 用途 |
|---|---|---|
| YouTubeKit | 1.3.0 | ホーム/検索/関連動画フェッチ |
| Nuke / NukeUI | 12.9.0 | サムネイル画像キャッシュ |

## 注意事項

- ターゲット: iOS 26.2+（Xcode 26.3 で作成）
- Swift 6 strict concurrency 有効（`@MainActor` デフォルト）
- **ストリーム取得**: YouTubeKit は使わず Innertube API を IOS クライアント (v21.13.6) で直接叩く
  - `clientName: "IOS"`, `X-Youtube-Client-Name: 5` が必須
  - iOS クライアントは通常動画でも `hlsManifestUrl`（M3U8）を返す
- **ホーム/検索/関連**: YouTubeKit の `HomeScreenResponse` / `SearchResponse` / `MoreVideoInfosResponse` を使用
  - ログインなしでは HomeScreenResponse が空 → SearchResponse にフォールバック
- `VideoInfosResponse.streamingURL` は HLS manifest URL（ライブ配信専用ではなく IOS クライアントなら通常動画でも取得可）
