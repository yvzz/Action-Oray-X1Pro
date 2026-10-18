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

# 2. Fix sysupgrade failure on oray,x1pro
#    U-Boot 未在设备树 chosen 节点设置 rootdisk 属性,
#    导致 export_fitblk_bootdev() 检测失败 → CI_METHOD 为空 → fit_do_upgrade return 1 → 固件未写入.
#    修复方式: 通过仓库 files/ overlay 覆盖 /lib/upgrade/fit.sh (见 files/lib/upgrade/fit.sh),
#    该文件已在 CI_METHOD 为空时 fallback 到 UBI 默认参数, 不依赖源码树路径探测, 更可靠.
#    (早期在 diy-part1.sh 里 sed 补丁源码树 fit.sh 的方式因路径探测不稳定已弃用)

# DTS/filogic.mk/02_network/platform.sh/MAC fix 已全部集成至上游源码
# 仓库路径: yvzz/immortalwrt-mt798x-6.6 openwrt-24.10-6.6 branch
# 无需本地 patch

echo "=== DIY Part 1 done ==="
