#!/bin/bash
# 启动 k3s 集群 (基于 systemd 服务或备用手动启动)
# 如果你的 k3s 已经通过 systemd 管理，它会自动尝试 systemd 启动；
# 否则使用 nohup 后台启动。

set -e

# 优先使用 systemd 服务
if systemctl list-unit-files | grep -q k3s.service; then
    echo ">>> 检测到 systemd 服务，启动 k3s..."
    sudo systemctl start k3s
else
    echo ">>> systemd 服务不存在，使用 nohup 手动启动..."
    sudo pkill -9 -f "k3s server" 2>/dev/null || true
    nohup sudo /usr/local/bin/k3s server --write-kubeconfig-mode 644 > /tmp/k3s.log 2>&1 &
fi

echo ">>> 等待 30 秒..."
sleep 30

echo ">>> 设置 KUBECONFIG..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo ">>> 检查节点状态..."
kubectl get nodes

echo ">>> 启动完成。"