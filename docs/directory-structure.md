# ディレクトリ構成

```
strix/
├── Strix.xcodeproj
├── CLAUDE.md
├── docs/
├── Strix/
│   ├── StrixApp.swift               # エントリポイント・ModelContainer 設定
│   ├── Info.plist                   # 手動管理（UIBackgroundModes=audio 含む）
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
│   │   │   ├── PlayerView.swift     # 動画再生（PiP・バックグラウンド・倍速・ループ・プレイリスト再生）
│   │   │   ├── PlayerCoordinator.swift  # アプリ全体のプレイヤー状態管理
│   │   │   ├── PlayerContainerView.swift # フルスクリーン/ミニプレイヤーのオーバーレイ管理
│   │   │   └── MiniPlayerBar.swift  # ミニプレイヤー（右下の小窓映像ウィンドウ）
│   │   ├── Channel/
│   │   │   └── ChannelView.swift    # チャンネルページ（ホーム・動画・ライブ・再生リストタブ）
│   │   ├── Account/
│   │   │   ├── HistoryView.swift    # 視聴履歴
│   │   │   └── PlaylistDetailView.swift  # プレイリスト動画一覧
│   │   ├── Auth/
│   │   │   ├── LoginView.swift      # WKWebView ログイン
│   │   │   ├── BotVerifyView.swift  # ボット検出時の認証画面
│   │   │   ├── AccountView.swift    # アカウント情報・ライブラリ・プレイリスト一覧
│   │   │   └── LogView.swift        # デバッグログ
│   │   └── Components/
│   │       ├── VideoCardView.swift  # 共通カード・行ビュー
│   │       └── AddToPlaylistMenu.swift  # プレイリスト追加サブメニュー
│   ├── Clients/
│   │   ├── YouTubeClient.swift      # ストリーム URL 取得（IOS → WEB → WebPage フォールバック）
│   │   ├── ContentClient.swift      # ホーム/検索/関連動画/チャンネル/プレイリスト
│   │   ├── AccountClient.swift      # アカウント情報・ライブラリ
│   │   └── AuthClient.swift         # 認証状態管理（AuthState）・Keychain・Cookie 検証
│   └── Utilities/
│       ├── VideoID.swift            # URL・動画 ID パーサー
│       ├── AppLogger.swift          # アプリ内ログ
│       ├── NowPlayingManager.swift  # コントロールセンター表示
│       ├── LiveActivityManager.swift # ダイナミックアイランド制御
│       └── StrixActivityAttributes.swift # Live Activity 属性定義（メインアプリ・Widget 共有）
├── StrixWidgetExtension/
│   ├── StrixWidgetExtensionBundle.swift  # Widget バンドルエントリポイント
│   ├── StrixLiveActivity.swift           # ダイナミックアイランド・ロック画面 UI
│   ├── StrixWidgetExtensionLiveActivity.swift
│   ├── StrixWidgetExtension.swift
│   ├── StrixWidgetExtensionControl.swift
│   ├── AppIntent.swift
│   ├── Info.plist
│   └── Assets.xcassets/
├── StrixTests/
└── StrixUITests/
```
