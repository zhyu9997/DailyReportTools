#!/usr/bin/env bash
# 构建 DailyReport 并打包成 macOS .app bundle
set -euo pipefail

cd "$(dirname "$0")/.."

# Command Line Tools 缺少 SwiftData 宏插件，需用完整 Xcode
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="${1:-release}"
APP="DailyReport.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
if [[ ! -f "$BIN_DIR/DailyReport" ]]; then
    echo "ERROR: 可执行文件未找到: $BIN_DIR/DailyReport" >&2
    exit 1
fi

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_DIR/DailyReport" "$APP/Contents/MacOS/DailyReport"
cp "Resources/Info.plist.template" "$APP/Contents/Info.plist"

touch "$APP"

RESULT="$(pwd)/$APP"
echo ""
echo "✅ 构建完成: $RESULT"
echo "   启动: open \"$RESULT\""
echo "   卸载: rm -rf \"$RESULT\""
