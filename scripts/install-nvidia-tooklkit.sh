#!/bin/bash
# 安装 NVIDIA Container Toolkit (nvidia-container-runtime)
# 本脚本添加 NVIDIA 官方仓库并安装运行时

set -e

echo ">>> 导入 NVIDIA 仓库 GPG 密钥..."
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-container-runtime/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-runtime-keyring.gpg

echo ">>> 添加 NVIDIA 仓库..."
echo "deb [signed-by=/usr/share/keyrings/nvidia-container-runtime-keyring.gpg] \
  https://nvidia.github.io/nvidia-container-runtime/$distribution $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-runtime.list

echo ">>> 更新并安装 nvidia-container-runtime..."
sudo apt update
sudo apt install -y nvidia-container-runtime

echo ">>> 验证安装..."
dpkg -l | grep nvidia-container-runtime

echo ">>> nvidia-container-runtime 安装完成。"