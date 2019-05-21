#!/bin/bash

#####		debian/CentOS 一键安装诛仙		#####
#####		作者：vipkj.net					#####
#####		更新时间：2019-05-20			#####
#安装依赖
function rely(){
yum install -y wget gcc gcc-c++ libffi-devel zlib-devel
}
	#下载源码
	wget http://pan.vipkj.net/%E5%8D%95%E6%9C%BA%E6%B8%B8%E6%88%8F/%E8%AF%9B%E4%BB%99/%E6%9C%8D%E5%8A%A1%E7%AB%AF/422/1.tar.gz
	#解压
	tar xvfz 1.tar.gz -C /
	#清理工作
	cd /root
	rm -rf 1.tar.gz
	echo "------------------------------------------------"
	echo '|	恭喜您，诛仙 安装完成！  		 |'	
	echo "------------------------------------------------"
}

###启动诛仙服务端
function uninstall(){
	cd /root
	./Myqd
	echo "------------------------------------------------"
	echo '诛仙服务端启动完成！				 |'	
	echo "------------------------------------------------"
}

echo "------------------------------------------------------------"
echo '一键安装诛仙脚本 ^_^ 请选择需要执行的操作：'
echo "1) 安装诛仙"
echo "2) 启动诛仙 "
echo "q) 退出！"
echo "------------------------------------------------------------"
read -p ":" istype

case $istype in
	1)
		install_py37
	;;
	2)
		uninstall
	;;
	'q')
		exit
	;;
	*)
		echo '参数错误！'
		exit
	;;
esac	
