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

**重要方針**
- デバッグ・検証は、まずユニットテスト、結合テスト、シミュレータで行うこと。
- **最新ビルドをユーザーへデリバリーするための実機ビルドとインストールは、デバッグとは別物として扱い、デバイスが到達可能な限り原則として毎回行うこと。**
- **実機での再現確認や実機ログ取得は最終手段**とすること。
- 実機確認に進むのは、シミュレータやテストでは再現できない、または実機固有挙動（認証、CoreDevice、オーディオセッション、バックグラウンド再生、実機専用 API など）が関係すると合理的に判断できる場合のみ。
- 安易に「実機へ入れて確認する」を選ばないこと。**ユーザーの時間は有限であり、エージェントの時間よりはるかに重要**である。
- 実機確認が必要になった場合でも、事前に「なぜシミュレータやテストでは足りないのか」を明確にした上で、回数を最小化すること。
- ユーザーにアクションを求めることは最終手段とし、**デバイスが同一ネットワークまたは USB 接続で到達可能なら、まずエージェント側で実機ビルドとインストールを行うこと。**

### 前提：接続方法について

iOS の CoreDevice 通信ポート（62078）は Wi-Fi インターフェースにのみバインドされるため、
**Tailscale 単独では接続不可**。以下いずれかが必要：

- **USB 接続**（最も確実）
- **同じ Wi-Fi ネットワーク**（ネットワークペアリング済みであること）

### ネットワークペアリング（初回のみ・USB 接続時に実行）

Xcode の UI（Connect via network）は不要。USB 接続中に以下を一度実行するだけでよい：

```bash
xcrun devicectl manage pair --device 9C6866FC-D294-573E-BB8B-4106CC0E01F6
```

ペアリング後は **同じ Wi-Fi** にいれば USB なしで `devicectl` が使える。
Tailscale のみ（別ネットワーク）では依然として不可。

### ビルド＆インストールコマンド

```bash
# デバイスが見えているか確認（Tailscale 接続中に実行）
xcrun devicectl list devices --columns udid

# 実機向けビルド
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
- **検証の優先順位は `ユニットテスト → 結合テスト → シミュレータ確認 → 実機確認` とすること。**
- **実機ログ取得は、どうしても必要な場合の最終手段としてのみ行うこと。**
- シミュレータやテストで確認できる内容について、実機確認を先に行わないこと。
- 一方で、最新ビルドのデリバリー目的の実機インストールは常に別扱いとし、デバイス接続が成立している限り、ユーザーへ操作依頼する前にエージェント側で実施すること。
- デバッグのために一時ログや検証コードを入れた場合は、原因特定後に必ず削除し、恒久実装とテストだけを残すこと。
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
│   ├── Info.plist                   # 手動管理 Info.plist（UIBackgroundModes=audio 含む）
│   ├── Assets.xcassets/
│   ├── Models/
│   │   ├── VideoItem.swift          # 軽量動画モデル（ホーム・検索・関連動画共通）
│   │   ├── WatchedVideo.swift       # SwiftData モデル（視聴履歴）
│   │   └── PinnedPlaylist.swift     # SwiftData モデル（ホーム画面プレイリスト選択）
│   ├── Features/
│   │   ├── RootTabView.swift        # タブ構成（ホーム・検索・アカウント）
│   │   ├── Home/
│   │   │   ├── HomeView.swift       # ホームフィード + プレイリストクイックアクセス
│   │   │   └── HomePlaylistEditView.swift  # ホーム表示プレイリスト選択画面
│   │   ├── Search/
│   │   │   └── SearchView.swift     # 動画検索
│   │   ├── Player/
│   │   │   └── PlayerView.swift     # 動画再生（PiP・バックグラウンド・倍速・ループ・プレイリスト再生）
│   │   ├── Channel/
│   │   │   └── ChannelView.swift    # チャンネルページ（ホーム・動画・ライブ・再生リストタブ）
│   │   ├── Account/
│   │   │   ├── HistoryView.swift    # 視聴履歴
│   │   │   └── PlaylistDetailView.swift  # プレイリスト動画一覧
│   │   ├── Auth/
│   │   │   ├── LoginView.swift      # WKWebView ログイン
│   │   │   ├── BotVerifyView.swift  # ボット検出時の認証画面
│   │   │   └── LogView.swift        # デバッグログ
│   │   └── Components/
│   │       └── VideoCardView.swift  # 共通カード・行ビュー
│   ├── Clients/
│   │   ├── YouTubeClient.swift      # ストリーム URL 取得（IOS → WEB → WebPage フォールバック）
│   │   ├── ContentClient.swift      # ホーム/検索/関連動画/チャンネル/プレイリスト（Innertube WEB client）
│   │   └── AccountClient.swift      # アカウント情報・ライブラリ（Innertube WEB client）
│   └── Utilities/
│       ├── VideoID.swift            # URL・動画 ID パーサー
│       ├── AppLogger.swift          # アプリ内ログ
│       ├── NowPlayingManager.swift  # コントロールセンター表示
│       └── LiveActivityManager.swift # ダイナミックアイランド
├── StrixTests/
└── StrixUITests/
```

