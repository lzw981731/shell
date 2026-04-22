#!/bin/bash

# ==========================================
# XAMPP 综合管理脚本 (带进度条防错位 + 密码修改)
# ==========================================

# 1. 安装 XAMPP
function install_xampp() {
    clear
    echo "=========================================="
    echo "             1. 安装 XAMPP"
    echo "=========================================="
    
    if [ -d "/opt/lampp" ]; then
        echo "【警告】检测到系统已存在 /opt/lampp 文件夹！"
        read -p "XAMPP 可能已经安装。是否强制重新安装？(y/n): " force_install
        if [[ "$force_install" == "y" || "$force_install" == "Y" ]]; then
            echo "正在结束旧的 XAMPP 进程..."
            sudo /opt/lampp/lampp stop >/dev/null 2>&1
            # 使用安全正则匹配，防止误杀脚本自身
            sudo pkill -9 -f "[o]pt/lampp" >/dev/null 2>&1
            echo "正在删除 /opt/lampp 文件夹..."
            sudo rm -rf /opt/lampp
            echo "清理完毕，准备重新安装。"
        else
            echo "已取消安装操作。"
            read -p "按回车键返回主菜单..."
            return
        fi
    fi

    INSTALLER_FILE=""
    local_pkg=$(ls xampp-linux*.run 2>/dev/null | head -n 1)
    
    if [ -n "$local_pkg" ]; then
        echo "检测到当前目录下存在安装包：$local_pkg"
        read -p "是否使用此本地包进行安装？(y/n): " use_local
        if [[ "$use_local" == "y" || "$use_local" == "Y" ]]; then
            INSTALLER_FILE=$local_pkg
        fi
    fi

    if [ -z "$INSTALLER_FILE" ]; then
        echo "准备从 SourceForge 在线下载最新版..."
        latest_version=$(curl -s "https://sourceforge.net/projects/xampp/files/XAMPP%20Linux/" | grep -oP 'title="[0-9]+\.[0-9]+\.[0-9]+"' | head -n 1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')
        
        if [ -z "$latest_version" ]; then
            echo "获取最新版本信息失败，请检查网络。"
            read -p "按回车键返回主菜单..."
            return
        fi

        download_url="https://sourceforge.net/projects/xampp/files/XAMPP%20Linux/${latest_version}/xampp-linux-x64-${latest_version}-0-installer.run/download"
        INSTALLER_FILE="xampp-linux-x64-${latest_version}-0-installer.run"
        echo "开始下载 $INSTALLER_FILE ..."
        wget -q --show-progress -O "$INSTALLER_FILE" "$download_url"
    fi

    chmod +x "$INSTALLER_FILE"
    echo "=========================================="
    echo "开始执行安装程序: $INSTALLER_FILE (静默模式)"
    
    # 彻底关闭 Bash 后台作业提醒，避免输出 Killed
    set +m 
    
    # 后台执行静默安装
    sudo ./"$INSTALLER_FILE" --mode unattended > /dev/null 2>&1 &
    installer_pid=$!

    # 构建正则安全匹配，防止 pkill 误杀当前脚本
    first_char="${INSTALLER_FILE:0:1}"
    rest_chars="${INSTALLER_FILE:1}"
    safe_pattern="[${first_char}]${rest_chars}"

    last_size=0
    same_size_count=0
    
    # 进度条主循环
    while true; do
        sleep 5
        if ! kill -0 $installer_pid 2>/dev/null; then
            printf "\r\033[K安装程序进程已自然退出。\n"
            break
        fi

        if [ ! -d "/opt/lampp" ]; then
            printf "\r\033[K正在等待生成 /opt/lampp 文件夹..."
            continue
        fi

        current_size=$(sudo du -sk /opt/lampp 2>/dev/null | awk '{print $1}')
        if [ -z "$current_size" ]; then current_size=0; fi
        current_size_mb=$((current_size / 1024))
        
        if [ "$current_size" -eq "$last_size" ] && [ "$current_size_mb" -gt 800 ]; then
            same_size_count=$((same_size_count+1))
            printf "\r\033[K当前 /opt/lampp 体积: %s MB | 正在等待文件锁释放 (%d/6)..." "$current_size_mb" "$same_size_count"
        else
            same_size_count=0
            printf "\r\033[K当前 /opt/lampp 体积: %s MB (解压中...)" "$current_size_mb"
        fi
        
        last_size=$current_size
        
        if [ "$same_size_count" -ge 6 ]; then
            if [ -f "/opt/lampp/bin/apachectl" ]; then
                # 精准斩杀，且不报任何错
                sudo kill -9 $installer_pid >/dev/null 2>&1
                sudo pkill -9 -f "$safe_pattern" >/dev/null 2>&1
                
                # 强制恢复终端的回车换行状态 (彻底解决阶梯状错位)
                stty sane
                printf "\r\n已经完成文件锁释放\n"
                break
            fi
        fi
    done
    
    # 恢复 Bash 作业提醒功能
    set -m
    # 再次确保终端格式正常
    stty sane 
    
    echo "=========================================="
    echo "XAMPP 核心文件部署完毕！"
    echo "建议立即执行 [2. 修复 XAMPP 环境]。"
    read -p "按回车键返回主菜单..."
}

# 2. 修复 XAMPP 环境
function fix_xampp() {
    clear
    echo "=========================================="
    echo "          2. 修复 XAMPP 环境 (WSL优化)"
    echo "=========================================="
    
    if [ ! -d "/opt/lampp" ]; then
        echo "错误：未检测到 /opt/lampp 目录，请先执行安装！"
        read -p "按回车键返回主菜单..."
        return
    fi

    echo ">>> [1/5] 手动修复 Apache 配置文件..."
    sudo sed -i 's/^ServerRoot.*/ServerRoot "\/opt\/lampp"/' /opt/lampp/etc/httpd.conf
    sudo sed -i 's/^DocumentRoot.*/DocumentRoot "\/opt\/lampp\/htdocs"/' /opt/lampp/etc/httpd.conf
    sudo sed -i 's/<Directory ".*htdocs">/<Directory "\/opt\/lampp\/htdocs">/' /opt/lampp/etc/httpd.conf
    sudo sed -i 's/^PidFile/#PidFile/g' /opt/lampp/etc/httpd.conf
    sudo sed -i '/^ServerRoot/a PidFile "/opt/lampp/logs/httpd.pid"' /opt/lampp/etc/httpd.conf

    echo ">>> [2/5] 消除 WSL 特有的网络协议警告..."
    grep -q "AcceptFilter http none" /opt/lampp/etc/httpd.conf || sudo sh -c 'echo "AcceptFilter http none" >> /opt/lampp/etc/httpd.conf'
    grep -q "AcceptFilter https none" /opt/lampp/etc/httpd.conf || sudo sh -c 'echo "AcceptFilter https none" >> /opt/lampp/etc/httpd.conf'

    echo ">>> [3/5] 修复 MySQL 配置与重置数据库..."
    grep -q "innodb_use_native_aio" /opt/lampp/etc/my.cnf || sudo sed -i '/^\[mysqld\]/a innodb_use_native_aio = 0' /opt/lampp/etc/my.cnf
    sudo sed -i 's|@@BITNAMI_XAMPP_ROOT@@|/opt/lampp|g' /opt/lampp/etc/my.cnf
    sudo sed -i 's|@@BITROCK_INSTALLDIR@@|/opt/lampp|g' /opt/lampp/etc/my.cnf
    
    sudo rm -rf /opt/lampp/var/mysql/*
    sudo /opt/lampp/bin/mysql_install_db --user=mysql --basedir=/opt/lampp --datadir=/opt/lampp/var/mysql >/dev/null 2>&1
    sudo chown -R mysql:mysql /opt/lampp/var/mysql
    
    sudo /opt/lampp/bin/mysql.server start >/dev/null 2>&1

    echo ">>> [4/5] 修复 phpMyAdmin 与 PHP 引擎..."
    sudo sh -c 'cat << \EOF > /opt/lampp/etc/extra/httpd-xampp.conf
LoadModule php_module modules/libphp.so

<IfModule php_module>
    <FilesMatch "\.php$">
        SetHandler application/x-httpd-php
    </FilesMatch>
    
    Alias /phpmyadmin "/opt/lampp/phpmyadmin"
    <Directory "/opt/lampp/phpmyadmin">
        AllowOverride All
        Require all granted
        DirectoryIndex index.php
    </Directory>
</IfModule>
EOF'

    sudo sed -i 's|@@BITNAMI_XAMPP_ROOT@@|/opt/lampp|g' /opt/lampp/etc/php.ini
    sudo mkdir -p /opt/lampp/temp
    sudo chmod 777 /opt/lampp/temp

    sudo sed -i "s/'config'/'cookie'/g" /opt/lampp/phpmyadmin/config.inc.php
    sudo sed -i 's|@@BITNAMI_XAMPP_ROOT@@|/opt/lampp|g' /opt/lampp/phpmyadmin/config.inc.php
    sudo chmod -R 755 /opt/lampp/phpmyadmin
    sudo chown -R daemon:daemon /opt/lampp/phpmyadmin

    echo ">>> [5/5] 设置 MySQL root 密码为 123456..."
    sudo /opt/lampp/bin/mysqladmin -u root password 123456 2>/dev/null || true

    echo ">>> 重启 Apache..."
    sudo /opt/lampp/bin/apachectl restart >/dev/null 2>&1

    echo "=========================================="
    echo "修复流程彻底完成！"
    echo "数据库密码: 123456"
    echo "测试访问: http://127.0.0.1/phpmyadmin/"
    echo "=========================================="
    read -p "按回车键返回主菜单..."
}

# 3. 启动 XAMPP
function start_xampp() {
    clear
    echo "=========================================="
    echo "        3. 启动 XAMPP / 常用命令"
    echo "=========================================="
    echo "  启动 apachectl :  sudo /opt/lampp/bin/apachectl start"
    echo "  停止 apachectl :  sudo /opt/lampp/bin/apachectl stop"
    echo "  启动 mysql     :  sudo /opt/lampp/bin/mysql.server start"
    echo "  停止 mysql     :  sudo /opt/lampp/bin/mysql.server stop"
    echo "  启动全部服务   :  sudo /opt/lampp/lampp start"
    echo "  停止全部服务   :  sudo /opt/lampp/lampp stop"
    echo "=========================================="
    read -p "按回车键返回主菜单..."
}

# 4. 修改 MySQL 密码 (新增模块)
function modify_mysql_password() {
    clear
    echo "=========================================="
    echo "          4. 修改 MySQL root 密码"
    echo "=========================================="
    
    # 检查 XAMPP 是否存在
    if [ ! -f "/opt/lampp/bin/mysqladmin" ]; then
        echo "错误：未检测到 XAMPP 环境，请先安装！"
        read -p "按回车键返回主菜单..."
        return
    fi

    # 检查 MySQL 是否在运行，未运行则尝试启动
    if ! pgrep -f "/opt/lampp/sbin/mysqld" > /dev/null; then
        echo "检测到 MySQL 未运行，正在启动以修改密码..."
        sudo /opt/lampp/bin/mysql.server start >/dev/null 2>&1
        sleep 2
    fi

    # 交互式修改密码
    echo "【提示】若您刚刚执行过修复环境，默认密码为：123456"
    echo "【提示】若从未设置过密码，直接按回车即可"
    read -p "请输入当前 MySQL root 密码: " old_pass
    read -p "请输入新的 MySQL root 密码: " new_pass

    if [ -z "$new_pass" ]; then
        echo "操作取消：新密码不能为空！"
        read -p "按回车键返回主菜单..."
        return
    fi

    echo "正在执行密码修改指令..."
    
    if [ -z "$old_pass" ]; then
        # 针对原来没有密码的情况
        sudo /opt/lampp/bin/mysqladmin -u root password "$new_pass"
    else
        # 针对原来有密码的情况
        sudo /opt/lampp/bin/mysqladmin -u root -p"$old_pass" password "$new_pass"
    fi

    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ MySQL root 密码修改成功！新密码为: $new_pass"
    else
        echo ""
        echo "❌ 密码修改失败！可能是原密码错误，或者 MySQL 未正常启动。"
    fi
    
    echo "=========================================="
    read -p "按回车键返回主菜单..."
}

# 主循环
while true; do
    clear
    echo "=========================================="
    echo "         XAMPP 自动管理工具菜单"
    echo "=========================================="
    echo "  1. 安装 XAMPP"
    echo "  2. 修复 XAMPP 环境"
    echo "  3. 启动/停止 XAMPP (查看命令)"
    echo "  4. 修改 MySQL 密码"
    echo "  5. 退出脚本"
    echo "=========================================="
    read -p "请输入序号 (1-5): " choice
    
    case $choice in
        1) install_xampp ;;
        2) fix_xampp ;;
        3) start_xampp ;;
        4) modify_mysql_password ;;
        5) clear; echo "退出。"; exit 0 ;;
        *) echo "无效选择！"; sleep 1 ;;
    esac
done