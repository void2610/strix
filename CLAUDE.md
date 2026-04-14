# Strix - CLAUDE.md

iOS 向け広告なし YouTube クライアント。Swift 6 + SwiftUI + Innertube API。
詳細は [docs/](./docs/) を参照。

## ビルド

```bash
# シミュレータ向けビルド
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# SPM パッケージ解決
xcodebuild -resolvePackageDependencies -project Strix.xcodeproj
```

## 実機ビルド＆インストール（iPhone 16）

```bash
# ビルド＆インストール一括
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination "platform=iOS,id=00008140-001C61C436A2801C" \
  -configuration Debug -allowProvisioningUpdates build && \
xcrun devicectl device install app \
  --device 9C6866FC-D294-573E-BB8B-4106CC0E01F6 \
  $(find ~/Library/Developer/Xcode/DerivedData/Strix-*/Build/Products/Debug-iphoneos -name "Strix.app" -maxdepth 1 | head -1)
```

- UDID: `00008140-001C61C436A2801C` / CoreDevice ID: `9C6866FC-D294-573E-BB8B-4106CC0E01F6`
- 開発チーム: `8MDSKG4HM9`（Personal Team）
- Tailscale 単独では接続不可（Wi-Fi または USB 必須）

## テスト

```bash
xcodebuild test -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:StrixTests \
  2>&1 | grep -E "passed|failed|error:"
```

## 行動規則

- **検証優先順位**: ユニットテスト → 結合テスト → シミュレータ → 実機
- **実機デバッグは最終手段**。シミュレータやテストで足りない理由を明確にすること
- **最新ビルドのデリバリー**はデバッグとは別扱い。デバイス到達可能なら原則毎回実機インストール
- デバッグ用の一時コードは原因特定後に必ず削除
- 新しい ViewModel・ロジック・ユーティリティには対応テストを同時実装
- **テスト分類**:
  - ユニットテスト: `ContentClient.mock()` 等でネットワーク不要
  - 結合テスト: 実ネットワーク疎通確認
  - SwiftData: `ModelConfiguration(isStoredInMemoryOnly: true)`
- **DI パターン**: `init(client: ContentClient = .live)` でデフォルト `.live`、テスト時は `.mock()` で差し替え
