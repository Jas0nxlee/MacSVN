#!/bin/bash
# 端到端回归测试：建一个临时仓库 + 带认证的 svnserve，跑完所有核心流程。
# 用法: ./scripts/regression.sh [工作目录]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-/tmp/macsvn-regression}"
# 每次用不同端口 → 认证 realm 唯一，避免命中上一次遗留在钥匙串里的凭据
PORT="${MACSVN_TEST_PORT:-$((3700 + RANDOM % 200))}"
USER_NAME="testuser"
PASS_WORD="testpass"

# 始终用最新编译产物，避免跑到过期的 .app
swift build --package-path "$ROOT" >/dev/null 2>&1 || {
    printf 'swift build 失败，请先修复编译错误\n' >&2
    exit 1
}
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/MacSVN"
if [ ! -x "$BIN" ]; then
    printf '找不到可执行文件：%s\n' "$BIN" >&2
    exit 1
fi

pass=0
fail=0
declare -a failures

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); failures+=("$1"); printf '  \033[31m✗\033[0m %s\n' "$1"; }

expect_ok() {
    local label="$1"; shift
    if "$@" >"$WORK/last.log" 2>&1; then ok "$label"; else bad "$label"; sed 's/^/      /' "$WORK/last.log"; fi
}

expect_fail() {
    local label="$1"; shift
    if "$@" >"$WORK/last.log" 2>&1; then bad "${label}（预期失败却成功了）"; else ok "$label"; fi
}

