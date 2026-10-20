#!/bin/bash
#################################################
# Cloud DDNS - DNSPod + AliDNS combined script
# Based on:
#   - AnripDdns v5.08 (dnspod) by dz
#   - aliddns by honwen
#################################################

LOGFILE="/var/log/cloud-ddns.log"
LASTIP_FILE="/usr/share/cloud-ddns/last.ip"
mkdir -p /usr/share/cloud-ddns
[ -d /var/log ] || mkdir -p /var/log
touch "$LOGFILE"

# ── UCI helpers ──
uci_get() { uci -q get "$1" 2>/dev/null; }

# ── 日志：同时写进 LOGFILE（LuCI 页面读取）和 stdout（procd 会收进 syslog）──
# 注意：只用于「状态/结果」输出；像 get_inet_ipv4() 这种用 echo 返回 IP 的
# 值传递函数，绝对不能改成 log()，否则会把 IP 混进日志且返回值丢失。
log() {
    echo "$@"
    echo "$@" >> "$LOGFILE" 2>/dev/null
}

load_config() {
    # DNSPod
    DP_ENABLED=$(uci_get cloud-ddns.dnspod.enabled)
    DP_TIME=$(uci_get cloud-ddns.dnspod.time); [ -z "$DP_TIME" ] && DP_TIME=600
    DP_MODE=$(uci_get cloud-ddns.dnspod.mode); [ -z "$DP_MODE" ] && DP_MODE="token"
    if [ "$DP_MODE" = "login" ]; then
        DP_MAIL=$(uci_get cloud-ddns.dnspod.login_email)
        DP_PASS=$(uci_get cloud-ddns.dnspod.login_password)
        DP_TOKEN=""
    else
        DP_TOKEN=$(uci_get cloud-ddns.dnspod.artoken)
        DP_MAIL=""; DP_PASS=""
    fi

    # AliDNS
    ALI_ENABLED=$(uci_get cloud-ddns.alidns.enabled)
    ALI_KEY=$(uci_get cloud-ddns.alidns.app_key)
    ALI_SECRET=$(uci_get cloud-ddns.alidns.app_secret)

    # IP source
    IPV4_SRC=$(uci_get cloud-ddns.ip.ipv4_source); [ -z "$IPV4_SRC" ] && IPV4_SRC="internet"
    IPV6_SRC=$(uci_get cloud-ddns.ip.ipv6_source); [ -z "$IPV6_SRC" ] && IPV6_SRC="internet"
}

# ── Log rotation ──
clean_log() {
    local n; n=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$n" -ge 3000 ]; then
        : > "$LOGFILE"
        log "$(date '+%Y-%m-%d %H:%M:%S') 日志超限清空"
    fi
}

