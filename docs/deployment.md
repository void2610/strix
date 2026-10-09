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

## Mac 版（Mac Catalyst）

iOS 版と同じアプリターゲットを Mac Catalyst でビルドする（ネイティブ macOS は UIKit 依存の書き分けが多いため見送り）。

- **Sandbox**: Mac では App Sandbox が有効なため、通信には `ENABLE_OUTGOING_NETWORK_CONNECTIONS`（`com.apple.security.network.client`）が必須。iOS では効かない設定なので iOS 版だけ見ていると欠落に気付かない
- **Mac で無効な機能**: Live Activity（ActivityKit が Mac Catalyst で使えない。ウィジェット拡張は iOS のみ埋め込む）

### 配布（MornNotary で署名・公証）

[MornNotary](https://github.com/matsufriends/MornNotary)（private）で Developer ID 署名と公証を受ける。Apple Developer Program に加入していないため、Developer ID 証明書は MornNotary 側の所有者のものを使う（アプリは証明書の所有者名義で署名される）。

```bash
scripts/sign-mac.sh            # build/mac に署名済みの Strix.app と配布用の Strix-signed.zip を出力
scripts/sign-mac.sh <出力先>
```

- **ビルド**: Release 構成をアドホック署名でビルドする。開発用プロファイルを埋め込むと、MornNotary が Developer ID で署名し直したあとのアプリと食い違うため
- **entitlements**: アドホック署名は `get-task-allow` を自動で付けるが、公証はこれを拒否し、MornNotary は entitlements を引き継いで署名し直す。そのためビルド設定から生成された entitlements からこれだけを外して署名し直す。`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` は Sandbox と通信許可まで消えるので使わない
- **依頼に必要なもの**: `gh auth login` 済みで、MornNotary リポジトリへの書き込み権限があること。依頼ブランチと Artifact は `sign.sh` が自動で削除する
- **MornNotary の固定**: 手元で実行する `sign.sh` は、内容を確認したコミット（スクリプトの `MORNNOTARY_COMMIT`）に固定している。MornNotary 側を更新したら `sign.sh` の差分を確認してから値を上げる。署名と公証そのものは MornNotary 側の Actions（main の `sign.yml`）が行うため、こちらからは固定できない
- **確認**: `spctl -a -vv -t execute build/mac/Strix.app` が `source=Notarized Developer ID` で accepted になること

## テスト

```bash
# ユニットテスト
xcodebuild test -project Strix.xcodeproj -scheme Strix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:StrixTests \
  2>&1 | grep -E "passed|failed|error:"
```