cleanup() {
    pkill -f "svnserve -d --foreground -r $WORK" 2>/dev/null
    # 清掉本次测试可能写进 ~/.subversion 与钥匙串的凭据
    svn auth --remove "*127.0.0.1:${PORT}*" >/dev/null 2>&1
    # MacSVN 自己保存的登录信息（service=MacSVN，account=<scheme>://host:port）
    security delete-generic-password -s MacSVN -a "svn://127.0.0.1:${PORT}" >/dev/null 2>&1
    security delete-generic-password -s MacSVN -a "http://127.0.0.1:${PORT}" >/dev/null 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------- 准备环境
step "准备测试仓库 $WORK"
cleanup
rm -rf "$WORK"
mkdir -p "$WORK/repo" "$WORK/seed/trunk/docs" "$WORK/local"
svnadmin create "$WORK/repo"
printf 'readme v1\n' > "$WORK/seed/trunk/readme.txt"
printf 'guide v1\n' > "$WORK/seed/trunk/docs/guide.md"
printf 'target placeholder\n' > "$WORK/seed/trunk/.keep"
svn import -q -m "init" "$WORK/seed" "file://$WORK/repo" >/dev/null 2>&1
svn mkdir -q -m "target dir" "file://$WORK/repo/trunk/target-dir" >/dev/null 2>&1
ok "仓库已就绪（$(svnlook youngest "$WORK/repo") 版本）"

cat > "$WORK/repo/conf/svnserve.conf" <<EOF
[general]
anon-access = none
auth-access = write
password-db = passwd
realm = RegressionRepo
EOF
cat > "$WORK/repo/conf/passwd" <<EOF
[users]
$USER_NAME = $PASS_WORD
EOF
nohup svnserve -d --foreground -r "$WORK" --listen-port "$PORT" >"$WORK/svnserve.log" 2>&1 &
disown 2>/dev/null || true     # 退出时不要打印 “Terminated” 噪音
sleep 1.5
if svn list --non-interactive --no-auth-cache --username "$USER_NAME" --password "$PASS_WORD" \
        "svn://127.0.0.1:${PORT}/repo" >/dev/null 2>&1; then
    ok "svnserve 已启动（svn://127.0.0.1:${PORT}）"
else
    bad "svnserve 启动失败"; sed 's/^/      /' "$WORK/svnserve.log"; exit 1
fi

FILE_URL="file://$WORK/repo"
SVN_URL="svn://127.0.0.1:$PORT/repo"

# ---------------------------------------------------------------- 核心自检
step "核心自检（svn / svnmucc 全流程 + 边界用例）"
expect_ok "file:// 仓库自检" "$BIN" --selftest "$FILE_URL"
expect_ok "svn:// 认证仓库自检" "$BIN" --selftest "$SVN_URL" "$USER_NAME" "$PASS_WORD"

# ---------------------------------------------------------------- 界面流程演练
step "界面流程演练（真实事件循环，走 BrowserModel）"
printf 'hello\n' > "$WORK/local/note.txt"
mkdir -p "$WORK/local/batch"
printf 'inner v1\n' > "$WORK/local/batch/inner.md"

expect_ok "拖入上传（新增）" \
    "$BIN" --headless-upload "$FILE_URL/trunk" - "$WORK/local/note.txt" "$WORK/local/batch"
printf 'hello v2\n' > "$WORK/local/note.txt"
expect_ok "拖入上传（重名覆盖）" \
    "$BIN" --headless-upload "$FILE_URL/trunk" - "$WORK/local/note.txt" "$WORK/local/batch"

if svn cat "$FILE_URL/trunk/note.txt" 2>/dev/null | grep -q "hello v2"; then
    ok "覆盖后内容为 v2"
else
    bad "覆盖后内容不是 v2"
fi

expect_ok "拖到子目录上传" \
    "$BIN" --headless-upload "$FILE_URL/trunk" batch "$WORK/local/note.txt"

printf 'movable\n' > "$WORK/local/moveme.txt"
if svnmucc -m "seed movable" put "$WORK/local/moveme.txt" "$FILE_URL/trunk/moveme.txt" >/dev/null 2>&1; then
    ok "准备 moveme.txt"
else
    bad "准备 moveme.txt 失败"
fi
expect_ok "库内拖动移动文件" "$BIN" --headless-move "$FILE_URL/trunk" moveme.txt target-dir
expect_ok "库内拖动移动目录" "$BIN" --headless-move "$FILE_URL/trunk" batch target-dir

svnmucc -m "seed movable again" put "$WORK/local/moveme.txt" "$FILE_URL/trunk/moveme.txt" >/dev/null 2>&1
expect_ok "目标已有同名项时被拦下" \
    sh -c "'$BIN' --headless-move '$FILE_URL/trunk' moveme.txt target-dir | grep -q '按预期拦下\|已存在同名'"

# 库内复制（服务端 cp，不经过本地）
step "库内复制"
expect_ok "复制文件到其它目录" \
    "$BIN" --headless-copy "$FILE_URL/trunk" note.txt target-dir
expect_ok "复制文件夹（含子目录）到其它目录" \
    "$BIN" --headless-copy "$FILE_URL/trunk" docs target-dir
expect_ok "目标就是源所在目录时被拦下" sh -c \
    "'$BIN' --headless-copy '$FILE_URL/trunk' note.txt - | grep -q '按预期拦下'"
expect_ok "目标目录不存在时被拦下" sh -c \
    "'$BIN' --headless-copy '$FILE_URL/trunk' note.txt no-such-folder | grep -q '按预期拦下'"
expect_ok "复制时可以改名" \
    "$BIN" --headless-copy "$FILE_URL/trunk" note.txt target-dir "改名后的副本.txt"
expect_ok "改名非法（含斜杠）被拦下" sh -c \
    "'$BIN' --headless-copy '$FILE_URL/trunk' note.txt target-dir 'bad/name.txt' | grep -q '改名后被判定为不可用'"

printf 'renamable\n' > "$WORK/local/rename-me.txt"
if svnmucc -m "seed rename" put "$WORK/local/rename-me.txt" "$FILE_URL/trunk/rename-me.txt" >/dev/null 2>&1; then
    ok "准备 rename-me.txt"
else
    bad "准备 rename-me.txt 失败"
fi
expect_ok "新建文件夹（当前目录）" \
    "$BIN" --headless-newfolder "$FILE_URL/trunk" - "新建目录"
# 注意：batch 在这一步之前已被“库内拖动移动目录”移走，这里用 target-dir 当父目录
expect_ok "新建文件夹（在指定文件夹内）" \
    "$BIN" --headless-newfolder "$FILE_URL/trunk" target-dir "子目录里的新目录"
expect_ok "重命名" "$BIN" --headless-op "$FILE_URL/trunk" renamed.txt rename-me.txt
expect_ok "删除" "$BIN" --headless-op "$FILE_URL/trunk" delete renamed.txt

step "右键菜单"
expect_ok "空白处 / 文件夹行 / 文件行的菜单项" "$BIN" --selftest-menu "$FILE_URL/trunk"

step "地址编解码"
expect_ok "中文 / 空格地址的编码与显示解码" "$BIN" --selftest-paths

step "登录信息存储（钥匙串）"
expect_ok "保存 / 到期失效 / 注销自检" "$BIN" --selftest-credentials

# ---------------------------------------------------------------- 依赖安装
step "依赖安装（Homebrew 路径）"
if [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; then
    expect_ok "brew 安装流程自检（含无 Homebrew / 脚本生成 / 失败分支）" "$BIN" --selftest-brew
else
    printf '  \033[33m·\033[0m 本机没有 Homebrew，跳过安装自检\n'
fi

# 中文目录：地址栏显示解码后的文字，回车后仍要能打开
svn mkdir -q -m "chinese dir" "$FILE_URL/trunk/其他" >/dev/null 2>&1
printf 'x\n' > "$WORK/local/报告.txt"
svnmucc -m "chinese file" put "$WORK/local/报告.txt" "$FILE_URL/trunk/其他/报告.doc" >/dev/null 2>&1
expect_ok "中文路径（显示形态）可直接访问" "$BIN" --headless-open "$FILE_URL/trunk/其他" silent
expect_ok "中文路径（编码形态）同样可访问" \
    "$BIN" --headless-open "$FILE_URL/trunk/%E5%85%B6%E4%BB%96" silent

# ---------------------------------------------------------------- 登录
step "账户验证"
if svn auth "*127.0.0.1:${PORT}*" 2>/dev/null | grep -q "Credential kind"; then
    bad "本机仍缓存着本次测试服务器的凭据，登录用例无效"
else
    ok "本机无该服务器缓存凭据（登录用例有效）"
fi
expect_ok "首次访问要求登录" "$BIN" --headless-open "$SVN_URL" prompt
expect_ok "需要认证时弹出登录框并登录成功" \
    "$BIN" --headless-login "$SVN_URL" "$USER_NAME" "$PASS_WORD"
expect_ok "登录信息被记住（再次访问免输入）" "$BIN" --headless-open "$SVN_URL" silent
expect_ok "退出登录清除已保存信息" "$BIN" --headless-logout "$SVN_URL"
expect_ok "退出后重新要求登录" "$BIN" --headless-open "$SVN_URL" prompt

# 密码错误的分支：单独验证，不污染上面的状态
expect_fail "密码错误时拒绝登录" \
    "$BIN" --headless-login "$SVN_URL" "$USER_NAME" "definitely-wrong"
expect_ok "密码错误不会写入钥匙串" sh -c \
    "! security find-generic-password -s MacSVN -a '$(echo "$SVN_URL" | sed 's#/[^/]*$##')' >/dev/null 2>&1"

# ---------------------------------------------------------------- 汇总
step "结果"
printf '  通过 %d 项，失败 %d 项\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '  失败项：\n'
    for item in "${failures[@]}"; do printf '    - %s\n' "$item"; done
    exit 1
fi
printf '  \033[32m全部通过\033[0m\n'
