# iOS YouTube クライアント 開発計画

## プロジェクト概要

個人用の広告なし YouTube クライアント（iOS）。Apple HIG 準拠のモダン UI を持ち、バックグラウンド再生・PiP などの実用機能を重視する。

## ドキュメント構成

| ファイル | 内容 |
|---|---|
| [tech-stack.md](./tech-stack.md) | 技術スタック・アーキテクチャ |
| [deployment.md](./deployment.md) | ビルド・デプロイ方針 |
| [features.md](./features.md) | 機能一覧 |
| [implementation-basic.md](./implementation-basic.md) | 基本機能の実装計画・UI デザイン |

## 決定事項まとめ

- [x] Swift 6 + SwiftUI（+ 必要に応じ UIKit）
- [x] iOS 17+ ターゲット
- [x] YouTubeKit（Innertube）でストリーム取得（広告なし）
- [x] AVPlayer + AVKit で PiP・バックグラウンド再生
- [x] アーキテクチャは TCA または MVVM + @Observable
- [x] 開発は M1 MacBook Pro でローカルビルド
- [x] リモート操作は Tailscale + Claude Code
- [x] デプロイは無料 Apple ID + Tailscale Wireless
- [x] Apple Developer Program には加入しない
- [x] 7日失効は fastlane で自動再インストール対応
