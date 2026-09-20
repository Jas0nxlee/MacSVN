#!/bin/bash
# 编译并组装 MacSVN.app
#
# 用法:
#   ./scripts/build-app.sh                # release，本机架构
#   ./scripts/build-app.sh debug          # debug
#   ./scripts/build-app.sh release universal   # 通用二进制（Apple 芯片 + Intel）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
ARCH="${2:-native}"
APP="$ROOT/dist/MacSVN.app"

ARCH_FLAGS=()
if [ "$ARCH" = "universal" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> 编译（${CONFIG}${ARCH:+, $ARCH}）"
swift build -c "$CONFIG" --package-path "$ROOT" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/MacSVN"

echo "==> 组装 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacSVN"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 本地化资源"
if [ -d "$ROOT/Resources" ]; then
    for lproj in "$ROOT/Resources"/*.lproj; do
        [ -d "$lproj" ] || continue
        cp -R "$lproj" "$APP/Contents/Resources/"
        echo "    $(basename "$lproj")"
    done
else
    echo "    没有 Resources 目录，跳过"
fi

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
    echo "    已签名（ad-hoc，没有开发者 ID，别人首次打开需要手动放行）"
else
    echo "    签名失败（不影响本机运行）"
fi

echo
echo "架构：$(lipo -info "$APP/Contents/MacOS/MacSVN" 2>/dev/null | sed 's/.*: //')"
echo "完成：$APP"
echo "运行：open \"$APP\""
