#!/bin/bash
# By: Lixuekun
# QQ: 781732825
# Time: 20250517
# Email: 781732825@qq.com


# ================== 权限检查 ==================
if [ "$(id -u)" -ne 0 ]; then
  echo "错误：该脚本需要以root用户权限运行！ 请使用 sudo -i 并且输入NAS的登录密码切换到Root身份后可在任意目录下运行该脚本。" >&2
  exit 1
fi
# =============================================


# ================= 配置项 =================
DB_FILE="downloadcenter.db"                                      # 数据库文件名
MY_UID=1000                                            # 用户UID标记
URLS=(                                                 # Tracker来源列表
  "https://ngosang.github.io/trackerslist/trackers_all.txt"
  "https://cf.trackerslist.com/all.txt"
  "https://down.adysec.com/trackers_all.txt"
)
CURL_IGNORE_SSL=1                                      # 忽略SSL错误
CURL_TIMEOUT=30                                        # 超时时间（秒）
TRACKER_MAX_LENGTH=200                                 # Tracker最大长度
BATCH_SIZE=100                                         # 每批插入数量
# ==========================================

cd /usr/trim/var/downloadcenter/   # 进入数据库目录

# 预检数据库表结构
if ! sqlite3 "$DB_FILE" "SELECT name FROM sqlite_master WHERE type='table' AND name='USER_TRACKERS';" | grep -q USER_TRACKERS; then
  echo "错误: 数据库表 USER_TRACKERS 不存在"
  exit 1
fi


echo " 正在停止下载应用服务"
systemctl stop dlcenter

# 初始化全局ID（从数据库当前最大值+1开始）
LAST_ID=$(sqlite3 "$DB_FILE" "SELECT MAX(ID) FROM USER_TRACKERS;")
CURRENT_ID=${LAST_ID:-0}
((CURRENT_ID++))

# 清空旧数据（保留表结构）
sqlite3 "$DB_FILE" "DELETE FROM USER_TRACKERS;"

# 内存去重缓存
declare -A existing_trackers

# 请求失败重试函数
fetch_url() {
  local url=$1
  for retry in {1..3}; do
    if response=$(curl -sLk --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null); then
      echo "$response"
      return 0
    else
      echo "  [重试] 第 $retry 次请求失败" >&2
      sleep 2
    fi
  done
  return 1
}

for url in "${URLS[@]}"; do
  echo "处理 URL: $url"
  
  # 获取Tracker列表
  if ! response=$(fetch_url "$url"); then
    echo "  [错误] 请求失败或超时"
    continue
  fi

  # 处理有效Tracker
  valid_trackers=$(
    echo "$response" |
    tr -d '\r' |                             # 移除CR字符
    grep -Eo --line-buffered "(udp|http|https|wss|ws)://[^'\"<>]+" |
    sed "s/'/''/g" |                         # 转义单引号
    cut -c -"$TRACKER_MAX_LENGTH" |          # 长度限制
    awk '!a[tolower($0)]++'                  # 内存级去重
  )

  # 统计有效Tracker数量
  url_count=$(echo "$valid_trackers" | grep -c .)
  if [ "$url_count" -eq 0 ]; then
    echo "  [警告] 无有效Tracker"
    continue
  fi

  # 分批处理
  current_batch=0
  batch_sql=""
  success_count=0
  
  while IFS= read -r tracker; do
    # 去重检查
    lower_tracker=$(tr '[:upper:]' '[:lower:]' <<< "$tracker")
    if [[ -n "${existing_trackers[$lower_tracker]}" ]]; then
      continue
    fi

    # 生成唯一ID（全局递增）
    new_id=$((CURRENT_ID++))
    existing_trackers["$lower_tracker"]="$new_id"

    # 构建插入语句
    if [ $current_batch -eq 0 ]; then
      batch_sql="BEGIN;"
    fi
    
    batch_sql+="INSERT INTO USER_TRACKERS (ID, UID, TRACKER) VALUES ($new_id, $MY_UID, '$tracker');"
    ((current_batch++))
    ((success_count++))

    # 达到批次大小提交
    if [ $current_batch -ge $BATCH_SIZE ]; then
      batch_sql+="COMMIT;"
      if ! sqlite3 "$DB_FILE" "$batch_sql" 2>/dev/null; then
        echo "  [错误] 批次插入失败，尝试单条插入"
        
        # 失败后逐条插入
        while IFS=';' read -ra stmts; do
          for stmt in "${stmts[@]}"; do
            [ -z "$stmt" ] && continue
            if ! sqlite3 "$DB_FILE" "$stmt"; then
              echo "  [错误] 插入失败: ${stmt:0:60}..."
              ((CURRENT_ID--))  # 回退ID计数器
            fi
          done
        done <<< "${batch_sql//COMMIT;/}"
      fi
      current_batch=0
      batch_sql=""
    fi
  done <<< "$valid_trackers"

  # 提交剩余数据
  if [ $current_batch -gt 0 ]; then
    batch_sql+="COMMIT;"
    if ! sqlite3 "$DB_FILE" "$batch_sql"; then
      echo "  [错误] 最后批次插入失败"
      # 失败后ID不回退，保持递增避免冲突
    fi
  fi

  echo "  [成功] 有效插入 $success_count 个Tracker"
done

# 最终去重处理
echo "================================="
original_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM USER_TRACKERS;")

# 创建临时表去重
sqlite3 "$DB_FILE" <<EOL
CREATE TEMP TABLE tmp_trackers AS 
SELECT MIN(ID) as keep_id, TRACKER 
FROM USER_TRACKERS 
GROUP BY TRACKER;

DELETE FROM USER_TRACKERS 
WHERE ID NOT IN (SELECT keep_id FROM tmp_trackers);

DROP TABLE tmp_trackers;
EOL

new_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM USER_TRACKERS;")
deleted_count=$((original_count - new_count))
echo "总计删除重复Tracker: $deleted_count"
echo "最终有效Tracker数量: $new_count"

echo " 正在启动下载应用服务"
systemctl start dlcenter
echo "Tracker更新操作已完成。"