# 部署 k3s + GPU 全故障排障指南

本指南记录在阿里云 GPU 实例（T4）上部署 k3s 单节点集群并注册 NVIDIA GPU 资源的完整过程，包含所有遇到的错误、日志分析、解决命令和最终成功配置。  

---

## 目录
1. [故障 1：系统包管理器错误](#故障-1系统包管理器错误)
2. [故障 2：k3s 安装脚本静默卡死](#故障-2k3s-安装脚本静默卡死)
3. [故障 3：节点 NotReady - 镜像拉取超时与 CNI 未初始化](#故障-3节点-notready---镜像拉取超时与-cni-未初始化)
4. [故障 4：k3s 进程 panic - kine.sock 丢失](#故障-4k3s-进程-panic---kinesock-丢失)
5. [故障 5：systemd 端口冲突](#故障-5systemd-端口冲突)
6. [故障 6：NVIDIA 设备插件 CrashLoopBackOff (exit 139) 与注册超时](#故障-6nvidia-设备插件-crashloopbackoff-exit-139-与注册超时)
7. [排障速查表](#排障速查表)
8. [最终成功配置汇总](#最终成功配置汇总)

---

## 环境信息
- **云平台**：阿里云 ECS  
- **实例规格**：ecs.gn6i-c2g1.xlarge (2vCPU, 8GiB, 1× NVIDIA T4 16GB)  
- **操作系统**：Ubuntu 22.04 LTS（预装 NVIDIA Driver 535 + CUDA 12.2）  
- **K3s 版本**：v1.36.2+k3s1  

---

## 故障 1：系统包管理器错误

**现象**  
更新系统时，终端最后几行报错，整个升级失败：
```
$ sudo apt update && sudo apt upgrade -y
...
Errors were encountered while processing:
 ca-certificates
 snapd
E: Sub-process /usr/bin/dpkg returned an error code (1)
```

**日志分析**  
查看 apt 的详细日志：
```bash
tail -20 /var/log/apt/term.log
```
输出关键行：
```
dpkg: dependency problems prevent configuration of snapd:
snapd depends on ca-certificates; however:
Package ca-certificates is not configured yet.
```

**原因**  
`ca-certificates` 包在上次升级过程中未正确配置，导致依赖它的 `snapd` 也无法配置。

**解决步骤**  
1. 强制配置所有未完成的包：
   ```bash
   sudo dpkg --configure -a
   ```
2. 重装 `ca-certificates` 修复证书状态：
   ```bash
   sudo apt install --reinstall ca-certificates -y
   ```
3. 修复损坏的依赖关系：
   ```bash
   sudo apt --fix-broken install -y
   ```
4. 再次更新系统：
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

执行完毕后，系统包管理恢复正常。

---

## 故障 2：k3s 安装脚本静默卡死

**现象**  
执行官方脚本后，终端长时间无任何输出，进程挂起：
```bash
$ curl -sfL https://get.k3s.io | sh -
# 光标一直闪烁，无任何输出，持续超过 5 分钟
```

**原因**  
- `curl -s` 静默模式不显示下载进度。  
- GitHub Release 在国内下载速度慢，导致二进制文件（约 60MB）长时间无法完成。

**排查方法**  
查看进程状态：
```bash
ps aux | grep k3s
```
发现只有 `curl` 进程，没有开始安装。

**解决步骤**  
直接手动下载 k3s 二进制并启动：

1. 下载 k3s（使用 `wget` 显示进度条）：
   ```bash
   wget -O /usr/local/bin/k3s https://github.com/k3s-io/k3s/releases/download/v1.36.2%2Bk3s1/k3s
   ```
   如果下载速度 < 50KB/s，可使用镜像（但本次直接下载成功）。

2. 赋予执行权限：
   ```bash
   sudo chmod +x /usr/local/bin/k3s
   ```

3. 后台启动 k3s 服务器：
   ```bash
   nohup sudo k3s server --write-kubeconfig-mode 644 > /tmp/k3s.log 2>&1 &
   sleep 90
   ```

4. 检查节点状态：
   ```bash
   sudo k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes
   ```
   **初始状态为 NotReady（见故障 3），后续修复后变为 Ready。**

---

## 故障 3：节点 NotReady - 镜像拉取超时与 CNI 未初始化

**现象**  
节点始终为 NotReady 状态：
```bash
$ kubectl get nodes
NAME          STATUS     ROLES           AGE   VERSION
gpu-node-01   NotReady   control-plane   2m    v1.36.2+k3s1
```

所有系统 Pod 卡在 `ContainerCreating` 或 `Pending`：
```bash
$ kubectl -n kube-system get pods
NAME                                      READY   STATUS              RESTARTS   AGE
coredns-5f5694d56b-nfwjb                  0/1     ContainerCreating   0          2m
helm-install-traefik-bhh8p                0/1     ContainerCreating   0          2m
local-path-provisioner-58d557dc48-5dtrf   0/1     ContainerCreating   0          2m
```

**日志分析**  
查看 k3s 日志尾部：
```bash
tail -30 /tmp/k3s.log
```
发现两种关键错误：

1. **Pause 镜像拉取超时**：
   ```
   E0706 10:48:20.208782   ... "Failed to create sandbox for pod" err="failed to pull image \"rancher/mirrored-pause:3.6\": dial tcp 108.160.170.26:443: i/o timeout"
   ```
2. **CNI 插件未初始化**：
   ```
   I0706 10:47:08 ... "Container runtime network not ready" networkReady="NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized"
   ```

**根本原因**  
- Pause 镜像是每个 Pod 的“沙箱”基础镜像，被 k3s 的 containerd 从 Docker Hub 拉取失败，导致所有 Pod 无法创建网络栈。  
- CNI 未初始化是由于 pause 镜像一直不可用，kubelet 无法进入就绪状态；早期日志中也有 `subnet.env not found` 的瞬态错误，但核心瓶颈在镜像拉取。

**错误尝试与规避**  
- **错误做法**：直接修改 `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl` 添加阿里云镜像加速，**覆盖了 k3s 自带的默认 CNI 配置**，导致 CNI 插件彻底丢失。  
  > 教训：**不要直接编辑 containerd 模板**，应使用 k3s 官方的 `registries.yaml`。

**正确解决步骤**  
1. 彻底清理旧数据：
   ```bash
   sudo pkill -9 -f "k3s server"
   sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/k3s
   ```
2. 创建 k3s 镜像加速配置文件：
   ```bash
   sudo mkdir -p /etc/rancher/k3s
   sudo tee /etc/rancher/k3s/registries.yaml <<-'EOF'
   mirrors:
     docker.io:
       endpoint:
         - "https://registry.cn-hangzhou.aliyuncs.com"
   EOF
   ```
3. 重新启动 k3s：
   ```bash
   nohup sudo k3s server --write-kubeconfig-mode 644 > /tmp/k3s.log 2>&1 &
   sleep 90
   ```
4. 验证节点：
   ```bash
   kubectl get nodes
   # NAME          STATUS   ROLES           AGE   VERSION
   # gpu-node-01   Ready    control-plane   2m    v1.36.2+k3s1
   ```

至此节点 Ready，系统 Pod 全部运行。

---

## 故障 4：k3s 进程 panic - kine.sock 丢失

**现象**  
节点 Ready 后不久，再次执行 `kubectl get nodes` 出现：
```
The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?
```
查看 k3s 日志最后几行：
```bash
tail -20 /tmp/k3s.log
```
输出：
```
F0706 11:16:37.415812   54705 hooks.go:203] PostStartHook "start-service-ip-repair-controllers" failed: unable to perform initial IP and Port allocation check
panic: ...
dial unix kine.sock: connect: no such file or directory
```
随后 k3s 进程退出。

**原因**  
多次强制杀死 k3s 进程（`kill -9`）导致 k3s 内嵌存储 kine 的 Unix socket 文件损坏或锁冲突，新进程无法初始化存储层，进而引发 panic。

**解决步骤**  
必须彻底清空所有 k3s 数据目录，让 k3s 重建数据库：

```bash
sudo pkill -9 -f "k3s server"
sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/k3s
# 重新创建镜像加速配置（同故障 3）
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml <<-'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://registry.cn-hangzhou.aliyuncs.com"
EOF
# 重新启动
nohup sudo k3s server --write-kubeconfig-mode 644 > /tmp/k3s.log 2>&1 &
sleep 90
kubectl get nodes   # Ready
```

---

## 故障 5：systemd 端口冲突

**现象**  
将 k3s 配置为 systemd 服务后，启动服务失败：
```bash
$ sudo systemctl start k3s.service
$ sudo systemctl status k3s.service
...
Failed to listen and serve err="listen tcp 0.0.0.0:10250: bind: address already in use"
```
同时 `kubectl` 报错 `connection refused`。

**排查**  
查看端口占用：
```bash
sudo ss -tlnp | grep -E "10250|10248|6443"
```
输出显示：
```
LISTEN  0  4096  127.0.0.1:10248  0.0.0.0:*  users:(("k3s-server",pid=6296,fd=205))
LISTEN  0  4096         *:6443          *:*  users:(("k3s-server",pid=6296,fd=12))
LISTEN  0  4096         *:10250         *:*  users:(("k3s-server",pid=6296,fd=185))
```
说明之前手动 `nohup` 启动的 k3s 进程仍存活，与 systemd 实例端口冲突。

**解决步骤**  
1. 停止 systemd 服务，彻底杀死所有 k3s 进程：
   ```bash
   sudo systemctl stop k3s.service
   sudo pkill -9 -f "k3s server"
   ```
2. 稍等几秒，再次检查端口是否释放：
   ```bash
   sudo ss -tlnp | grep -E "10250|10248|6443"
   ```
   无输出即表示端口已释放。
3. 重新启动 systemd 服务：
   ```bash
   sudo systemctl start k3s.service
   sleep 30
   kubectl get nodes
   ```
   节点恢复 Ready，systemd 开机自启正常工作。

**附 systemd 服务文件** (`/etc/systemd/system/k3s.service`)：
```ini
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server --write-kubeconfig-mode 644
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

---

## 故障 6：NVIDIA 设备插件 CrashLoopBackOff (exit 139) 与注册超时

**现象**  
部署 NVIDIA device plugin DaemonSet 后，Pod 反复重启：
```bash
$ kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
NAME                                   READY   STATUS             RESTARTS   AGE
nvidia-device-plugin-daemonset-qfwmq   0/1     CrashLoopBackOff   5          3m
```

**第一阶段排查 - 段错误 (exit 139)**  
查看 Pod 详情：
```bash
kubectl -n kube-system describe pod nvidia-device-plugin-daemonset-qfwmq
```
输出：
```
State:       Terminated
  Reason:    Error
  Exit Code: 139
```
Exit Code 139 表示段错误，通常是内存访问违规或库冲突。

**原因**  
早期尝试设置 `LD_LIBRARY_PATH` 并挂载宿主库，导致容器内的库与宿主库版本冲突，程序崩溃。

**纠正 - 使用 NVIDIA 容器运行时**  
修改 DaemonSet，添加 `runtimeClassName: nvidia`，移除手动库挂载和环境变量：
```yaml
spec:
  runtimeClassName: nvidia         # 让运行时自动注入驱动
  containers:
    - name: nvidia-device-plugin-ctr
      image: nvcr.io/nvidia/k8s-device-plugin:v0.14.1
      env:
        - name: FAIL_ON_INIT_ERROR
          value: "false"
      volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
  volumes:
    - name: device-plugin
      hostPath:
        path: /var/lib/kubelet/device-plugins
        type: DirectoryOrCreate
```
应用后，Pod 启动成功但日志显示新错误：
```
Could not contact Kubelet: context deadline exceeded
```

**第二阶段排查 - 注册超时**  
设备插件尝试向 kubelet 注册，但连接超时。检查 kubelet socket 位置：
```bash
sudo find /var -name "kubelet.sock" 2>/dev/null
```
返回：
```
/var/lib/kubelet/device-plugins/kubelet.sock
/var/lib/kubelet/pod-resources/kubelet.sock
```
宿主机上 socket 确实存在，问题出在容器内。

**原因分析**  
k3s 的设备插件路径默认是 `/var/lib/rancher/k3s/agent/kubelet/device-plugins`，该目录下没有 `kubelet.sock`。之前的 DaemonSet 错误地将容器的 `/var/lib/kubelet/device-plugins` 挂载到了该空目录，导致容器无法与 kubelet 通信。

**最终修复**  
将 volume 的 hostPath 直接指向宿主机上真实存在的 `/var/lib/kubelet/device-plugins`：
```yaml
volumes:
  - name: device-plugin
    hostPath:
      path: /var/lib/kubelet/device-plugins   # 宿主机真实路径
      type: DirectoryOrCreate
```
应用新配置：
```bash
kubectl -n kube-system delete daemonset nvidia-device-plugin-daemonset
kubectl apply -f nvidia-device-plugin.yaml
```

**验证**  
等待 30 秒后查看日志：
```bash
kubectl -n kube-system logs -l name=nvidia-device-plugin-ds --tail 10
```
输出中包含：
```
I0707 03:58:30.735384       1 server.go:125] Registered device plugin for 'nvidia.com/gpu' with Kubelet
```
检查节点资源：
```bash
kubectl describe node | grep nvidia.com/gpu
```
```
Capacity:
  nvidia.com/gpu:     1
Allocatable:
  nvidia.com/gpu:     1
```
**GPU 资源成功注册！**

---

## 排障速查表

| 目标 | 命令 |
|------|------|
| 查看 k3s 日志 | `journalctl -u k3s.service --no-pager \| tail -50` 或 `tail -50 /tmp/k3s.log` |
| 查看节点状态 | `kubectl get nodes` |
| 查看系统 Pod 详情 | `kubectl -n kube-system get pods -o wide` |
| 查看 Pod 失败事件 | `kubectl describe pod <pod-name> -n <namespace>` |
| 查看容器日志 | `kubectl logs <pod-name> -n <namespace>` |
| 检查端口占用 | `sudo ss -tlnp \| grep <port>` |
| 查找 kubelet socket | `sudo find /var -name "kubelet.sock" 2>/dev/null` |
| 彻底清理 k3s 重新开始 | `sudo pkill -9 -f "k3s server" && sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/k3s` |

---

## 最终成功配置汇总

**1. 系统镜像加速** (`/etc/rancher/k3s/registries.yaml`)
```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://registry.cn-hangzhou.aliyuncs.com"
```

**2. k3s systemd 服务** (`/etc/systemd/system/k3s.service`)
```ini
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server --write-kubeconfig-mode 644
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

**3. NVIDIA 设备插件 DaemonSet** (`deploy/nvidia-device-plugin.yaml`)
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      runtimeClassName: nvidia
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      priorityClassName: system-node-critical
      containers:
        - name: nvidia-device-plugin-ctr
          image: nvcr.io/nvidia/k8s-device-plugin:v0.14.1
          env:
            - name: FAIL_ON_INIT_ERROR
              value: "false"
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
            type: DirectoryOrCreate
```

---

## 总结
本文档详细记录了从一台空白 GPU 实例到 k3s 集群就绪、GPU 资源注册的完整过程，包含 6 个真实故障的日志输出、排查思路和修复命令。