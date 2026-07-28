#!/bin/sh
# ============================================================
# 节点质量监控与自动切换脚本 (PassWall2 / iStoreOS)
# 定时检测所有节点质量，将最优节点自动应用到指定分流规则
# ============================================================

# ---------- 配置区 ----------
# 分流规则后缀 (自动拼成 passwall2.rulenode.xxx)
# youtube    → TV/YouTube 规则
# default_node   → 默认出口
# GFW        → GFW 规则
# game       → 游戏规则
ROUTE_RULE="youtube"

SKIP_NODES=""                         # 不参与测速和切换 (支持节点ID/名称/IP/域名, 逗号或空格分隔)

MAX_LOSS=50                           # 丢包超过此值不参与评分 (%)
PING_COUNT=5
PING_TIMEOUT=2
TEST_URL="https://speed.cloudflare.com/__down?bytes=10485760"  # 10MB
SPEED_TIMEOUT=60                      # 单次测速超时 (秒), 10MB/60s ≈ 170KB/s能完整跑完, 慢的按已下载数据算
LOG_FILE="/tmp/node_monitor.log"
LOG_HISTORY="/tmp/node_monitor_history.log"
LOCK_FILE="/tmp/node_monitor.lock"
MAX_LOG_LINES=200                     # 日志保留行数
# ============================

. /usr/share/passwall2/utils.sh 2>/dev/null

# 日志 + 自动裁剪
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
    local lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$lines" -gt "$MAX_LOG_LINES" ] && \
        sed -i "1,$((lines - MAX_LOG_LINES))d" "$LOG_FILE" 2>/dev/null
}

get_remark() {
    local r=$(uci get passwall2.$1.remarks 2>/dev/null)
    echo "${r:-$1}"
}

# 解析 IP (避免 PassWall2 劫持 DNS)
resolve_ip() {
    local host=$1
    # 已经是 IP 格式则直接返回
    case "$host" in
        *:*|*.*.*.*) echo "$host"; return ;;
    esac
    # 用 nslookup 直连公共 DNS 解析，不走系统 DNS
    nslookup "$host" 8.8.8.8 2>/dev/null | \
        sed -n 's/^Address [0-9]*: *\([0-9.]*\)$/\1/p' | tail -1
}

# Ping 测试 (直接 IP，避免代理干扰)
test_ping() {
    local ip=$1
    local result=$(ping -c $PING_COUNT -W $PING_TIMEOUT "$ip" 2>&1)

    local loss=$(echo "$result" | sed -n 's/.* \([0-9]*\)% packet loss/\1/p')
    loss=${loss:-100}

    local avg="0"
    if [ "$loss" != "100" ]; then
        avg=$(echo "$result" | sed -n 's/.*round-trip min\/avg\/max = \([0-9.]*\)\/\([0-9.]*\)\/\([0-9.]*\).*/\2/p')
        avg=${avg:-0}
    fi

    echo "$loss $avg"
}

# 清理残留进程 (只杀自己启动的测试进程，不动 PassWall2)
cleanup() {
    pgrep -f "config_file=ms_" 2>/dev/null | while read pid; do
        kill -9 $pid 2>/dev/null
    done
    rm -f /tmp/etc/passwall2/ms_*.json "$LOCK_FILE" "$RESULT_FILE" "$RESULT_FILE.speed"
    kill $GUARD_PID 2>/dev/null
}

# 通过节点测速 (返回 KB/s)
test_speed() {
    local node_id=$1
    local port=$(get_new_port 48900 tcp,udp)

    /usr/share/passwall2/app.sh run_socks flag="ms_${node_id}" node=${node_id} \
        bind=127.0.0.1 socks_port=${port} config_file=ms_${node_id}.json >/dev/null 2>&1

    pgrep -f "config_file=ms_${node_id}" 2>/dev/null | while read pid; do
        kill -9 $pid 2>/dev/null
    done
    sleep 1

    export XRAY_LOCATION_ASSET=/usr/share/v2ray/
    /tmp/etc/passwall2/bin/xray run -c /tmp/etc/passwall2/ms_${node_id}.json >/dev/null 2>&1 &
    sleep 3

    local speed=$(curl -s --connect-timeout 5 --max-time $SPEED_TIMEOUT \
        -x socks5h://127.0.0.1:${port} \
        -o /dev/null -w "%{speed_download}" \
        "$TEST_URL" 2>/dev/null)

    pgrep -f "config_file=ms_${node_id}" 2>/dev/null | while read pid; do
        kill -9 $pid 2>/dev/null
    done
    rm -f /tmp/etc/passwall2/ms_${node_id}.json

    echo ${speed:-0}
}

