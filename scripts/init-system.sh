#!/bin/bash
# 系统初始化：修复 dpkg 错误、安装基础工具
# 适用于 Ubuntu 22.04，使用阿里云 GPU 镜像

set -e

echo ">>> 修复 ca-certificates 和 snapd 未配置的问题..."
sudo dpkg --configure -a || true
sudo apt install --reinstall ca-certificates -y
sudo apt --fix-broken install -y

echo ">>> 再次更新系统..."
sudo apt update && sudo apt upgrade -y

echo ">>> 安装常用工具 (curl, wget, vim, jq)..."
sudo apt install -y curl wget vim jq

echo ">>> 系统初始化完成！"