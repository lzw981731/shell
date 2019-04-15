#!/bin/bash

#####		CentOS 7一键安装Python 3		#####
#####		作者：xiaoz.me					#####
#####		更新时间：2018-07-20			#####
#安装依赖
function rely(){
apt-get install wget gcc gcc-c++ libffi-devel zlib-devel
}
	#下载源码
	wget http://pan.vipkj.net/%E5%8D%95%E6%9C%BA%E6%B8%B8%E6%88%8F/%E8%AF%9B%E4%BB%99/%E6%9C%8D%E5%8A%A1%E7%AB%AF/16%E7%BA%AF%E7%AB%AF/zx.tar.gz
	#解压
	tar   -zxvf zx.tar.gz
	#清理工作
	cd /root
	rm -rf zx.tar.gz
  #启动游戏服务器
  cd /root
  ./start
 #启动完成
	echo "------------------------------------------------"
	echo '|	恭喜您，诛仙 3安装完成！  		 |'	
	echo "------------------------------------------------"
}

###卸载Python 3
function uninstall(){
	rm -rf /usr/local/python3
	rm -rf /usr/bin/python3
	rm -rf /usr/bin/pip3
	echo "------------------------------------------------"
	echo '|	Python 3已卸载！				 |'	
	echo "------------------------------------------------"
}

echo "------------------------------------------------------------"
echo '一键安装诛仙3脚本 ^_^ 请选择需要执行的操作：'
echo "1) 安装诛仙3"
echo "2) 卸载诛仙 3"
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
