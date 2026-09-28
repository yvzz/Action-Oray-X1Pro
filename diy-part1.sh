#!/bin/bash
# DIY Part 1: X1 Pro device setup
# 原则：最小化侵入，只 patch 不改写上游文件
# 幂等设计：重复运行不会重复追加条目
# 参考 TR3000：第三方包直接 clone 到 package/，不用 feeds
set -euo pipefail

WORKSPACE="$GITHUB_WORKSPACE"
OPENWRT="$WORKSPACE/openwrt"

echo "=== DIY Part 1: X1 Pro setup ==="

# 1. Clone third-party packages into package/ (参照 TR3000)
#    直接 clone 避免 feeds 分支/index 问题
mkdir -p "$OPENWRT/package"
for repo in luci-theme-aurora luci-app-aurora-config luci-app-bandix openwrt-bandix luci-app-easytier luci-app-vnt2; do
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
    esac
    git clone --depth=1 "$url" "$OPENWRT/package/$repo"
  fi
done
echo "  → aurora packages cloned"

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

# 2. Fix sysupgrade failure on oray,x1pro
#    U-Boot 未在设备树 chosen 节点设置 rootdisk 属性,
#    导致 export_fitblk_bootdev() 检测失败 → CI_METHOD 为空 → fit_do_upgrade return 1 → 固件未写入.
#    补丁: CI_METHOD 为空时 fallback 到 UBI 默认参数 (ubi/kernel/rootfs).
#    关键: 源码树里存在【多个】fit.sh:
#      - 通用 OpenWrt fit.sh (package/feeds base-files, 不含 export_fitblk_bootdev, 补丁对其无效)
#      - mt798x 专用 fit.sh (含 export_fitblk_bootdev + CI_METHOD, 才是本机真正的升级逻辑)
#    必须定位到【含 export_fitblk_bootdev】的那个并打补丁, 否则会命中通用版而静默跳过.
FIT_SH=""
for cand in \
  "$OPENWRT/target/linux/mediatek/base-files/lib/upgrade/fit.sh" \
  "$OPENWRT/target/linux/mediatek/filogic/base-files/lib/upgrade/fit.sh" \
  "$OPENWRT/target/linux/mediatek/mt798x/base-files/lib/upgrade/fit.sh" \
  "$OPENWRT/package/base-files/files/lib/upgrade/fit.sh" \
  "$OPENWRT/feeds/base-files/files/lib/upgrade/fit.sh" ; do
  if [ -f "$cand" ] && grep -q "export_fitblk_bootdev" "$cand"; then
    FIT_SH="$cand"; break
  fi
done
# 兜底: 全盘搜索含 export_fitblk_bootdev 的 fit.sh (排除 build_dir / staging_dir 产物)
if [ -z "$FIT_SH" ]; then
  FIT_SH=$(find "$OPENWRT" -name fit.sh \
    -not -path "*/build_dir/*" -not -path "*/staging_dir/*" 2>/dev/null \
    -exec grep -l "export_fitblk_bootdev" {} \; | head -1)
fi

if [ -n "$FIT_SH" ]; then
  if grep -q 'CI_ROOTPART="rootfs"' "$FIT_SH"; then
    echo "  → fit.sh: already patched ($FIT_SH)"
  else
    sed -i 's/\[ -n "\$CI_METHOD" \] || return 1/[ -n "$CI_METHOD" ] || { CI_METHOD="ubi"; CI_UBIPART="ubi"; CI_KERNPART="kernel"; CI_ROOTPART="rootfs"; }/' "$FIT_SH"
    if grep -q 'CI_ROOTPART="rootfs"' "$FIT_SH"; then
      echo "  → fit.sh: patched ($FIT_SH)"
    else
      echo "  → [WARN] fit.sh patch failed (pattern not found in $FIT_SH)"
    fi
  fi
else
  echo "  → [WARN] fit.sh not found (含 export_fitblk_bootdev), skipping sysupgrade fix"
fi

# DTS/filogic.mk/02_network/platform.sh/MAC fix 已全部集成至上游源码
# 仓库路径: yvzz/immortalwrt-mt798x-6.6 openwrt-24.10-6.6 branch
# 无需本地 patch

echo "=== DIY Part 1 done ==="
