# 技術スタック

## 言語・UI

| 領域 | 選択 |
|---|---|
| 言語 | Swift 6 |
| UI | SwiftUI（+ 一部 UIKit） |
| 最小ターゲット | iOS 17+ |

UIKit との混在は AVKit 連携など一部の場面で現実的に必要。

## データ取得

- **YouTubeKit**（Innertube API ラッパー）でストリーム URL を取得
  - NewPipe / Piped などが使っている非公式内部 API
  - 広告なし再生の核心部分
- **YouTube Data API v3**（公式）で検索・メタデータ補完

> ⚠️ YouTube 利用規約上、個人・学習目的の範囲に留める

## 再生・バックグラウンド・PiP

```swift
import AVKit
import AVFoundation

// バックグラウンド再生
try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

// PiP
// AVPictureInPictureController（iOS 14+）
```

- `Info.plist` に `UIBackgroundModes: audio` を追加
- AVPlayer / AVKit で PiP・バックグラウンド再生をカバー

## アーキテクチャ

**TCA（The Composable Architecture）** または **MVVM + @Observable**

```
App
├── Features/
│   ├── Home/
│   ├── Player/
│   ├── Search/
│   └── Settings/
└── Clients/
    ├── YouTubeClient
    └── PlayerClient
```

## 主要ライブラリ（SPM）

| ライブラリ | 用途 |
|---|---|
| `swift-composable-architecture` | 状態管理 |
| `Nuke` | サムネキャッシュ |
| `YouTubeKit` | Innertube API ラッパー |

## UI 方針

- NavigationStack（iOS 16+）
- SF Symbols
- Dynamic Type 対応

## 開発環境

- **開発機**：M1 MacBook Pro（常時起動）
- **ターゲット端末**：手元の iPhone
- **リモート操作**：Tailscale 経由で屋外から Claude Code に指示

### Claude Code × Xcode

- **ローカル**：Claude Code CLI + XcodeBuildMCP でビルド・シミュレータ操作を自動化
- **Xcode 26.3 以降**：Claude Agent SDK がネイティブ統合（SwiftUI Preview の視覚確認も可能）

> Claude Code のクラウド実行環境は Linux のため、iOS ビルドは不可。ローカル Mac 必須。
