#!/bin/sh
# cloud-ddns 运行条件校验
#
# init.d 与 LuCI 状态接口共用同一份判断，避免两处逻辑漂移。
#
# 退出码：0 = 允许运行；1 = 不满足运行条件
# stdout：不满足时输出一行中文原因（页面「服务状态」处直接展示）
#
# 条件（同一个服务商必须同时满足三项才算可用）：
#   1) 该服务商已启用
#   2) 凭据齐全   —— DNSPod: ID,Token 或 登录邮箱+密码；AliDNS: Access Key ID + Secret
#   3) 至少有一条指向它的域名记录 —— 主域名、子域名都填了，记录类型为 A 或 AAAA

UCI="uci -q get"

dp_enabled=$($UCI cloud-ddns.dnspod.enabled)
dp_mode=$($UCI cloud-ddns.dnspod.mode)
[ -z "$dp_mode" ] && dp_mode="token"
dp_token=$($UCI cloud-ddns.dnspod.artoken)
dp_mail=$($UCI cloud-ddns.dnspod.login_email)
dp_pass=$($UCI cloud-ddns.dnspod.login_password)

ali_enabled=$($UCI cloud-ddns.alidns.enabled)
ali_key=$($UCI cloud-ddns.alidns.app_key)
ali_secret=$($UCI cloud-ddns.alidns.app_secret)

# ── 统计「有效」域名记录（按服务商归类）──
dp_domain=0
ali_domain=0
i=0
while $UCI "cloud-ddns.@domain[$i]" >/dev/null 2>&1; do
	provider=$($UCI "cloud-ddns.@domain[$i].provider")
	[ -z "$provider" ] && provider="dnspod"
	main=$($UCI "cloud-ddns.@domain[$i].main_domain")
	sub=$($UCI "cloud-ddns.@domain[$i].sub_domain")
	rtype=$($UCI "cloud-ddns.@domain[$i].record_type")
	[ -z "$rtype" ] && rtype="A"

	if [ -n "$main" ] && [ -n "$sub" ] && { [ "$rtype" = "A" ] || [ "$rtype" = "AAAA" ]; }; then
		if [ "$provider" = "alidns" ]; then
			ali_domain=1
		else
			dp_domain=1
		fi
	fi
	i=$((i + 1))
done

# ── 凭据 ──
dp_cred=0
if [ "$dp_mode" = "login" ]; then
	[ -n "$dp_mail" ] && [ -n "$dp_pass" ] && dp_cred=1
else
	[ -n "$dp_token" ] && dp_cred=1
fi

ali_cred=0
[ -n "$ali_key" ] && [ -n "$ali_secret" ] && ali_cred=1

if [ "$dp_enabled" != "1" ] && [ "$ali_enabled" != "1" ]; then
	echo "未启用任何服务商：请勾选「启用 DNSPod」或「启用 AliDNS」"
	exit 1
fi

dp_ready=0
ali_ready=0
[ "$dp_enabled" = "1" ] && [ "$dp_cred" = "1" ] && [ "$dp_domain" = "1" ] && dp_ready=1
[ "$ali_enabled" = "1" ] && [ "$ali_cred" = "1" ] && [ "$ali_domain" = "1" ] && ali_ready=1

if [ "$dp_ready" = "1" ] || [ "$ali_ready" = "1" ]; then
	exit 0
fi

# 有启用的服务商但配置不完整，给出最具体的一条原因
if [ "$dp_enabled" = "1" ]; then
	if [ "$dp_cred" != "1" ]; then
		echo "DNSPod 凭据未填写：需要 ID,Token（Token 解析）或 登录邮箱+密码（账号解析）"
		exit 1
	fi
	if [ "$dp_domain" != "1" ]; then
		echo "没有指向 DNSPod 的可用记录：主域名与子域名必填，记录类型须为 A 或 AAAA"
		exit 1
	fi
fi

if [ "$ali_enabled" = "1" ]; then
	if [ "$ali_cred" != "1" ]; then
		echo "AliDNS 凭据未填写：需要 Access Key ID 与 Access Key Secret"
		exit 1
	fi
	if [ "$ali_domain" != "1" ]; then
		echo "没有指向 AliDNS 的可用记录：主域名与子域名必填，记录类型须为 A 或 AAAA"
		exit 1
	fi
fi

echo "配置不完整，服务保持停止"
exit 1
