#!/bin/bash
# Acme-lsh 环境自检（只读，不修改任何文件）
# 用途：脚本报"未检测到可用的 acme.sh"时，用这个把真正的原因打出来。
echo "=== 1. 基本环境 ==="
echo "whoami  : $(id -un 2>/dev/null)"
echo "HOME    : ${HOME:-<空>}"
echo "bash    : $(command -v bash)  版本 $BASH_VERSION"
echo "LE_WORKING_DIR : ${LE_WORKING_DIR:-<未设置>}"
echo "ACME_PACKAGED  : ${ACME_PACKAGED:-<未设置>}"
echo

echo "=== 2. 候选路径探测（与脚本 acme_probe 完全相同的判定） ==="
for c in "${ACME_BIN:-}" "$HOME/.acme.sh/acme.sh" /root/.acme.sh/acme.sh /usr/local/bin/acme.sh /usr/bin/acme.sh; do
  [ -n "$c" ] || continue
  if [ ! -e "$c" ]; then echo "  $c : 不存在"; continue; fi
  if [ ! -x "$c" ]; then echo "  $c : 存在但不可执行"; continue; fi
  v=$("$c" -v 2>&1); rc=$?
  echo "  $c : 可执行  -v退出码=$rc"
  echo "        输出: $(printf '%s' "$v" | tr '\n' '|' | cut -c1-120)"
done
echo

echo "=== 3. acme.sh 文件本身 ==="
A="${ACME_BIN:-$HOME/.acme.sh/acme.sh}"
[ -f "$A" ] || A=/root/.acme.sh/acme.sh
ls -l "$A" 2>&1
echo "大小: $(wc -c < "$A" 2>/dev/null) 字节"
echo "头两行: $(head -n 2 "$A" 2>/dev/null | tr '\n' '|')"
echo

echo "=== 4. 关键命令能否工作 ==="
echo "--- \$A -v ---";        "$A" -v; echo "退出码=$?"
echo "--- \$A --version ---"; "$A" --version 2>&1 | tail -n 2; echo "退出码=${PIPESTATUS[0]}"
echo "--- \$A --list --listraw ---"
"$A" --list --listraw 2>&1 | head -n 4
echo "退出码=${PIPESTATUS[0]}"
echo

echo "=== 5. 直接执行（走 shebang）能否工作 ==="
"$A" -v >/dev/null 2>&1; echo "直接执行退出码=$?"
echo "shebang: $(head -n 1 "$A")"
echo

echo "=== 6. 当前 crontab ==="
crontab -l 2>&1 | head -n 5
echo

echo "=== 7. 已有证书 ==="
"$A" --list 2>&1 | head -n 10
echo
echo "=== 自检结束 ==="
