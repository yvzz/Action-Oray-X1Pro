#!/bin/sh
# ============================================================
# Oray X1 Pro 运维脚本下载器
# 无参数: 下载 down-scripts.sh 引导脚本 (推荐)
# 带 *.sh 参数: 仅下载该文件到 /root/
# 用法:  sh /root/get-scripts.sh [xxx.sh]
# 仓库:  https://gitee.com/vvvv/wrt-x1-pro
# ============================================================

REPO="https://gitee.com/vvvv/wrt-x1-pro/raw/master"
DEST_DIR="/root"

# 参数处理: 带 *.sh 参数 → 仅下载该文件; 否则 → 下载引导脚本
# 只接受「纯文件名」：不允许 / 、.. 或绝对路径。此前 "$1" 被直接拼进
# "$DEST_DIR/$name"，`sh get-scripts.sh ../../etc/rc.local` 就能写到任意路径。
if [ -n "$1" ]; then
  name="${1##*/}"
  case "$name" in
    *.sh) ;;
    *) echo "[ERROR] 只接受 .sh 文件: $1"; exit 1 ;;
  esac
  case "$name" in
    */*|.*|*..*) echo "[ERROR] 非法文件名: $1"; exit 1 ;;
    *[!A-Za-z0-9._-]*) echo "[ERROR] 文件名只允许字母/数字/._-: $1"; exit 1 ;;
  esac
  FILES="$name"
  MODE="single"
else
  FILES="down-scripts.sh"
  MODE="bootstrap"
fi

log(){ echo "  $*"; }

# 可选校验：仓库里若提供 <name>.sha256 就比对摘要，没有则跳过（保持向后兼容）
verify_sum(){
  local path="$1" name="$2" want got
  want=$(curl -fsSL --connect-timeout 10 -m 20 "$REPO/$name.sha256" 2>/dev/null | awk '{print $1}' | head -1)
  [ -n "$want" ] || return 0
  got=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
  [ -n "$got" ] || return 0
  if [ "$want" != "$got" ]; then
    log "[!] sha256 校验失败: 期望 $want, 实际 $got"
    return 1
  fi
  log "[ok] sha256 校验通过"
}

fetch_one(){
  local name="$1"
  local url="$REPO/$name"
  local dest="$DEST_DIR/$name"
  local tmp="$dest.tmp"
  local i
  log "下载 $name ..."
  for i in 1 2 3; do
    if curl -fsSL --connect-timeout 15 -m 60 -o "$tmp" "$url" 2>/dev/null; then
      # 校验: 非空 + 首行是 shebang + 有 .sha256 时比对摘要
      if [ -s "$tmp" ] && head -1 "$tmp" 2>/dev/null | grep -q '^#!'; then
        if verify_sum "$tmp" "$name"; then
          mv "$tmp" "$dest"
          chmod +x "$dest"
          log "[ok] $name -> $dest ($(wc -c < "$dest") 字节)"
          command -v sha256sum >/dev/null 2>&1 && log "     sha256: $(sha256sum "$dest" | awk '{print $1}')"
          return 0
        fi
      fi
    fi
    log "  [!] 第 $i 次下载失败/校验失败, 重试..."
    sleep 2
  done
  rm -f "$tmp"
  return 1
}

echo "=============================================="
echo " X1Pro 引导脚本下载"
echo "=============================================="

# 网络连通性预检
if ! curl -fsSL --connect-timeout 10 -m 15 -o /dev/null "https://gitee.com" 2>/dev/null; then
  echo "[ERROR] 无法连接 gitee.com, 请检查外网连通性"
  exit 1
fi

mkdir -p "$DEST_DIR" || { echo "[ERROR] 无法创建 $DEST_DIR"; exit 1; }

fail=0
for f in $FILES; do
  fetch_one "$f" || fail=$((fail + 1))
done

echo "=============================================="
if [ "$fail" -eq 0 ]; then
  if [ "$MODE" = "single" ]; then
    echo " 已下载: $DEST_DIR/$FILES"
  else
    echo " 引导脚本已下载: $DEST_DIR/down-scripts.sh"
    echo ""
    echo " 请执行以下命令获取操作脚本:"
    echo "   sh $DEST_DIR/down-scripts.sh 或 sh down-scripts.sh"
    echo ""
  fi
else
  echo " 下载失败, 请检查网络后重试: sh $DEST_DIR/get-scripts.sh"
fi
echo "=============================================="

exit "$fail"
