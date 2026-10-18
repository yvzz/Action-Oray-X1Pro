#!/bin/bash
# DIY Part 1: X1 Pro device setup
# 原则：最小化侵入，只 patch 不改写上游文件
# 幂等设计：重复运行不会重复追加条目
# 参考 TR3000：第三方包直接 clone 到 package/，不用 feeds
set -euo pipefail

WORKSPACE="$GITHUB_WORKSPACE"
OPENWRT="$WORKSPACE/openwrt"

echo "=== DIY Part 1: X1 Pro setup ==="

# 0. 拷贝内嵌的第三方包源码到构建树 package/
# 说明：luci-app-cloud-ddns 等包以源码形式内嵌在仓库 $WORKSPACE/package/ 下，
# 但 openwrt 构建树在 $OPENWRT/package/（/workdir/openwrt/package/），build job
# 不会整体 copy $GITHUB_WORKSPACE/package/，必须在此显式拷贝，make defconfig
# 才能扫描到这些包。参考 pushbot 的 clone 机制（也是写入 $OPENWRT/package/）。
for embedded_pkg in luci-app-cloud-ddns; do
  src="$WORKSPACE/package/$embedded_pkg"
  dest="$OPENWRT/package/$embedded_pkg"
  if [ -d "$src" ]; then
    rm -rf "$dest"
    cp -a "$src" "$dest"
    echo "  → embedded $embedded_pkg copied from $src"
  else
    echo "  [WARN] $src not found locally; content of \$WORKSPACE/package:" >&2
    ls -la "$WORKSPACE/package/" 2>&1 | head -20 >&2
    echo "  [info] cloning from github.com/yvzz/luci-app-cloud-ddns"
    rm -rf "$dest"
    if git clone --depth=1 "https://github.com/yvzz/luci-app-cloud-ddns" "$dest"; then
      echo "  → embedded $embedded_pkg cloned to $dest"
    else
      echo "  [ERROR] failed to clone $embedded_pkg" >&2
      exit 1
    fi
  fi
  if [ ! -f "$dest/Makefile" ]; then
    echo "  [ERROR] $embedded_pkg Makefile missing after copy/clone" >&2
    exit 1
  fi
  echo "  → embedded $embedded_pkg ready (Makefile present)"
done

# 1. Clone third-party packages into package/ (参照 TR3000)
#    直接 clone 避免 feeds 分支/index 问题
mkdir -p "$OPENWRT/package"
for repo in luci-theme-aurora luci-app-aurora-config luci-app-bandix openwrt-bandix luci-app-easytier luci-app-vnt2 luci-app-pushbot; do
  if [ -d "$OPENWRT/package/$repo" ]; then
    echo "  → $repo already exists, skipping clone"
  else
    case "$repo" in
      luci-theme-aurora)      url="https://github.com/eamonxg/luci-theme-aurora" ;;
      luci-app-aurora-config) url="https://github.com/eamonxg/luci-app-aurora-config" ;;
      luci-app-bandix)        url="https://github.com/timsaya/luci-app-bandix" ;;
      openwrt-bandix)         url="https://github.com/timsaya/openwrt-bandix" ;;
      luci-app-easytier)     url="https://github.com/EasyTier/luci-app-easytier" ;;
      luci-app-vnt2)         url="https://github.com/whzhni1/luci-app-vnt2" ;;
      luci-app-pushbot)      url="https://github.com/zzsj0928/luci-app-pushbot" ;;
    esac
    git clone --depth=1 "$url" "$OPENWRT/package/$repo"
  fi
done
echo "  → aurora + pushbot packages cloned"

# 1b2. NPC 升级到 0.34（djylb/nps-openwrt）
#   上游 immortalwrt/packages 的 net/nps 是 Go 源码编译、版本停在 0.26.24，
#   且同一个包同时产出 npc + nps 两个包。改用 djylb 的 npc 包（0.34.7，下载官方
#   预编译二进制；aarch64 → arm64 资产 linux_arm64_client.tar.gz）。
#   npc 0.34 废弃了 -config=<文件> 的启动方式，改用纯命令行参数
#   （-server= -vkey= -type= -dns_server= -log=），旧版 init 脚本与 LuCI 界面配置项
#   均不兼容，故旧 files/ 下的 npc 界面文件已移除，改由 luci-app-npc 包提供。
#   必须移除 feeds 的 net/nps：它同时定义 npc，否则 npc 会有两个提供者导致冲突。
NPS_OPENWRT_TARGET="$OPENWRT/package/nps-openwrt"
rm -rf "$NPS_OPENWRT_TARGET"
if git clone --depth 1 https://github.com/djylb/nps-openwrt "$NPS_OPENWRT_TARGET"; then
  echo "  → cloned nps-openwrt (npc 0.34.7)"
  rm -rf "$NPS_OPENWRT_TARGET/nps" "$NPS_OPENWRT_TARGET/luci-app-nps"
  removed=0
  for d in "$OPENWRT"/package/feeds/*/npc "$OPENWRT"/package/feeds/*/nps; do
    if [ -e "$d" ] || [ -L "$d" ]; then
      rm -rf "$d"
      echo "  → removed feeds conflict: ${d#$OPENWRT/}"
      removed=1
    fi
  done
  if [ "$removed" = 0 ]; then
    echo "  → [info] no feeds npc/nps package found to remove"
  fi
