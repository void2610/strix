# ビルド・デプロイ

## 方針

- 無料 Apple ID + ローカルビルド（Apple Developer Program 不使用）
- 7日で証明書失効 → 定期的に再ビルド＆インストール

## デバイス情報（iPhone 16）

| 項目 | 値 |
|---|---|
| UDID | `00008140-001C61C436A2801C` |
| CoreDevice ID | `9C6866FC-D294-573E-BB8B-4106CC0E01F6` |
| 開発チーム | `8MDSKG4HM9`（Personal Team） |

## 接続方法

iOS の CoreDevice 通信ポート（62078）は Wi-Fi インターフェースにのみバインドされるため、**Tailscale 単独では接続不可**。

| 方法 | 状態 |
|---|---|
| USB 接続 | 最も確実 |
| 同じ Wi-Fi（ペアリング済み） | OK |
| Tailscale のみ（別ネットワーク） | 不可 |

### ネットワークペアリング（初回のみ・USB 接続時）

```bash
xcrun devicectl manage pair --device 9C6866FC-D294-573E-BB8B-4106CC0E01F6
```

## ビルドコマンド

```bash
# デバイス確認
xcrun devicectl list devices --columns udid

# シミュレータビルド
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# 実機ビルド
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination "platform=iOS,id=00008140-001C61C436A2801C" \
  -configuration Debug -allowProvisioningUpdates \
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

# シミュレータ一覧
xcodebuild -project Strix.xcodeproj -scheme Strix -showdestinations

# SPM パッケージ解決
xcodebuild -resolvePackageDependencies -project Strix.xcodeproj
```

## テスト

```bash
# ユニットテスト
xcodebuild test -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:StrixTests \
  2>&1 | grep -E "passed|failed|error:"
```
