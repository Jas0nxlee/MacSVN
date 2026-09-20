#!/bin/bash
# 打包并发布 GitHub Release（通用二进制 .app）
#
# 用法: ./scripts/release.sh [版本号]   例如 ./scripts/release.sh 1.0.0
# 版本号缺省时取 scripts/Info.plist 里的 CFBundleShortVersionString
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)}"
TAG="v$VERSION"
APP="$ROOT/dist/MacSVN.app"
ZIP_NAME="MacSVN-$VERSION-macOS.zip"
ZIP="$ROOT/dist/$ZIP_NAME"
NOTES="$ROOT/dist/release-notes-$VERSION.md"

if ! command -v gh >/dev/null 2>&1; then
    echo "需要 GitHub CLI（gh），请先：brew install gh && gh auth login" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "工作区有未提交的改动，请先提交再发布：" >&2
    git status --short >&2
    exit 1
fi

echo "==> 构建通用二进制并打包 .app"
"$ROOT/scripts/build-app.sh" release universal >/dev/null

if [ ! -d "$APP" ]; then
    echo "构建产物不存在：$APP" >&2
    exit 1
fi

echo "==> 压缩（ditto，保留 bundle 结构与权限）"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE="$(du -h "$ZIP" | awk '{print $1}')"
echo "    ${ZIP_NAME}（${SIZE}）"
echo "    SHA256 $SHA"

echo "==> 生成 release notes"
cat > "$NOTES" <<EOF
## 安装

1. 下载下面的 \`$ZIP_NAME\`，双击解压得到 \`MacSVN.app\`
2. 把它拖进「应用程序」文件夹
3. 首次打开会被 macOS 拦下（应用没有 Apple 开发者签名），按下面任一方式放行：
   - 终端执行：\`xattr -dr com.apple.quarantine /Applications/MacSVN.app\`
   - 或在「系统设置 → 隐私与安全性」里点「仍要打开」
4. 打开后若提示缺少 Subversion，点「用 Homebrew 安装 Subversion」即可，应用会自己装好

## 文件校验

\`\`\`
SHA256  $SHA
\`\`\`

## 本次修复

- 地址栏与面包屑现在显示解码后的文字（例如 `tags/其他` 而不是 `tags/%E5%85%B6%E4%BB%96`）；
  请求仍然使用百分号编码，直接复制显示出来的地址再次回车也能正常打开

## 登录信息

登录成功后账号密码存入系统钥匙串，默认 **30 天内免登录**；只有服务端验证通过的凭据才会保存。想换账号时用「MacSVN › 退出登录」立即清除。

## 界面语言

英文与简体中文，跟随系统语言自动切换（其他语言回落到英文）。

## 系统要求

- macOS 13 或更高
- 通用二进制：Apple 芯片与 Intel 均可（Intel 切片由同一份源码交叉编译，发布者手头没有 Intel 机器，未做真机验证；如遇问题请提 issue，或直接[从源码编译](https://github.com/Jas0nxlee/MacSVN#从源码构建与运行)）
- Subversion 可在应用内一键安装（通过 Homebrew），也可以自己 \`brew install subversion\`
EOF

echo "==> 创建 GitHub Release $TAG"
gh release create "$TAG" "$ZIP" \
    --title "MacSVN $VERSION" \
    --notes-file "$NOTES" \
    --target "$(git rev-parse --abbrev-ref HEAD)"

echo
gh release view "$TAG" --json url,assets --jq '"发布地址：\(.url)\n附件：\(.assets[].name)"'
