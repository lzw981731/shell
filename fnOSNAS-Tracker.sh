#!/bin/bash
# By: vipkj.net
# Update: 2026-02-01

# ================== 权限检查 ==================
if [ "$(id -u)" -ne 0 ]; then
  echo "错误：该脚本需要以root用户权限运行！请使用 sudo -i 后运行。" >&2
  exit 1
fi

# ================= 环境预检 =================
# 检测并安装必要工具
for cmd in sqlite3 curl; do
    if ! command -v $cmd &> /dev/null; then
        echo "未检测到 $cmd，准备安装..."
        apt-get update && apt-get install -y $cmd
    fi
done

# ================= 配置项 =================
DB_DIR="/usr/trim/var/downloadcenter"
DB_FILE="downloadcenter.db"
MY_UID=1000
URLS=(
  "https://trackerslist.com/best.txt"
  "https://ngosang.github.io/trackerslist/trackers_all.txt"
  "https://cf.trackerslist.com/all.txt"
)
CURL_TIMEOUT=30
TRACKER_MAX_LENGTH=200
BATCH_SIZE=100
SCRIPT_PATH=$(realpath "$0") # 获取当前脚本的绝对路径用于定时任务
# ==========================================

# 更新函数逻辑
update_trackers() {
    cd "$DB_DIR" || { echo "无法进入目录 $DB_DIR"; exit 1; }
    
    if [ ! -f "$DB_FILE" ]; then
        echo "错误：数据库文件 $DB_FILE 不存在。"
        exit 1
    fi

    echo "--- 正在停止下载应用服务 ---"
    systemctl stop dlcenter

    # 初始化ID
    LAST_ID=$(sqlite3 "$DB_FILE" "SELECT MAX(ID) FROM USER_TRACKERS;")
    CURRENT_ID=${LAST_ID:-0}
    ((CURRENT_ID++))

    sqlite3 "$DB_FILE" "DELETE FROM USER_TRACKERS;"
    declare -A existing_trackers

    for url in "${URLS[@]}"; do
        echo "获取 URL: $url"
        response=$(curl -sLk --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null)
        [ -z "$response" ] && continue

        valid_trackers=$(echo "$response" | tr -d '\r' | grep -Eo "(udp|http|https|wss|ws)://[^'\"<>]+" | sed "s/'/''/g" | cut -c -"$TRACKER_MAX_LENGTH" | awk '!a[tolower($0)]++')

        current_batch=0
        batch_sql="BEGIN;"
        
        while IFS= read -r tracker; do
            [ -z "$tracker" ] && continue
            lower_tracker=$(echo "$tracker" | tr '[:upper:]' '[:lower:]')
            [[ -n "${existing_trackers[$lower_tracker]}" ]] && continue

            new_id=$((CURRENT_ID++))
            existing_trackers["$lower_tracker"]="$new_id"
            batch_sql+="INSERT INTO USER_TRACKERS (ID, UID, TRACKER) VALUES ($new_id, $MY_UID, '$tracker');"
            ((current_batch++))

            if [ $current_batch -ge $BATCH_SIZE ]; then
                batch_sql+="COMMIT;"
                sqlite3 "$DB_FILE" "$batch_sql"
                batch_sql="BEGIN;"
                current_batch=0
            fi
        done <<< "$valid_trackers"

        if [ $current_batch -gt 0 ]; then
            batch_sql+="COMMIT;"
            sqlite3 "$DB_FILE" "$batch_sql"
        fi
    done

    echo "--- 正在清理并重启服务 ---"
    systemctl start dlcenter
    echo "Tracker 更新完成！"
}

# 定时任务设置函数
setup_cron() {
    # 检查是否已存在定时任务
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        echo "提示：定时任务已存在，无需重复设置。"
    else
        # 设置每天凌晨 3:00 自动运行（不带交互模式直接运行更新）
        (crontab -l 2>/dev/null; echo "0 3 * * * $SCRIPT_PATH --auto") | crontab -
        echo "成功：已设置每天凌晨 03:00 自动更新 Tracker。"
    fi
}

# ================= 主程序交互 =================

# 检查是否为定时任务调用的自动模式
if [ "$1" == "--auto" ]; then
    update_trackers
    exit 0
fi

echo "------------------------------------------"
echo "        飞牛下载中心 Tracker 维护脚本"
echo "------------------------------------------"
echo "1) 立即运行 Tracker 更新"
echo "2) 设置每天凌晨定时更新任务"
echo "------------------------------------------"
echo "提示：若 3 分钟内无操作，将自动执行第 1 项。"

# read -t 180 表示 180 秒（3 分钟）超时
read -t 180 -p "请输入选项 [1-2]: " choice

# 如果超时或没输入，默认选 1
if [ -z "$choice" ]; then
    echo -e "\n超时未响应，正在自动运行功能 1..."
    choice=1
fi

case $choice in
    1)
        update_trackers
        ;;
    2)
        setup_cron
        ;;
    *)
        echo "输入无效，脚本退出。"
        exit 1
        ;;
esac
