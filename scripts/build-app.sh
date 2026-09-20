#!/bin/bash
# 编译并组装 MacSVN.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/dist/MacSVN.app"

echo "==> 编译（${CONFIG}）"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/MacSVN"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacSVN"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 生成图标"
if swift "$ROOT/scripts/make-icon.swift" "$ROOT/dist" >/dev/null 2>&1; then
    if iconutil -c icns "$ROOT/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        echo "    图标已生成"
    else
        echo "    iconutil 失败，跳过图标"
    fi
    rm -rf "$ROOT/dist/AppIcon.iconset"
else
    echo "    图标脚本失败，跳过图标"
fi

echo "==> 签名（ad-hoc）"
xattr -cr "$APP"
if codesign --force --sign - --identifier com.macsvn.app "$APP"; then
    echo "    已签名"
else
    echo "    签名失败（不影响本机运行）"
fi

echo
echo "完成：$APP"
echo "运行：open \"$APP\""