# ── IP 合法性校验 ──
# 关键：IP 源被限流/报错时会返回 "429 Too Many Requests" 这类 HTML 页面；
# 原逻辑只看「非空」就采纳，于是把整页 HTML 当成 IP 提交给 DNSPod，
# 表现为 DNSPod 报 code 34「记录的值不正确」。必须先验格式再用。
is_ipv4() {
    local ip="$1" o
    [ -z "$ip" ] && return 1
    local IFS=.
    set -- $ip
    [ $# -eq 4 ] || return 1
    for o in "$@"; do
        case "$o" in ''|*[!0-9]*) return 1;; esac
        [ "$o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

is_ipv6() {
    local ip="$1"
    [ -z "$ip" ] && return 1
    case "$ip" in *[!0-9a-fA-F:]*) return 1;; esac
    [ "${#ip}" -ge 3 ] || return 1
    return 0
}

# ── Get public IPv4（逐个源尝试，取到合法 IP 才停）──
get_inet_ipv4() {
    local ip u
    for u in "http://members.3322.org/dyndns/getip" "http://ip.3322.net" \
             "https://api.ipify.org" "https://api.ip.sb/ip" "http://ifconfig.co"; do
        ip=$(curl -sL -k --connect-timeout 5 "$u" 2>/dev/null | tr -d '\r\n')
        if is_ipv4 "$ip"; then echo -n "$ip"; return; fi
    done
    echo -n ""
}

# ── Get public IPv6（逐个源尝试，取到合法 IP 才停）──
get_inet_ipv6() {
    local ip u
    for u in "https://api-ipv6.ip.sb/ip" "http://v6.ident.me" "http://ifconfig.co"; do
        ip=$(curl -6 -sL -k --connect-timeout 5 "$u" 2>/dev/null | tr -d '\r\n')
        if is_ipv6 "$ip"; then echo -n "$ip"; return; fi
    done
    echo -n ""
}

# ── 公网 IP 缓存 ──
# 一个检查周期内每条域名都要问一次公网 IP，N 条域名就把外部请求放大 N 倍，
# 很容易把 IP 源打到 429。周期内取到一次就复用。
CD_IPV4=""; CD_IPV6=""; CD_IPV4_DONE=0; CD_IPV6_DONE=0

get_inet_ip_cached() {
    if [ "$1" = "AAAA" ]; then
        if [ "$CD_IPV6_DONE" != "1" ]; then CD_IPV6=$(get_inet_ipv6); CD_IPV6_DONE=1; fi
        echo -n "$CD_IPV6"
    else
        if [ "$CD_IPV4_DONE" != "1" ]; then CD_IPV4=$(get_inet_ipv4); CD_IPV4_DONE=1; fi
        echo -n "$CD_IPV4"
    fi
}

# ── Get WAN interface IPv4 ──
get_wan_ipv4() {
    ubus call network.interface.wan status 2>/dev/null | grep '"address"' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1
}

# ── Get WAN interface IPv6 ──
get_wan_ipv6() {
    ubus call network.interface.wan6 status 2>/dev/null | grep '"address"' | grep -oE '([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{1,4}' | head -1
}

# ── Get current IP by type ──
get_current_ip() {
    local rtype=$1 src=$2
    if [ "$rtype" = "AAAA" ]; then
        if [ "$src" = "wan" ]; then get_wan_ipv6; else get_inet_ip_cached "AAAA"; fi
    else
        if [ "$src" = "wan" ]; then get_wan_ipv4; else get_inet_ip_cached "A"; fi
    fi
}

# ── Get last IP from file ──
get_last_ip() {
    local key="$1"
    [ -f "$LASTIP_FILE" ] && grep "$key" "$LASTIP_FILE" 2>/dev/null | awk '{print $2}'
}

# ── Save last IP ──
save_last_ip() {
    local key="$1" ip="$2"
    if [ -f "$LASTIP_FILE" ]; then
        grep -v "$key" "$LASTIP_FILE" > "${LASTIP_FILE}.tmp" 2>/dev/null
    fi
    echo "$key $ip" >> "${LASTIP_FILE}.tmp"
    mv "${LASTIP_FILE}.tmp" "$LASTIP_FILE" 2>/dev/null
}

# ── URL encoder ──
urlencode() {
    local s="$1" out="" c
    for c in $(echo -n "$s" | sed 's/[^\n]/&\n/g'); do
        case "$c" in
            [a-zA-Z0-9._-]) out="$out$c" ;;
            *) out="$out$(printf '%%%02X' "'$c")" ;;
        esac
    done
    echo -n "$out"
}

# ============================================================
# DNSPod API
# ============================================================
dp_api_post() {
    local action=$1 params=$2
    local inter="https://dnsapi.cn/${action}"
    local param
    if [ -n "$DP_TOKEN" ]; then
        param="login_token=${DP_TOKEN}&format=json&${params}"
    else
        param="login_email=${DP_MAIL}&login_password=${DP_PASS}&format=json&${params}"
    fi
    curl -s -k -X POST "$inter" -d "$param"
}

