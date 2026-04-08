# Xcode手動設定TODO

帰宅後にXcodeで以下の作業を行うこと。

---

## 1. iPhoneにインストール

USBでiPhoneを接続し、以下を実行：

```bash
xcodebuild -project Strix.xcodeproj -scheme Strix \
  -destination "platform=iOS,id=00008140-001C61C436A2801C" \
  -configuration Debug -allowProvisioningUpdates build && \
xcrun devicectl device install app \
  --device 9C6866FC-D294-573E-BB8B-4106CC0E01F6 \
  $(find ~/Library/Developer/Xcode/DerivedData/Strix-*/Build/Products/Debug-iphoneos -name "Strix.app" -maxdepth 1 | head -1)
```

---

## 2. Widget Extensionターゲット追加（ダイナミックアイランド用）

1. Xcode → **File → New → Target**
2. **Widget Extension** を選択
3. 設定：
   - Product Name: `StrixWidgetExtension`
   - Include Live Activity: **チェックを入れる**
4. Finishを押してターゲット作成

### 既存ファイルをターゲットに追加

以下の2ファイルをWidget Extensionターゲットのメンバーに追加する：

- `StrixWidgetExtension/StrixLiveActivity.swift`
  - ファイル選択 → File inspector → Target Membership → `StrixWidgetExtension` にチェック
- `Strix/Utilities/StrixActivityAttributes.swift`
  - 同様に `StrixWidgetExtension` にもチェックを追加（メインアプリと両方にチェック）

Xcodeが自動生成したWidget Extensionのデフォルトファイル（`StrixWidgetExtension.swift` など）は**削除してよい**。

---

## 3. Live Activities権限を追加（メインアプリ）

1. Xcodeでメインアプリターゲット（Strix）を選択
2. **Signing & Capabilities** タブ
3. **+ Capability** をクリック
4. **Live Activities** を追加

---

## 完了後の確認

- バックグラウンド再生：動画を再生してホームボタンで戻る → 音が続けば OK
- コントロールセンター：再生/一時停止/スキップが操作できれば OK
- ダイナミックアイランド：再生中にホームに戻るとアイランドに表示されれば OK
