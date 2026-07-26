#!/usr/bin/env bash
# 构建 DailyReport 并打包成 macOS .app bundle
set -euo pipefail

cd "$(dirname "$0")/.."

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

# 注入构建版本号：CFBundleVersion = "<git 提交数>.<git short sha>"
# 方便从用户的 "关于" / 崩溃日志 / app.log 反查到具体提交
GIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_VER="${GIT_COUNT}.${GIT_SHA}"
plutil -replace CFBundleVersion -string "$BUILD_VER" "$APP/Contents/Info.plist"
echo "   构建版本号: $BUILD_VER"

# 注入 marketing 版本号：CFBundleShortVersionString
# 优先取最近一个 git tag（vX.Y.Z 或 X.Y.Z）；无 tag 时保留 template 默认（1.0.0）
# tag ≠ 版本格式（如 v1.0-beta）时也保留默认，避免把任意字符串塞进 plist
LATEST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"
if [[ -n "$LATEST_TAG" ]]; then
    # 剥离可选的 v 前缀，校验 X.Y.Z（数字.数字.数字，允许后缀 -xxx 但 plist 用前 3 段）
    TAG_VER="$(echo "$LATEST_TAG" | sed -E 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' || echo '')"
    if [[ -n "$TAG_VER" ]]; then
        # 取前 3 段（防止 tag 带预发布后缀如 1.2.3-rc1 污染 plist；macOS 只识别 X.Y.Z）
        TAG_VER_CLEAN="$(echo "$TAG_VER" | cut -d- -f1)"
        plutil -replace CFBundleShortVersionString -string "$TAG_VER_CLEAN" "$APP/Contents/Info.plist"
        echo "   marketing 版本号: $TAG_VER_CLEAN (来自 tag $LATEST_TAG)"
    else
        echo "   marketing 版本号: 保留 1.0.0 (tag '$LATEST_TAG' 不符合 X.Y.Z 格式)"
    fi
else
    echo "   marketing 版本号: 保留 1.0.0 (无 git tag)"
fi

# Ad-hoc 签名（SMAppService 注册登录项需要 bundle 至少有签名）
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "⚠️  ad-hoc 签名失败，开机自启功能可能不可用"

touch "$APP"

RESULT="$(pwd)/$APP"
echo ""
echo "✅ 构建完成: $RESULT"
echo "   启动: open \"$RESULT\""
echo "   卸载: rm -rf \"$RESULT\""
