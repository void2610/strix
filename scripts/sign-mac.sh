#!/usr/bin/env bash
# Mac Catalyst 版を Release ビルドし、MornNotary で Developer ID 署名・公証した ZIP を作る（使い方: scripts/sign-mac.sh [出力先]）
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR=${1:-build/mac}
# 手元で実行する sign.sh が上流の変更で勝手に変わらないよう、内容を確認したコミットに固定する
MORNNOTARY_COMMIT=dec5ef5cc0f9278fbabff91c69c88f3bb5fdabde
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# MornNotary が Developer ID で署名し直すため、開発用プロファイルを埋め込まないアドホック署名でビルドする
xcodebuild -quiet -project Strix.xcodeproj -scheme Strix -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -derivedDataPath "$WORK/DerivedData" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build
APP="$WORK/DerivedData/Build/Products/Release-maccatalyst/Strix.app"

# アドホック署名は get-task-allow を付けるが、公証はこれを拒否し MornNotary は entitlements を引き継ぐため、これだけ外して署名し直す
ENTITLEMENTS="$WORK/entitlements.plist"
codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS"
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$ENTITLEMENTS" > /dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENTITLEMENTS"
fi
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/Strix.app" "$OUT_DIR/Strix-signed.zip"
ditto "$APP" "$OUT_DIR/Strix.app"

gh repo clone matsufriends/MornNotary "$WORK/MornNotary" -- --quiet --depth 1
git -C "$WORK/MornNotary" fetch --quiet --depth 1 origin "$MORNNOTARY_COMMIT"
git -C "$WORK/MornNotary" checkout --quiet --detach FETCH_HEAD
bash "$WORK/MornNotary/sign.sh" "$OUT_DIR/Strix.app"