dp_update_domain() {
    local main=$1 sub=$2 rtype=$3
    local my_ip domain_id list_rs record_id record_rs record_code action

    # 主机记录为空时按根域名处理（DNSPod 用 @ 表示）
    [ -z "$sub" ] && sub="@"

    my_ip=$(get_current_ip "$rtype" "$(if [ "$rtype" = "AAAA" ]; then echo "$IPV6_SRC"; else echo "$IPV4_SRC"; fi)")
    [ -z "$my_ip" ] && { log "$(date '+%F %T') [DNSPod] 无法获取IP，跳过 ${sub}.${main}"; return; }

    domain_id=$(dp_api_post "Domain.Info" "domain=${main}" | tr -d ' \n' | sed 's/.*"id":"\([0-9]*\)".*/\1/')
    case "$domain_id" in ''|*[!0-9]*) domain_id="";; esac
    [ -z "$domain_id" ] && { log "$(date '+%F %T') [DNSPod] 获取域名ID失败: ${main}"; return; }

    # 先查这条主机记录是否已存在：没有就新增，有则修改。
    # 不能用 Record.Ddns——它是「快速修改」，必须传 record_id，记录不存在会返回
    # code 8「记录编号错误」，而且不支持 AAAA 记录。
    # 不限制 record_line，任意线路上的同名记录都能命中（限定默认线路时，
    # 建在其它线路的记录会查不到，导致重复新增报 code 104）。
    list_rs=$(dp_api_post "Record.List" "domain_id=${domain_id}&sub_domain=${sub}&record_type=${rtype}")
    record_id=$(echo "$list_rs" | tr -d ' \n' | sed 's/.*"records":\[{"id":"\([0-9]*\)".*/\1/')
    # sed 没匹配到时会原样输出整行，必须校验结果是纯数字才算有效 id
    case "$record_id" in ''|*[!0-9]*) record_id="";; esac

    if [ -z "$record_id" ]; then
        action="新增记录"
        record_rs=$(dp_api_post "Record.Create" "domain_id=${domain_id}&sub_domain=${sub}&record_type=${rtype}&value=${my_ip}&record_line=%e9%bb%98%e8%ae%a4")
    else
        action="更新记录"
        record_rs=$(dp_api_post "Record.Modify" "domain_id=${domain_id}&record_id=${record_id}&sub_domain=${sub}&record_type=${rtype}&value=${my_ip}&record_line=%e9%bb%98%e8%ae%a4")
    fi

    record_code=$(echo "$record_rs" | tr -d ' \n' | sed 's/.*{"code":"\([0-9]*\)".*/\1/')

    if [ "$record_code" = "1" ]; then
        log "$(date '+%F %T') [DNSPod] ${sub}.${main} (${rtype}) ${action} -> ${my_ip}"
    else
        log "$(date '+%F %T') [DNSPod] ${sub}.${main} (${rtype}) ${action}失败(value=${my_ip}): ${record_rs}"
    fi
}

# ============================================================
# AliDNS API
# ============================================================
ali_send_request() {
    local action=$1 args=$2
    local ts; ts=$(date -u "+%Y-%m-%dT%H%%3A%M%%3A%SZ")
    local all_args="AccessKeyId=${ALI_KEY}&Action=${action}&Format=json&${args}&SignatureMethod=HMAC-SHA1&SignatureNonce=${ts}&SignatureVersion=1.0&Timestamp=${ts}&Version=2015-01-09"
    local sig; sig=$(urlencode "$(echo -n "GET&%2F&$(urlencode "$all_args")" | openssl dgst -sha1 -hmac "${ALI_SECRET}&" -binary | openssl base64)")
    curl -sSL --connect-timeout 10 "http://alidns.aliyuncs.com/?${all_args}&Signature=${sig}"
}

ali_get_recordid() {
    sed 's/RR/\n/g' | sed -n 's/.*RecordId[^0-9]*\([0-9]*\).*/\1\n/p' | sort -ru | sed /^$/d
}

ali_resolve_ip() {
    local domain=$1 rtype=$2
    local ip
    if [ "$rtype" = "AAAA" ]; then
        ip=$(nslookup "$domain" ns1.alidns.com 2>/dev/null | grep -oE '([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{1,4}' | tail -1)
        [ -z "$ip" ] && ip=$(nslookup "$domain" 114.114.115.115 2>/dev/null | grep -oE '([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{1,4}' | tail -1)
    else
        ip=$(nslookup "$domain" ns1.alidns.com 2>/dev/null | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | tail -1)
        [ -z "$ip" ] && ip=$(nslookup "$domain" 114.114.115.115 2>/dev/null | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | tail -1)
    fi
    echo -n "$ip"
}

