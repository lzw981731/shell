#!/bin/bash
# =================================================================
# 项目名称: 飞牛 (fnOS) 下载中心 Tracker 自动维护工具
# 适配系统: Debian / fnOS
# 功能描述: 自动抓取最新 Tracker 并注入 dlcenter 数据库
# =================================================================

# ================== 1. 环境检查 ==================
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 错误：必须以 root 权限运行此脚本！请使用 'sudo -i' 切换身份。" >&2
  exit 1
fi

# 安装必要依赖
for cmd in sqlite3 curl; do
    if ! command -v $cmd &> /dev/null; then
        echo "正在安装必要组件 $cmd ..."
        apt-get update && apt-get install -y $cmd
    fi
done

# ================== 2. 配置项 ==================
DB_DIR="/usr/trim/var/downloadcenter"
DB_FILE="downloadcenter.db"
MY_UID=1000  # 飞牛默认下载用户 UID

# Tracker 订阅源
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

# 执行 Tracker 更新
do_update() {
    if [ ! -d "$DB_DIR" ]; then
        echo "❌ 错误: 找不到数据库目录 $DB_DIR"
        exit 1
    fi
    cd "$DB_DIR" || exit 1

    echo "------------------------------------------"
    echo "📅 [$(date '+%Y-%m-%d %H:%M:%S')] 开始更新流程..."
    echo "------------------------------------------"
    
    # 停止服务以防止数据库死锁
    echo "⏱️ 正在停止下载服务 (dlcenter)..."
    systemctl stop dlcenter

    # 获取 ID 计数器
    LAST_ID=$(sqlite3 "$DB_FILE" "SELECT MAX(ID) FROM USER_TRACKERS;")
    CURRENT_ID=${LAST_ID:-0}
    ((CURRENT_ID++))

    # 清理旧数据
    echo "🧹 正在清理旧 Tracker 数据..."
    sqlite3 "$DB_FILE" "DELETE FROM USER_TRACKERS;"
    
    # 内存去重缓存
    declare -A seen_trackers

    for url in "${URLS[@]}"; do
        echo "🌐 正在获取: $url"
        # 抓取并强制去除 \r (针对从网络下载的内容)
        response=$(curl -sLk --max-time "$CURL_TIMEOUT" "$url" | tr -d '\r')
        [ -z "$response" ] && continue

        # 过滤合法格式并限制长度
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
    echo "🚀 正在重启下载服务 (dlcenter)..."
    systemctl start dlcenter
    echo "✅ [完成] Tracker 注入成功，服务已恢复正常。"
}

# 自动设置 Cron 定时任务
set_cron() {
    # 移除已有的重复任务并添加新任务
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "0 3 * * * $SCRIPT_PATH --auto") | crontab -
    echo "✅ [成功] 已设置定时任务：每天凌晨 03:00 自动执行更新。"
}

# ================== 4. 交互菜单 ==================

# 检查是否为定时任务调用的自动模式
if [ "$1" == "--auto" ]; then
    do_update
    exit 0
fi

clear
echo "=========================================="
echo "      飞牛 (fnOS) 下载中心维护工具"
echo "=========================================="
echo " 1) 🚀 立即运行 Tracker 更新"
echo " 2) ⏰ 设置每天凌晨 3 点自动更新"
echo " 3) ❌ 退出脚本"
echo "=========================================="
echo "💡 提示：若 3 分钟内无操作，将自动运行功能 1。"

# 使用 read 捕获超时
read -t 180 -p "请输入选项 [1-3] (默认 1): " choice

# 处理默认选项
choice=${choice:-1}

case $choice in
    1)
        do_update
        ;;
    2)
        set_cron
        ;;
    3)
        echo "👋 已退出。"
        exit 0
        ;;
    *)
        echo "⚠️ 输入无效，正在执行默认更新..."
        do_update
        ;;
esac
