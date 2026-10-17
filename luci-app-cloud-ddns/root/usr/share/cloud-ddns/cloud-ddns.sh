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
touch "$LASTIP_FILE"

# ── UCI helpers ──
uci_get() { uci -q get "$1" 2>/dev/null; }

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
        echo "$(date '+%Y-%m-%d %H:%M:%S') 日志超限清空" >> "$LOGFILE"
    fi
}

# ── Get public IPv4 ──
get_inet_ipv4() {
    local ip
    ip=$(curl -sL --connect-timeout 5 members.3322.org/dyndns/getip)
    [ -z "$ip" ] && ip=$(curl -sL --connect-timeout 5 api.ip.sb/ip)
    [ -z "$ip" ] && ip=$(curl -sL --connect-timeout 5 ifconfig.co)
    [ -z "$ip" ] && ip=$(curl -sL --connect-timeout 5 ipinfo.io/ip)
    echo -n "$ip"
}

# ── Get public IPv6 ──
get_inet_ipv6() {
    local ip
    ip=$(curl -6 -sL --connect-timeout 5 ifconfig.co)
    [ -z "$ip" ] && ip=$(curl -6 -sL --connect-timeout 5 v6.ident.me)
    [ -z "$ip" ] && ip=$(curl -6 -sL --connect-timeout 5 api-ipv6.ip.sb/ip)
    echo -n "$ip"
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
        if [ "$src" = "wan" ]; then get_wan_ipv6; else get_inet_ipv6; fi
    else
        if [ "$src" = "wan" ]; then get_wan_ipv4; else get_inet_ipv4; fi
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
    local my_ip domain_id record_id record_rs record_code post_type

    my_ip=$(get_current_ip "$rtype" "$(if [ "$rtype" = "AAAA" ]; then echo "$IPV6_SRC"; else echo "$IPV4_SRC"; fi)")
    [ -z "$my_ip" ] && { echo "$(date '+%F %T') [DNSPod] 无法获取IP，跳过 ${sub}.${main}"; return; }

    domain_id=$(dp_api_post "Domain.Info" "domain=${main}")
    domain_id=$(echo "$domain_id" | sed 's/.*"id":"\([0-9]*\)".*/\1/')
    [ -z "$domain_id" ] && { echo "$(date '+%F %T') [DNSPod] 获取域名ID失败: ${main}"; return; }

    if echo "$my_ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        post_type="Record.Ddns"
    else
        post_type="Record.Modify"
    fi

    record_id=$(dp_api_post "Record.List" "domain_id=${domain_id}&sub_domain=${sub}&record_type=${rtype}&record_line=%e9%bb%98%e8%ae%a4")
    record_id=$(echo "$record_id" | sed 's/.*"id":"\([0-9]*\)".*/\1/')

    record_rs=$(dp_api_post "$post_type" "domain_id=${domain_id}&record_id=${record_id}&sub_domain=${sub}&record_type=${rtype}&value=${my_ip}&record_line=%e9%bb%98%e8%ae%a4")
    record_code=$(echo "$record_rs" | sed 's/.*{"code":"\([0-9]*\)".*/\1/')

    if [ "$record_code" = "1" ]; then
        echo "$(date '+%F %T') [DNSPod] ${sub}.${main} (${rtype}) -> ${my_ip} 更新成功"
    else
        echo "$(date '+%F %T') [DNSPod] ${sub}.${main} (${rtype}) 更新失败: ${record_rs}"
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
    [ -z "$my_ip" ] && { echo "$(date '+%F %T') [AliDNS] 无法获取IP，跳过 ${sub}.${main}"; return; }

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
        echo "$(date '+%F %T') [AliDNS] ${dm_real} (${rtype}) IP未变化 ${my_ip}"
        return
    fi

    rrid=$(ali_send_request "DescribeSubDomainRecords" "SubDomain=${dm_escape}&Type=${rtype}" | ali_get_recordid)

    if [ -z "$rrid" ]; then
        rrid=$(ali_send_request "AddDomainRecord&DomainName=${main}" "RR=${sub_escape}&Type=${rtype}&Value=${my_ip_escape}" | ali_get_recordid)
        echo "$(date '+%F %T') [AliDNS] ${dm_real} (${rtype}) 新增记录 -> ${my_ip}"
    else
        ali_send_request "UpdateDomainRecord" "RR=${sub_escape}&RecordId=${rrid}&Type=${rtype}&Value=${my_ip_escape}" >/dev/null 2>&1
        echo "$(date '+%F %T') [AliDNS] ${dm_real} (${rtype}) 更新记录 -> ${my_ip}"
    fi
}

# ── Process all domains ──
process_domains() {
    local i=0
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
while true; do
    load_config

    if [ "$DP_ENABLED" != "1" ] && [ "$ALI_ENABLED" != "1" ]; then
        sleep 60
        continue
    fi

    clean_log
    echo "$(date '+%F %T') === Cloud DDNS 检查开始 ==="

    process_domains

    echo "$(date '+%F %T') === 下次检查: ${DP_TIME}秒后 ==="
    sleep "$DP_TIME"
done