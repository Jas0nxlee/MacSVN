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
# 用带引号的 heredoc：模板里的反引号不会被 shell 当命令执行；变量走占位符替换
cat > "$NOTES" <<'NOTES_TEMPLATE'
## 安装

1. 下载下面的 `MacSVN-@@VERSION@@-macOS.zip`，双击解压得到 `MacSVN.app`
2. 把它拖进「应用程序」文件夹
3. 首次打开会被 macOS 拦下（应用没有 Apple 开发者签名），按下面任一方式放行：
   - 终端执行：`xattr -dr com.apple.quarantine /Applications/MacSVN.app`
   - 或在「系统设置 → 隐私与安全性」里点「仍要打开」
4. 打开后若提示缺少 Subversion，点「用 Homebrew 安装 Subversion」即可，应用会自己装好

## 本版更新

- 修正 `--selftest-menu` 自检在中文界面下的断言：原来用英文前缀匹配菜单标题，
  中文环境下会误报失败（应用功能本身没问题）。现在按本地化后的完整标题比对，
  并在中英文两种界面下都验证通过

## 上一版（1.0.4）

- 右键菜单：在文件夹行上右键新增「New Folder in “X”…」，可直接在该文件夹内新建
- 新增 `--selftest-menu`：走 AppKit 真正的事件入口验证右键菜单在
  空白处 / 文件夹行 / 文件行三种情况下的菜单项

## 登录信息

登录成功后账号密码存入系统钥匙串，默认 **30 天内免登录**；只有服务端验证通过的凭据才会保存。想换账号时用「MacSVN › 退出登录」立即清除。

## 界面语言

英文与简体中文，跟随系统语言自动切换（其他语言回落到英文）。

## 系统要求

- macOS 13 或更高
- 通用二进制：Apple 芯片与 Intel 均可（Intel 切片由同一份源码交叉编译，发布者手头没有 Intel 机器，未做真机验证；如遇问题请提 issue，或直接[从源码编译](https://github.com/Jas0nxlee/MacSVN#从源码构建与运行)）
- Subversion 可在应用内一键安装（通过 Homebrew），也可以自己 `brew install subversion`

## 文件校验

```
SHA256  @@SHA@@
```
NOTES_TEMPLATE

# 占位符替换（避免 sed 里出现斜杠问题，用 | 作分隔符）
sed -i '' "s|@@VERSION@@|${VERSION}|g; s|@@SHA@@|${SHA}|g" "$NOTES"

echo "==> 创建 GitHub Release $TAG"
gh release create "$TAG" "$ZIP" \
    --title "MacSVN $VERSION" \
    --notes-file "$NOTES" \
    --target "$(git rev-parse --abbrev-ref HEAD)"

echo
gh release view "$TAG" --json url,assets --jq '"发布地址：\(.url)\n附件：\(.assets[].name)"'
