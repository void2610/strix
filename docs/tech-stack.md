# 技術スタック

## 言語・UI

| 領域 | 選択 |
|---|---|
| 言語 | Swift 6（strict concurrency 有効、`@MainActor` デフォルト） |
| UI | SwiftUI |
| 最小ターゲット | iOS 26.2+（Xcode 26.3 で作成） |

## 主要ライブラリ（SPM）

| ライブラリ | バージョン | 用途 |
|---|---|---|
| YouTubeKit | 1.3.0 | 検索（`SearchResponse`）のみ使用。他はすべて Innertube 直接呼び出し |
| Nuke / NukeUI | 12.9.0 | サムネイル画像キャッシュ |

## アーキテクチャパターン

- **MVVM + @Observable**: ViewModel は `@Observable` マクロで状態管理
- **DI パターン**: `init(client: ContentClient = .live)` で本番はデフォルト引数、テスト時は `.mock()` で差し替え
- **クライアント分離**: `YouTubeClient` / `ContentClient` / `AccountClient` / `AuthClient` に責務を分離

## フォーマッタ

- **SwiftFormat**（nicklockwood 版、Homebrew）を `.swiftformat` の設定で使う。`swiftformat .` で全体を整形する
- 有効にするルールは、空白とインデントの揺れを正すものだけに限定している（`--rules` によるホワイトリスト）。既存の書き方（辞書・行末コメントの揃え、末尾カンマなし、1 行の `if` 本体、`guard ... else {` を最後の条件と同じ行に置く）を保つため
- Apple の swift-format（Xcode 同梱）は見送った。複数行の `guard` / `if` で `else` と `{` を独立した行に移し、短い代入まで `=` の直後で改行するなど、既存スタイルを大きく書き換え、しかもそれらを設定で無効にできないため

## 開発環境

- **開発機**: M1 MacBook Pro
- **ターゲット端末**: iPhone 16
- **リモート操作**: Tailscale 経由で Claude Code に指示
