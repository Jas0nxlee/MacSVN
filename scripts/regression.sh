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

printf 'renamable\n' > "$WORK/local/rename-me.txt"
if svnmucc -m "seed rename" put "$WORK/local/rename-me.txt" "$FILE_URL/trunk/rename-me.txt" >/dev/null 2>&1; then
    ok "准备 rename-me.txt"
else
    bad "准备 rename-me.txt 失败"
fi
expect_ok "重命名" "$BIN" --headless-op "$FILE_URL/trunk" renamed.txt rename-me.txt
expect_ok "删除" "$BIN" --headless-op "$FILE_URL/trunk" delete renamed.txt

# ---------------------------------------------------------------- 依赖安装
step "依赖安装（Homebrew 路径）"
if [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; then
    expect_ok "brew 安装流程自检（含无 Homebrew / 脚本生成 / 失败分支）" "$BIN" --selftest-brew
else
    printf '  \033[33m·\033[0m 本机没有 Homebrew，跳过安装自检\n'
fi

# ---------------------------------------------------------------- 登录
step "账户验证"
if svn auth "*127.0.0.1:${PORT}*" 2>/dev/null | grep -q "Credential kind"; then
    bad "本机仍缓存着本次测试服务器的凭据，登录用例无效"
else
    ok "本机无该服务器缓存凭据（登录用例有效）"
fi
expect_ok "需要认证时弹出登录框并登录成功" \
    "$BIN" --headless-login "$SVN_URL" "$USER_NAME" "$PASS_WORD"
expect_fail "密码错误时拒绝登录" \
    "$BIN" --headless-login "$SVN_URL" "$USER_NAME" "definitely-wrong"

# ---------------------------------------------------------------- 汇总
step "结果"
printf '  通过 %d 项，失败 %d 项\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '  失败项：\n'
    for item in "${failures[@]}"; do printf '    - %s\n' "$item"; done
    exit 1
fi
printf '  \033[32m全部通过\033[0m\n'