cleanup() {
    kill -9 $(pgrep -f "ms_") >/dev/null 2>&1
    rm -f /tmp/etc/passwall2/ms_*.json
}

# ============================================================
# 主流程
# ============================================================
trap cleanup EXIT

# 自动发现所有节点
ALL_NODES=$(uci show passwall2 2>/dev/null | grep '=nodes' | \
    sed 's/passwall2\.\(.*\)=nodes/\1/' | \
    grep -v '^examplenode$' | grep -v '^rulenode$')

# 排除配置区指定的节点 (支持 ID/名称/地址 模糊匹配)
resolve_skip() {
    local pattern="$1"
    local matched=""
    for node in $ALL_NODES; do
        # 匹配节点ID
        [ "$node" = "$pattern" ] && { matched="$matched $node"; continue; }
        # 匹配备注名 (remarks)
        local remark=$(uci get passwall2.$node.remarks 2>/dev/null)
        [ "$remark" = "$pattern" ] && { matched="$matched $node"; continue; }
        # 匹配地址 (address)
        local addr=$(uci get passwall2.$node.address 2>/dev/null)
        [ "$addr" = "$pattern" ] && { matched="$matched $node"; continue; }
        # 模糊匹配 (pattern 是 remark 或 address 的子串)
        echo "$remark" | grep -qi "$pattern" && { matched="$matched $node"; continue; }
        echo "$addr" | grep -qi "$pattern" && { matched="$matched $node"; continue; }
    done
    echo "$matched"
}

# 逗号转空格, 然后逐个匹配跳过
SKIP_NODES=$(echo "$SKIP_NODES" | tr ',' ' ')
for pattern in $SKIP_NODES; do
    matched=$(resolve_skip "$pattern")
    for node in $matched; do
        remark=$(uci get passwall2.$node.remarks 2>/dev/null)
        log "跳过节点: $remark ($node)"
        ALL_NODES=$(echo "$ALL_NODES" | grep -v "^${node}$")
    done
done
ALL_NODES=$(echo "$ALL_NODES" | tr '\n' ' ')
log "发现节点: $ALL_NODES"

# 防重复执行
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
        log "上次检查还在运行 (PID $pid)，跳过"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo "$$" > "$LOCK_FILE"

# 总超时保护 (15分钟强制退出)
GUARD_PID=""
(sleep 900 && [ -f "$LOCK_FILE" ] && kill -9 $(cat "$LOCK_FILE" 2>/dev/null) 2>/dev/null) &
GUARD_PID=$!

# 先清理上次残留 (只杀测试进程)
pgrep -f "config_file=ms_" 2>/dev/null | while read pid; do
    kill -9 $pid 2>/dev/null
done
rm -f /tmp/etc/passwall2/ms_*.json

RESULT_FILE="/tmp/node_monitor_result.$$"

log "===== 节点全面扫描 ====="

# 收集每个节点的 IP（解析域名去重）
NODE_IP_MAP=""
for node in $ALL_NODES; do
    addr=$(uci get passwall2.$node.address 2>/dev/null)
    ip=$(resolve_ip "$addr")
    [ -z "$ip" ] && ip="$addr"
    NODE_IP_MAP="$NODE_IP_MAP $node=$ip"
done

