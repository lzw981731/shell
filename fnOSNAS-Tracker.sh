#!/bin/bash
# =================================================================
# Project: fnOS / Debian Tracker Updater
# Description: Automatically update BitTorrent trackers for dlcenter
# Author: vipkj.net 
# =================================================================

# 强制将当前脚本可能存在的 \r 去除（自愈逻辑）
# This script is optimized for Linux (LF).

# ================== 1. 权限与环境检查 ==================
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as root!" >&2
  exit 1
fi

# 检查并安装依赖 (fnOS / Debian 专用)
for cmd in sqlite3 curl; do
    if ! command -v $cmd &> /dev/null; then
        echo "Installing $cmd..."
        apt-get update && apt-get install -y $cmd
    fi
done

# ================== 2. 配置项 (Configuration) ==================
DB_DIR="/usr/trim/var/downloadcenter"
DB_FILE="downloadcenter.db"
MY_UID=1000  # 飞牛默认下载用户 UID

# Tracker 来源 (可根据需要增加)
URLS=(
  "https://trackerslist.com/best.txt"
  "https://ngosang.github.io/trackerslist/trackers_all.txt"
  "https://cf.trackerslist.com/all.txt"
)

CURL_TIMEOUT=30
TRACKER_MAX_LENGTH=200
BATCH_SIZE=100
SCRIPT_PATH=$(realpath "$0")

# ================== 3. 核心功能函数 ==================

# 执行更新逻辑
do_update() {
    if [ ! -d "$DB_DIR" ]; then
        echo "Error: Directory $DB_DIR not found."
        exit 1
    fi
    cd "$DB_DIR" || exit 1

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Tracker Update..."
    
    # 停止服务
    systemctl stop dlcenter

    # 获取当前最大 ID
    LAST_ID=$(sqlite3 "$DB_FILE" "SELECT MAX(ID) FROM USER_TRACKERS;")
    CURRENT_ID=${LAST_ID:-0}
    ((CURRENT_ID++))

    # 清理旧数据
    sqlite3 "$DB_FILE" "DELETE FROM USER_TRACKERS;"
    
    # 内存去重缓存
    declare -A seen_trackers

    for url in "${URLS[@]}"; do
        echo "Fetching: $url"
        response=$(curl -sLk --max-time "$CURL_TIMEOUT" "$url" | tr -d '\r')
        [ -z "$response" ] && continue

        # 提取并过滤有效 Tracker
        valid_list=$(echo "$response" | grep -Eo "(udp|http|https|wss|ws)://[^'\"<>]+" | cut -c -"$TRACKER_MAX_LENGTH")

        current_batch=0
        batch_sql="BEGIN;"

        while IFS= read -r tracker; do
            [ -z "$tracker" ] && continue
            lower_t=$(echo "$tracker" | tr '[:upper:]' '[:lower:]')
            
            if [[ -z "${seen_trackers[$lower_t]}" ]]; then
                seen_trackers["$lower_t"]=1
                batch_sql+="INSERT INTO USER_TRACKERS (ID, UID, TRACKER) VALUES ($CURRENT_ID, $MY_UID, '$tracker');"
                ((CURRENT_ID++))
                ((current_batch++))
            fi

            if [ $current_batch -ge $BATCH_SIZE ]; then
                batch_sql+="COMMIT;"
                sqlite3 "$DB_FILE" "$batch_sql"
                batch_sql="BEGIN;"
                current_batch=0
            fi
        done <<< "$valid_list"

        if [ $current_batch -gt 0 ]; then
            batch_sql+="COMMIT;"
            sqlite3 "$DB_FILE" "$batch_sql"
        fi
    done

    # 启动服务
    systemctl start dlcenter
    echo "[SUCCESS] All trackers updated and service restarted."
}

# 设置定时任务
set_cron() {
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "0 3 * * * $SCRIPT_PATH --auto") | crontab -
    echo "Cron job set: Automatically update at 03:00 AM every day."
}

# ================== 4. 交互菜单 (Menu) ==================

# 自动运行模式 (用于 Cron)
if [ "$1" == "--auto" ]; then
    do_update
    exit 0
fi

echo "------------------------------------------"
echo "   fnOS/Debian Download Center Tool"
echo "------------------------------------------"
echo "1) Run Tracker Update Now"
echo "2) Schedule Daily Update (03:00 AM)"
echo "3) Exit"
echo "------------------------------------------"

read -t 180 -p "Select an option [1-3] (Default 1): " choice

if [ -z "$choice" ]; then
    echo -e "\nNo input detected for 3 mins, running update..."
    choice=1
fi

case $choice in
    1) do_update ;;
    2) set_cron ;;
    3) exit 0 ;;
    *) echo "Invalid option."; exit 1 ;;
esac
