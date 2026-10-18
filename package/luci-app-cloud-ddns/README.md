# Cloud DDNS - luci-app-cloud-ddns

将 **DNSPod（腾讯云）** 和 **AliDNS（阿里云）** DDNS 服务合二为一的 LuCI 应用。

## 特性

- 纯 ucode 实现，兼容 OpenWrt 24.10+ / ImmortalWrt 25.12+
- 同时支持 DNSPod 和 AliDNS 双平台 DDNS
- 支持 A / AAAA 记录
- 支持 Token 和账号密码两种认证方式（DNSPod）
- 支持 Internet 公网获取和 WAN 接口获取 IP
- 多域名管理
- LuCI Web 界面位于 **服务 → Cloud DDNS**
- procd 守护进程，自动重启

## 依赖

- `curl`
- `openssl-util`
- `bash`

## 安装

在 OpenWrt 构建树中：

```bash
# 放到 package/ 目录
git clone https://github.com/yvzz/luci-app-cloud-ddns.git package/luci-app-cloud-ddns
make menuconfig # LuCI → 3. Applications → luci-app-cloud-ddns
make V=s
```

或在 `diy-part1.sh` 中：

```bash
git clone --depth 1 https://github.com/yvzz/luci-app-cloud-ddns.git package/luci-app-cloud-ddns
```

config 中添加：

```
CONFIG_PACKAGE_luci-app-cloud-ddns=y
```

## 致谢

- [honwen/luci-app-aliddns](https://github.com/honwen/luci-app-aliddns) — AliDNS 实现
- [samhjn/luci-app-dnspod](https://github.com/samhjn/luci-app-dnspod) — DNSPod 实现（原 dz）
- [zzsj0928/luci-app-pushbot](https://github.com/zzsj0928/luci-app-pushbot) — ucode 参考实现

## License

Apache-2.0