# 1. Ping 测试 (按 IP 去重)
log "--- Ping 测试 ---"
PING_CACHE_FILE="/tmp/ping_cache.$$"
for entry in $NODE_IP_MAP; do
    node=${entry%%=*}
    ip=${entry#*=}
    remark=$(get_remark "$node")

    # 检查 IP 缓存
    cached=$(grep "^${ip} " "$PING_CACHE_FILE" 2>/dev/null | head -1)
    if [ -n "$cached" ]; then
        loss=$(echo "$cached" | awk '{print $2}')
        avg=$(echo "$cached" | awk '{print $3}')
    else
        ping_result=$(test_ping "$ip")
        loss=$(echo "$ping_result" | awk '{print $1}')
        avg=$(echo "$ping_result" | awk '{print $2}')
        echo "$ip $loss $avg" >> "$PING_CACHE_FILE"
    fi

    log "  $remark ($node) → 丢包${loss}% 延迟${avg}ms"
    echo "$node $loss $avg" >> "$RESULT_FILE"
done
rm -f "$PING_CACHE_FILE"

# 2. 对丢包合格的节点测速
log "--- 单线程下载测速 ---"
BEST_NODE=""
BEST_SCORE=0
MAX_SPEED=1
MAX_PING=1

# 先收集有效节点
VALID_NODES=""
while read node loss avg; do
    [ "$loss" -ge "$MAX_LOSS" ] && continue
    VALID_NODES="$VALID_NODES $node"
done < "$RESULT_FILE"

if [ -z "$VALID_NODES" ]; then
    log "没有可用节点，跳过这次检查"
    rm -f "$RESULT_FILE"
    exit 1
fi

# 测速所有有效节点
for node in $VALID_NODES; do
    remark=$(get_remark "$node")
    bytes=$(test_speed "$node")
    speed=$(( bytes / 1024 ))
    log "  $remark ($node) → ${speed} KB/s"
    echo "$node $speed" >> "${RESULT_FILE}.speed"
    [ "$speed" -gt "$MAX_SPEED" ] && MAX_SPEED=$speed
done

# 读取 ping 数据用于评分
# 评分公式: score = speed/max_speed * 70 + (1 - ping/max_ping) * 30
# 先找最大 ping
while read node loss avg; do
    # 只对有效节点统计
    grep -q "$node" "${RESULT_FILE}.speed" 2>/dev/null || continue
    [ "${avg%.*}" -gt "$MAX_PING" ] 2>/dev/null && MAX_PING=${avg%.*}
done < "$RESULT_FILE"
[ "$MAX_PING" = "0" ] && MAX_PING=1

# 计算综合评分 (整数运算，避免依赖 bc)
while read node speed; do
    # 找对应的 ping
    local_avg=0
    while read n loss avg; do
        [ "$n" = "$node" ] && local_avg=$avg && break
    done < "$RESULT_FILE"
    local_ping=${local_avg%.*}  # 取整数部分

    # speed_score = speed * 70 / max_speed
    # ping_score = (max_ping - ping) * 30 / max_ping
    speed_score=$(( speed * 70 / MAX_SPEED ))
    [ "$MAX_PING" -gt 0 ] && ping_score=$(( (MAX_PING - local_ping) * 30 / MAX_PING )) || ping_score=30
    score=$(( speed_score + ping_score ))

    remark=$(get_remark "$node")
    log "  评分: $remark → speed=${speed_score} + ping=${ping_score} = ${score}"

    if [ "$score" -gt "$BEST_SCORE" ]; then
        BEST_SCORE=$score
        BEST_NODE=$node
    fi
done < "${RESULT_FILE}.speed"

rm -f "$RESULT_FILE" "${RESULT_FILE}.speed"

# 3. 应用最优节点到 TV 规则
if [ -z "$BEST_NODE" ]; then
    log "未找到合适的节点，不切换"
    exit 1
fi

CURRENT_RULE=$(uci get "passwall2.rulenode.$ROUTE_RULE" 2>/dev/null)
CURRENT_REMARK=$(get_remark "$CURRENT_RULE")
BEST_REMARK=$(get_remark "$BEST_NODE")

log ""
log "===== 结果 ====="
log "当前 $ROUTE_RULE 节点: $CURRENT_REMARK ($CURRENT_RULE)"
log "最优节点: $BEST_REMARK ($BEST_NODE) - 评分 $BEST_SCORE"

if [ "$BEST_NODE" = "$CURRENT_RULE" ]; then
    log "当前 $ROUTE_RULE 节点已是最优，无需切换"
    exit 0
fi

# 切换
log ">>> 切换 $ROUTE_RULE 至: $BEST_REMARK ($BEST_NODE)"
uci set "passwall2.rulenode.$ROUTE_RULE"="$BEST_NODE"
uci commit passwall2
/etc/init.d/passwall2 restart >/dev/null 2>&1
log ">>> 切换完成"

# 记录切换历史 (保留20行)
echo "$(date '+%Y-%m-%d %H:%M:%S') $ROUTE_RULE 切换至: $BEST_REMARK" >> "$LOG_HISTORY"
lines=$(wc -l < "$LOG_HISTORY" 2>/dev/null || echo 0)
[ "$lines" -gt 20 ] && sed -i "1,$((lines - 20))d" "$LOG_HISTORY" 2>/dev/null