ali_update_domain() {
    local main=$1 sub=$2 rtype=$3
    local my_ip current_ip rrid dm_real dm_escape sub_escape

    my_ip=$(get_current_ip "$rtype" "$(if [ "$rtype" = "AAAA" ]; then echo "$IPV6_SRC"; else echo "$IPV4_SRC"; fi)")
    [ -z "$my_ip" ] && { log "$(date '+%F %T') [AliDNS] 无法获取IP，跳过 ${sub}.${main}"; return; }

    if [ "$sub" = "@" ] || [ -z "$sub" ]; then
        dm_real="$main"
    else
        dm_real="${sub}.${main}"
    fi
    dm_escape=$(urlencode "$dm_real")
    sub_escape=$(urlencode "$sub")
    my_ip_escape=$(urlencode "$my_ip")

    current_ip=$(ali_resolve_ip "$dm_real" "$rtype")

    if [ "$my_ip" = "$current_ip" ] && [ -n "$current_ip" ]; then
        log "$(date '+%F %T') [AliDNS] ${dm_real} (${rtype}) IP未变化 ${my_ip}"
        return
    fi

    rrid=$(ali_send_request "DescribeSubDomainRecords" "SubDomain=${dm_escape}&Type=${rtype}" | ali_get_recordid)

    if [ -z "$rrid" ]; then
        rrid=$(ali_send_request "AddDomainRecord&DomainName=${main}" "RR=${sub_escape}&Type=${rtype}&Value=${my_ip_escape}" | ali_get_recordid)
        log "$(date '+%F %T') [AliDNS] ${dm_real} (${rtype}) 新增记录 -> ${my_ip}"
    else
        ali_send_request "UpdateDomainRecord" "RR=${sub_escape}&RecordId=${rrid}&Type=${rtype}&Value=${my_ip_escape}" >/dev/null 2>&1
        log "$(date '+%F %T') [AliDNS] ${dm_real} (${rtype}) 更新记录 -> ${my_ip}"
    fi
}

# ── Process all domains ──
process_domains() {
    local i=0
    # 新的一轮检查：清掉公网 IP 缓存，本轮内多条域名共用同一次查询结果
    CD_IPV4_DONE=0; CD_IPV6_DONE=0
    while uci -q get "cloud-ddns.@domain[$i]" >/dev/null 2>&1; do
        local provider main sub rtype
        provider=$(uci_get "cloud-ddns.@domain[$i].provider")
        main=$(uci_get "cloud-ddns.@domain[$i].main_domain")
        sub=$(uci_get "cloud-ddns.@domain[$i].sub_domain")
        rtype=$(uci_get "cloud-ddns.@domain[$i].record_type")
        [ -z "$rtype" ] && rtype="A"
        [ -z "$provider" ] && provider="dnspod"

        if [ "$provider" = "dnspod" ] && [ "$DP_ENABLED" = "1" ]; then
            dp_update_domain "$main" "$sub" "$rtype"
        elif [ "$provider" = "alidns" ] && [ "$ALI_ENABLED" = "1" ]; then
            ali_update_domain "$main" "$sub" "$rtype"
        fi
        i=$((i + 1))
    done
}

# ── Main loop ──
CD_BADCFG_LOGGED=0

while true; do
    load_config

    # 运行前校验：不满足条件就空转等待，不产生任何 API 请求。
    # 原因只在状态刚变坏时打一次，避免每 60 秒刷屏。
    if ! /usr/share/cloud-ddns/check-config.sh >/dev/null 2>&1; then
        if [ "$CD_BADCFG_LOGGED" != "1" ]; then
            log "$(date '+%F %T') 配置不满足运行条件（需：启用服务商 + 凭据齐全 + 至少一条 A/AAAA 域名记录），每 60 秒复查一次"
            CD_BADCFG_LOGGED=1
        fi
        sleep 60
        continue
    fi
    CD_BADCFG_LOGGED=0

    clean_log
    log "$(date '+%F %T') === Cloud DDNS 检查开始 ==="

    process_domains

    log "$(date '+%F %T') === 下次检查: ${DP_TIME}秒后 ==="
    sleep "$DP_TIME"
done