#!/bin/bash
# 安装 k3s v1.36.2，配置阿里云镜像加速，并启动单节点集群
# 依赖：wget, chmod, nohup, sleep, kubectl (k3s 自带)
# 注意：该脚本会清理旧 k3s 数据

set -e

echo ">>> 清理可能残留的旧 k3s 进程和数据..."
sudo pkill -9 -f "k3s server" 2>/dev/null || true
sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/k3s

echo ">>> 下载 k3s 二进制 (v1.36.2) ..."
wget -q --show-progress -O /usr/local/bin/k3s \
  https://github.com/k3s-io/k3s/releases/download/v1.36.2%2Bk3s1/k3s
sudo chmod +x /usr/local/bin/k3s

echo ">>> 创建镜像加速配置 (docker.io -> registry.cn-hangzhou.aliyuncs.com) ..."
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<-'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://registry.cn-hangzhou.aliyuncs.com"
EOF

echo ">>> 后台启动 k3s server (日志写入 /tmp/k3s.log) ..."
nohup sudo /usr/local/bin/k3s server --write-kubeconfig-mode 644 > /tmp/k3s.log 2>&1 &
echo "等待 90 秒让集群初始化..."
sleep 90

echo ">>> 设置 KUBECONFIG..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

echo ">>> 检查节点状态..."
sudo /usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes

echo ">>> 如果节点显示 Ready，则 k3s 安装成功！"