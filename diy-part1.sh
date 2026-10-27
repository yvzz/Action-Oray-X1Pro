#!/bin/bash
# Apply the X1 Pro device port to the pinned ImmortalWrt source tree.
set -euo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" && pwd)}"
OPENWRT="${OPENWRT_DIR:-$WORKSPACE/openwrt}"

# 0. Clone luci-app-cloud-ddns from GitHub（始终从上游拉取，不内嵌源码）
CLOUDDDNS_DEST="$OPENWRT/package/luci-app-cloud-ddns"
rm -rf "$CLOUDDDNS_DEST"
if git clone --depth=1 "https://github.com/yvzz/luci-app-cloud-ddns" "$CLOUDDDNS_DEST"; then
	echo "[ok] luci-app-cloud-ddns cloned from GitHub"
else
	echo "ERROR: failed to clone luci-app-cloud-ddns" >&2
	exit 1
fi
if [ ! -f "$CLOUDDDNS_DEST/Makefile" ]; then
	echo "ERROR: luci-app-cloud-ddns Makefile missing after clone" >&2
	exit 1
fi
echo "[ok] luci-app-cloud-ddns ready (Makefile present)"

DEVICE_SOURCE="$WORKSPACE/devices/mt7981b-oray-x1-pro.dts"
DEVICE_TARGET="$OPENWRT/target/linux/mediatek/dts/mt7981b-oray-x1-pro.dts"
DEVICE_PATCH="$WORKSPACE/patches/0001-mediatek-filogic-add-oray-x1-pro.patch"

if ! git -C "$OPENWRT" rev-parse --git-dir >/dev/null 2>&1; then
	echo "ERROR: ImmortalWrt source tree not found: $OPENWRT" >&2
	exit 1
fi

install -m 0644 "$DEVICE_SOURCE" "$DEVICE_TARGET"

if git -C "$OPENWRT" apply --reverse --check "$DEVICE_PATCH" 2>/dev/null; then
	echo "X1 Pro source patch is already applied"
elif git -C "$OPENWRT" apply --check "$DEVICE_PATCH"; then
	git -C "$OPENWRT" apply "$DEVICE_PATCH"
	echo "Applied X1 Pro source patch"
else
	echo "ERROR: X1 Pro source patch does not apply to the selected source" >&2
	exit 1
fi

# ---- Aurora theme (clone single LuCI package into package/) ----
# eamonxg aurora 是单个 LuCI 包（非 feed，feed 索引器不识别根目录无子包列表的仓库），
# 需 clone 到 package/ 由 buildroot 自动扫描。若 clone 失败仅告警、不阻塞构建：
# 缺包时 make defconfig 会静默丢弃对应 CONFIG_PACKAGE_*=y 符号，固件将不带主题但仍可编译。
for pkg in luci-theme-aurora luci-app-aurora-config; do
	repo="https://github.com/eamonxg/${pkg}.git"
	target="$OPENWRT/package/${pkg}"
	rm -rf "$target"
	if git clone --depth 1 "$repo" "$target"; then
		echo "[ok] cloned ${pkg} into package/"
	else
		echo "WARNING: failed to clone ${pkg} from ${repo}; firmware will build without this theme package" >&2
	fi
done

# ---- EasyTier (一仓多包: easytier core + easytier-noweb + luci-app-easytier + i18n) ----
# 与 24.10 分支同源同方式: 官方仓库 EasyTier/luci-app-easytier 同时提供
# easytier 核心包与 luci-app-easytier 界面包（luci.mk 自动生成 luci-i18n-easytier-<lang>），
# 未进 feeds，需 clone 到 package/ 由 buildroot 两层目录扫描自动识别。
# 依赖 kmod-tun + luci-compat（三份 config 均已启用）；若 clone 失败仅告警不阻塞，
# 此时 make defconfig 会静默丢弃 CONFIG_PACKAGE_easytier / luci-app-easytier 符号。
EASYTIER_TARGET="$OPENWRT/package/luci-app-easytier"
rm -rf "$EASYTIER_TARGET"
if git clone --depth 1 https://github.com/EasyTier/luci-app-easytier "$EASYTIER_TARGET"; then
	echo "[ok] cloned luci-app-easytier (含 easytier core) into package/"
else
	echo "WARNING: failed to clone luci-app-easytier; firmware will build without EasyTier" >&2
fi