## 主要ライブラリ（SPM）

| ライブラリ | バージョン | 用途 |
|---|---|---|
| YouTubeKit | 1.3.0 | 検索（SearchResponse）のみ使用。他はすべて Innertube 直接呼び出し |
| Nuke / NukeUI | 12.9.0 | サムネイル画像キャッシュ |

## アーキテクチャ

### 認証フロー
- WKWebView（`.default()` 永続ストア）で Google ログイン → YouTube セッション Cookie 取得
- 必須 Cookie（SID/HSID/SSID）検証後に Keychain 保存
- デバイス信頼情報は `.default()` ストアで永続保持（再ログイン時 2FA 不要）

### API クライアント戦略
- **コンテンツ取得**: Innertube WEB クライアント + Cookie + SAPISIDHASH 認証
- **ストリーム取得**: IOS クライアント（HLS）→ WEB クライアント（combined formats）→ WebPage（WKWebView で ytInitialPlayerResponse 抽出）の3段フォールバック
- **関連動画**: Innertube `/next` API から lockupViewModel をパース（YouTubeKit の MoreVideoInfosResponse は壊れているため不使用）
- **チャンネルアバター**: `/next` の videoOwnerRenderer → `/player` の endscreen → 関連動画の同一チャンネルから取得

### パーサー
- lockupViewModel（WEB 新形式）: `parseLockupViewModel` — チャンネル名/ID は `extractChannelInfo` で再帰探索
- videoRenderer（WEB 旧形式）: `parseVideoRenderer`
- videoWithContextModel（IOS 形式）: `parseVideoWithContextData`
- プレイリスト: `parsePlaylistLockups`（LOCKUP_CONTENT_TYPE_PLAYLIST/ALBUM）
- ミックスリスト: `/next` API の `playlistPanelVideoRenderer` をパース
- 画像 URL: `imageURL(from:)` でプロトコル相対 URL（`//`）を `https:` に補正

## 注意事項

- ターゲット: iOS 26.2+（Xcode 26.3 で作成）
- Swift 6 strict concurrency 有効（`@MainActor` デフォルト）
- **ストリーム取得**: YouTubeKit は使わず Innertube API を IOS/WEB クライアントで直接叩く
- **ホームフィード**: Innertube `/browse` (WEB client) を URLSession で直接呼ぶ
  - 認証: `Cookie` + `SAPISIDHASH` (`Authorization`) + `X-Goog-AuthUser: 0`
  - `httpShouldSetCookies = false` の ephemeral session でシステムの Cookie 上書きを防止
- **検索**: YouTubeKit の `SearchResponse` を使用（唯一の YouTubeKit 依存）
- **関連動画**: Innertube `/next` API を直接呼び出し
- **ボット検出対策**: WebPage フォールバック（WKWebView で YouTube ページを読み込み ytInitialPlayerResponse から抽出）+ BotVerifyView で手動 CAPTCHA 解決
- **倍速設定**: UserDefaults に永続化。動画切り替え・PiP・アプリ再起動でも維持
