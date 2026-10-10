# ビルド・デプロイ

## 方針

- 無料 Apple ID + ローカルビルド（Apple Developer Program 不使用）
- 署名に埋め込むプロファイルが 7 日で失効 → 常時起動の Mac（m1server）が毎晩ビルドして入れ直す（nix-config の `strix-nightly-install-server.nix`）
  - ビルド前に main を取り込む
  - Xcode は期限内のプロファイルを使い回し、入れ直すだけでは期限が延びないため、期限まで 2 日を切ったプロファイルは消して作り直させる

## 署名（開発用証明書の共有）

無料 Apple ID は有効な開発用証明書を 1 枚しか持てない。別の Mac の Xcode が証明書を新しく作ると、それまでの証明書は失効する。

- 失効した証明書で署名したアプリは、iPhone が失効を検知した時点（数時間〜1 日ほど後）から起動を拒否される。開いた瞬間に閉じ、クラッシュログは残らない
- そのため署名する Mac（手元の Mac と m1server）には同じ証明書を入れる。nix-config が sops で配り、専用キーチェーン `~/Library/Keychains/apple-development.keychain-db` に取り込む（`apple-development-signing.nix`）
- 別の Mac で実機ビルドするときは、先に nix-config でこの証明書を配る。配る前に Xcode でビルドすると新しい証明書が作られ、他の Mac で入れたアプリが起動しなくなる
- 失効は `security verify-cert -c <証明書の PEM> -p codeSign -R ocsp` で確かめる。`security find-identity` はキャッシュのため失効を見落とすことがある

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

## Mac 版（Mac Catalyst）

iOS 版と同じアプリターゲットを Mac Catalyst でビルドする（ネイティブ macOS は UIKit 依存の書き分けが多いため見送り）。

- **Sandbox**: Mac では App Sandbox が有効なため、通信には `ENABLE_OUTGOING_NETWORK_CONNECTIONS`（`com.apple.security.network.client`）が必須。iOS では効かない設定なので iOS 版だけ見ていると欠落に気付かない
- **Mac で無効な機能**: Live Activity（ActivityKit が Mac Catalyst で使えない。ウィジェット拡張は iOS のみ埋め込む）

## テスト

```bash
# ユニットテスト
xcodebuild test -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:StrixTests \
  2>&1 | grep -E "passed|failed|error:"
```