# ---- VNT2 (whzhni1/luci-app-vnt2: 纯 LuCI 界面包) ----
# 仓库顶层仅含单一包目录 luci-app-vnt2/（Makefile + htdocs + po + root），
# 是 ucode + JS 的纯界面包（LUCI_PKGARCH:=all），不含 vnt/vnts 核心程序。
# 核心二进制 vnt2_cli / vnt2_web / vnt2_ctrl / vnts2 由设备在 LuCI 界面「更新」时
# 从 GitHub / Gitee / GitLab / Cloudflare 镜像自行下载（架构自动探测为 aarch64）。
# 依赖 luci-base + luci-compat + kmod-tun（三份 config 均已具备）；
# clone 失败仅告警不阻塞，此时 make defconfig 会静默丢弃对应 CONFIG_PACKAGE_* 符号。
VNT2_TARGET="$OPENWRT/package/luci-app-vnt2"
rm -rf "$VNT2_TARGET"
if git clone --depth 1 https://github.com/whzhni1/luci-app-vnt2 "$VNT2_TARGET"; then
	echo "[ok] cloned luci-app-vnt2 (纯界面包) into package/"
else
	echo "WARNING: failed to clone luci-app-vnt2; firmware will build without VNT2" >&2
fi

# ---- Fix VNT2 postinst/prerm/postrm: vnt2-package.sh 在 package/install 阶段可能未就位 ----
# VNT2 的 Makefile 定义了 postinst 调用 /usr/libexec/vnt2/vnt2-package.sh，
# 但该文件在 package/install 执行时可能尚未安装到目标路径，导致 bash 报 127
#（No such file or directory）→ 整个构建失败。
# 实际上 vnt2-package.sh 首行已检查 IPKG_INSTROOT 并 exit 0（构建阶段不执行），
# 但文件不存在时 bash 在调用前就报错了。加 [ -f ] 守卫让构建跳过。
# 注意：Makefile 里是 "$$@"（Makefile 转义），正则必须用行级匹配 + 捕获组
# 保留尾部，不能直接匹配 "$@"（曾因此失配，修复静默无效）。
VNT2_MK="$OPENWRT/package/luci-app-vnt2/luci-app-vnt2/Makefile"
if [ -f "$VNT2_MK" ]; then
	if grep -q '/usr/libexec/vnt2/vnt2-package.sh postinst' "$VNT2_MK"; then
		perl -pi -e 's{^(/usr/libexec/vnt2/vnt2-package\.sh) (\w+)( .*)$}{[ -f $1 ] \&\& $1 $2$3 || true}' "$VNT2_MK"
		if grep -q '\[ -f /usr/libexec/vnt2/vnt2-package.sh \]' "$VNT2_MK"; then
			echo "[ok] VNT2 Makefile: postinst/prerm/postrm 加文件存在性检查"
		else
			echo "ERROR: VNT2 Makefile patch did not apply!" >&2
			exit 1
		fi
	else
		echo "[info] VNT2 Makefile 无需修补（postinst 格式已变或已修复）"
	fi
else
	echo "WARNING: VNT2 Makefile not found at $VNT2_MK" >&2
fi

# ---- 全能推送 (zzsj0928/luci-app-pushbot) ----
# 仓库顶层为单一包 luci-app-pushbot/（Makefile + htdocs + po + root），
# v6.01 起纯 ucode 架构（LUCI_PKGARCH:=all），平台无关，需 LuCI ≥ 23.05。
# clone 到 package/ 由 buildroot 自动扫描。
# 依赖：iputils-arping + curl + jq（三份 config 均已启用 curl；arping 和 jq 需显式选中）。
# clone 失败仅告警不阻塞，此时 make defconfig 会静默丢弃 CONFIG_PACKAGE_luci-app-pushbot 符号。
PUSHBOT_TARGET="$OPENWRT/package/luci-app-pushbot"
rm -rf "$PUSHBOT_TARGET"
if git clone --depth 1 https://github.com/zzsj0928/luci-app-pushbot "$PUSHBOT_TARGET"; then
	echo "[ok] cloned luci-app-pushbot (全能推送) into package/"
else
	echo "WARNING: failed to clone luci-app-pushbot; firmware will build without PushBot" >&2
fi

# ---- NPC 升级到 0.34 (djylb/nps-openwrt) ----
# 上游 immortalwrt/packages 的 net/nps 是 Go 源码编译、版本停在 0.26.24，且同一个包
# 同时产出 npc + nps。改用 djylb 的 npc 包（0.34.7，下载官方预编译二进制；
# aarch64 → arm64 资产 linux_arm64_client.tar.gz）。
# npc 0.34 废弃了 -config=<文件> 的启动方式，改用纯命令行参数
# （-server= -vkey= -type= -dns_server= -log=），旧版 init 与 LuCI 配置项不兼容，
# 故旧的 files/ npc 界面文件已移除，改由 luci-app-npc 包提供。
# 必须移除 feeds 的 net/nps：它同时定义 npc，否则 npc 会有两个提供者导致冲突。
NPS_OPENWRT_TARGET="$OPENWRT/package/nps-openwrt"
rm -rf "$NPS_OPENWRT_TARGET"
if git clone --depth 1 https://github.com/djylb/nps-openwrt "$NPS_OPENWRT_TARGET"; then
	echo "[ok] cloned nps-openwrt (npc 0.34.7)"
	rm -rf "$NPS_OPENWRT_TARGET/nps" "$NPS_OPENWRT_TARGET/luci-app-nps"
	removed=0
	for d in "$OPENWRT"/package/feeds/*/npc "$OPENWRT"/package/feeds/*/nps; do
		if [ -e "$d" ] || [ -L "$d" ]; then
			rm -rf "$d"
			echo "[ok] removed feeds conflict: ${d#$OPENWRT/}"
			removed=1
		fi
	done
	if [ "$removed" = 0 ]; then
		echo "[info] no feeds npc/nps package found to remove"
	fi
