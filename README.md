# Oray X1 Pro ImmortalWrt 固件

本仓库为 Oray X1 Pro 构建多配置固件（`none` / `openclash` / `homeproxy` / `vpn`）。源码固定为官方
[ImmortalWrt `v25.12.1`](https://github.com/immortalwrt/immortalwrt/releases/tag/v25.12.1)
（commit `a3378d1a2c15beb2faf4b0bce9c00f07143efa29`），避免构建结果随分支移动。

## 固件内容

预装内容包括基础路由与 Wi-Fi、LuCI HTTPS 中文界面、USB3 存储与自动挂载、USB 网络共享，以及 `firewall4`、`dnsmasq-full`、nftables TProxy、TUN/ip-full 等代理基础依赖。

各配置的差异（见 `config/`）：

| 配置 | 文件 | 附加内容 |
| --- | --- | --- |
| `none` | `x1pro.config` | 不含代理软件 |
| `openclash` | `x1pro-openclash.config` | OpenClash（`luci-app-openclash`）+ Ruby 3.4 运行环境 + `kmod-nft-tproxy` |
| `homeproxy` | `x1pro-homeproxy.config` | HomeProxy + sing-box |
| `vpn` | `x1pro-vpn.config` | L2TP/IPsec 客户端与配套 hotplug 脚本 |

OpenClash 的内核（clash/meta）不随固件打包，首次使用需在 LuCI 的「OpenClash → 版本更新」中下载。

以下内容不再预装：PassWall、旧 iptables 代理组件、WireGuard。

## X1 Pro 设备移植

官方 `v25.12.1` 没有 X1 Pro 设备项。本仓库在构建时应用
[`patches/0001-mediatek-filogic-add-oray-x1-pro.patch`](patches/0001-mediatek-filogic-add-oray-x1-pro.patch)，
并加入 X1 Pro DTS。升级格式恢复为原仓库的 `sysupgrade.bin`，分区、MAC 和
Wi-Fi 校准位置仍采用 X1 Pro 原布局：

| 分区 | 起始地址 | 大小 | 固件行为 |
| --- | ---: | ---: | --- |
| BL2 | `0x000000` | 1 MiB | 只读 |
| u-boot-env | `0x100000` | 512 KiB | 只读 |
| Factory | `0x180000` | 2 MiB | 只读；Wi-Fi 校准 `+0x0`，Wi-Fi MAC `+0x4`，网口 MAC `+0xe000` |
| FIP | `0x380000` | 2 MiB | 只读 |
| bdinfo | `0x580000` | 512 KiB | 只读 |
| kpanic | `0x600000` | 2 MiB | 保留 |
| ubi | `0x800000` | 112 MiB | 只写此处的 `kernel`/`rootfs`/`rootfs_data` 卷 |

本项目不构建 BL2/FIP，也不包含写入 Factory 或 bdinfo 的步骤。

## 当前 U-Boot 是否支持

配套的 [`yvzz/bl-mt798x-dhcpd`](https://github.com/yvzz/bl-mt798x-dhcpd)
源码支持解析 OpenWrt sysupgrade TAR：其 Web 固件升级代码会把 `.bin` 中的内核
和 rootfs 分别写入 UBI 的 `kernel`、`rootfs` 卷，并创建 `rootfs_data`。

但该源码中的 X1 Pro FIT 专用 TFTP 菜单会先执行 `iminfo`，再写入 `fit` 卷；该
入口只接受原始 `.itb`，不能用于本仓库恢复后的 `.bin`。源码也不能证明设备里
实际刷入的 FIP 和保存的环境变量与当前仓库完全一致。刷写前应在串口执行：

```text
printenv mtdparts bootcmd ubi_read_production
```

必须确认：

- `mtdparts` 是 X1 Pro 布局，并以 `114688k(ubi)` 结束。
- 使用的 Web 升级入口明确支持 OpenWrt sysupgrade TAR。
- 启动逻辑能够从 UBI 的 `kernel` 卷启动；如果 `ubi_read_production` 只读取
  `fit` 卷，则不能刷入此 `.bin`。

若任一项不符，不要刷入本固件。

特别是该 U-Boot 源码的 `layout@0` 仍是双 56 MiB UBI，不能用于本固件；必须选择
`x1pro-mod-112m`。切换 MTD 布局会使现有 UBI 固件和配置失效，应先完成全部备份，
并准备通过恢复模式重新写入系统。

另需注意：当前 U-Boot 仓库的 X1 Pro multi-layout DTS 把 FIP 放在
`0x380000`，但其
`uboot-mtk-20250711/configs-nonmbm/mt7981_oraybox_x1-pro_defconfig` 写的是
`OVERRIDE_FIP_BASE=0x3c0000`。这不影响本项目只更新 UBI，但在该差异被上游确认前，
不建议自行重新构建或刷写该仓库的 BL2/FIP。

## 构建与刷写

在 GitHub Actions 中运行 `Build ImmortalWrt for X1Pro`，在 `proxy` 选项中选择
`none` / `openclash` / `homeproxy` / `vpn`。工作流会核对源码
commit、安装官方固定版本 feeds、应用设备移植并构建单一 `.bin` 产物；发布前还会
检查 sysupgrade TAR 板名、内层 FIT/SquashFS、设备 metadata，以及所选代理软件
直接与关键传递依赖的软件包清单。

原厂恢复模式会校验厂商签名，不能直接接受该社区固件。应使用已经确认兼容的
U-Boot Web sysupgrade-TAR 升级入口刷入 `.bin`，不要使用会执行 `iminfo` 的 FIT
TFTP 入口。

如果设备当前运行的是本仓库之前生成的 `.itb` 固件，其旧版平台校验会拒绝
`.bin`；不要用 `sysupgrade -F` 强刷，应从已经确认支持 TAR 的 U-Boot Web 入口
完成一次布局切换。首次刷写前请备份全盘 NAND，并分别保存 BL2、FIP、Factory
和 bdinfo；不要把 TR3000 的 Factory 写入 X1 Pro。