else
  echo "  → [WARN] failed to clone nps-openwrt; npc stays at feeds 0.26.24 without LuCI UI" >&2
fi

# 1b. Fix bandix Makefile: 将 zoneinfo-all 改为 zoneinfo-asia（.config 已启用）
BANDIX_MK="$OPENWRT/package/openwrt-bandix/openwrt-bandix/Makefile"
if [ -f "$BANDIX_MK" ]; then
  if grep -q 'zoneinfo-all' "$BANDIX_MK"; then
    sed -i 's/zoneinfo-all/zoneinfo-asia/g' "$BANDIX_MK"
    echo "  → bandix Makefile: zoneinfo-all → zoneinfo-asia"
  else
    echo "  → bandix Makefile: already updated or no zoneinfo dep"
  fi
fi

# 2. sysupgrade 修复 (oray,x1pro) —— 必须本地 patch，不能依赖上游
#    背景（2026-10-19 实测）：设备 platform.sh 把 oray,x1pro 放在 fit_do_upgrade
#    分支里，而 fit_do_upgrade 依赖 export_fitblk_bootdev 读设备树
#    chosen/rootdisk 来判定 CI_METHOD；本设备 DTS 的 chosen 节点没有 rootdisk，
#    于是 CI_METHOD 为空 → `fit_do_upgrade` 直接 return 1 → sysupgrade 在
#    platform_do_upgrade 阶段失败。
#    注意 sysupgrade --test 只做镜像校验、不执行 platform_do_upgrade，所以
#    --test 返回 0 完全测不出这个问题（现象：能上传、能校验、但刷不进去）。
#    上游 fork(yvzz/immortalwrt-mt798x-6.6) 至今仍把 oray,x1pro 留在 fit 分支
#    列表中（2026-10-18 编译的 #254 镜像内 platform.sh 已验证只有 `oray,x1pro|`
#    一行，没有 nand_do_upgrade 分支），故此处在 platform_do_upgrade 的 case
#    开头插入显式分支，使其优先命中，后面的 fit 分支自然不再生效。
PLATFORM_SH="$(find "$OPENWRT/target/linux" -name platform.sh -path '*upgrade*' 2>/dev/null | head -1 || true)"
if [ -n "$PLATFORM_SH" ] && [ -f "$PLATFORM_SH" ]; then
  if grep -q 'CI_ROOTPART="rootfs"' "$PLATFORM_SH"; then
    echo "  → platform.sh: oray,x1pro nand_do_upgrade 分支已存在，跳过"
  else
    python3 - "$PLATFORM_SH" <<'PYEOF'
import sys

path = sys.argv[1]
lines = open(path, encoding='utf-8').read().split('\n')

fn = next((n for n, l in enumerate(lines) if l.startswith('platform_do_upgrade()')), None)
if fn is None:
    print('  !! platform_do_upgrade() not found in %s' % path)
    sys.exit(1)

idx = None
for n in range(fn, len(lines)):
    if lines[n].strip() == 'case "$board" in':
        idx = n
        break
if idx is None:
    print('  !! case "$board" in not found after platform_do_upgrade()')
    sys.exit(1)

block = [
    '\toray,x1pro)',
    '\t\tCI_UBIPART="ubi"',
    '\t\tCI_KERNPART="kernel"',
    '\t\tCI_ROOTPART="rootfs"',
    '\t\tnand_do_upgrade "$1"',
    '\t\t;;',
]
lines[idx + 1:idx + 1] = block
open(path, 'w', encoding='utf-8').write('\n'.join(lines))
print('  → platform.sh: 插入 oray,x1pro nand_do_upgrade 分支 (行 %d)' % (idx + 2))
PYEOF
  fi
else
  echo "  [WARN] platform.sh not found under \$OPENWRT/target/linux" >&2
fi

# DTS/filogic.mk/02_network/platform.sh/MAC fix 已全部集成至上游源码
# 仓库路径: yvzz/immortalwrt-mt798x-6.6 openwrt-24.10-6.6 branch
# 无需本地 patch

echo "=== DIY Part 1 done ==="