else
	echo "WARNING: failed to clone nps-openwrt; npc stays at feeds 0.26.24 without LuCI UI" >&2
fi

# ---- Fix sysupgrade failure on oray,x1pro ----
# U-Boot 未在设备树 chosen 节点设置 rootdisk 属性,
# 导致 export_fitblk_bootdev() 检测失败 → CI_METHOD 为空 → fit_do_upgrade return 1 → 固件未写入.
# 修复方式: 通过仓库 files/ overlay 覆盖 /lib/upgrade/fit.sh (见 files/lib/upgrade/fit.sh),
# 该文件已在 CI_METHOD 为空时 fallback 到 UBI 默认参数, 不依赖源码树路径探测, 更可靠.
# (早期在 diy-part1.sh 里 sed 补丁源码树 fit.sh 的方式因路径探测不稳定已弃用)

# ---- Rust host-compile fix (merged from diy-part2.sh — that script is NOT called by the workflow) ----
# rustc 1.94.0's bootstrap fetches a prebuilt CI LLVM tarball; the URL 404s because
# old CI artifacts get pruned from ci-artifacts.rust-lang.org. Disable download-ci-llvm
# so bootstrap builds LLVM from source instead. Matched string in the rust Makefile:
#   --set=llvm.download-ci-llvm=true   ->   --set=llvm.download-ci-llvm=false
RUST_MK="$OPENWRT/feeds/packages/lang/rust/Makefile"
if [ -f "$RUST_MK" ]; then
	if grep -q 'download-ci-llvm=true' "$RUST_MK"; then
		sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$RUST_MK"
		echo "[ok] disabled download-ci-llvm in rust Makefile (was 404-ing on ci-artifacts.rust-lang.org)"
	else
		echo "[info] rust Makefile has no download-ci-llvm=true (already patched or upstream changed)"
	fi
else
	echo "WARNING: rust Makefile not found at $RUST_MK; rust host-compile may fail with 404" >&2
fi

# ---- Fix: dl/ 缓存被上游改版污染后无法自愈（npc 0.34.7 -> 0.34.9 触发过一次）----
# download.pl 遇到「本地已有同名文件、但 hash 与 Makefile 要求不一致」时，正确行为是
# 删除旧文件后重新下载。immortalwrt v25.12.1 这份脚本把 die 写在了 unlink 之前：
#     die "Hash of the local file ... does not match - deleting download.\n";
#     unlink "$target/$filename";        ← 位于 die 之后，永远不会执行
# 于是坏文件永远留在 dl/（由 Actions cache 恢复而来），每次 make 都在同一处 Error 2
# 且无法自愈（OpenWrt 官方是 unlink 在 die 之前，重跑一次即可恢复）。
# 这里把 die 降级为 print STDERR：本次就删除旧文件并重新下载，无需重跑整轮编译。
DL_PL="$OPENWRT/scripts/download.pl"
if [ -f "$DL_PL" ]; then
	if grep -q 'die "Hash of the local file' "$DL_PL"; then
		perl -0pi -e 's/\bdie "Hash of the local file/print STDERR "Hash of the local file/' "$DL_PL"
		echo "[ok] download.pl: hash 不匹配时改为删除旧文件并重新下载（原 die 会跳过 unlink）"
	else
		echo "[info] download.pl 无需修补（已是删除后重试，或上游已修复）"
	fi
else
	echo "WARNING: scripts/download.pl not found at $DL_PL" >&2
fi

# ---- Build date in firmware filename (merged from diy-part2.sh) ----
IMG_MK="$OPENWRT/include/image.mk"
if [ -f "$IMG_MK" ] && ! grep -q 'BUILD_DATE := $(shell date' "$IMG_MK"; then
	sed -i -e '/^IMG_PREFIX:=/i BUILD_DATE := $(shell date +%Y%m%d)' \
	       -e '/^IMG_PREFIX:=/ s/\($(SUBTARGET)\)/\1-$(BUILD_DATE)/' "$IMG_MK"
	echo "[ok] added BUILD_DATE to firmware filename prefix"
fi
