# ビルド・デプロイ方針

## 採用：無料 Apple ID + Tailscale Wireless

```
屋外の iPhone
    ↓ Tailscale 経由で指示
MacBook の Claude Code がビルド
    ↓ Tailscale Wireless（WireGuard P2P）
iPhone に直接インストール
```

**Apple Developer Program（$99/年）は使わない。**

## 無料プロビジョニングの概要

- Xcode に Apple ID（無料）を登録するだけで自分の iPhone にインストール可能
- App Store・TestFlight 不要
- **制限：証明書が 7 日で失効 → 週 1 回再インストールが必要**

```
Xcode → Settings → Accounts → Apple ID 追加
プロジェクト Signing & Capabilities → Team を Apple ID に設定
```

## 7日失効の対策

fastlane で再署名・再インストールを自動化：

```bash
# 週1で自動実行
fastlane resign_and_install
```

## Tailscale の通信量

- シグナリングのみ Tailscale サーバー経由、実データは P2P（WireGuard）直通
- Tailscale 自体の通信コストはほぼゼロ
- .ipa 転送分のモバイル回線消費はあるが許容範囲

## 比較表

| | 無料 + Tailscale | $99/年 + TestFlight |
|---|---|---|
| コスト | 0円 | 約15,000円/年 |
| 配布先 | 自分のみ | 複数人も可 |
| 手間 | 7日ごと再インストール | ほぼ自動 |
| 今回の用途 | **◎** | 不要 |
