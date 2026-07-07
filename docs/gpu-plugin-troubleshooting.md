# NVIDIA Device Plugin 部署全故障排障指南

本指南记录了在 K3s 单节点集群上部署 NVIDIA 设备插件以暴露 GPU 资源时遇到的真实错误、排查过程及最终解决方案。所有命令和日志均来自实际环境。

---

## 环境

- **Kubernetes 发行版**: K3s v1.36.2+k3s1
- **操作系统**: Ubuntu 22.04 LTS (预装 NVIDIA Driver 535 + CUDA 12.2)
- **GPU**: Tesla T4 16GB (阿里云 ecs.gn6i-c2g1.xlarge)
- **NVIDIA 容器运行时**: nvidia-container-runtime 3.14.0

---

## 故障 1：容器退出码 139（段错误）

### 现象
部署 DaemonSet 后，Pod 反复 CrashLoopBackOff：
```bash
$ kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
NAME                                   READY   STATUS             RESTARTS   AGE
nvidia-device-plugin-daemonset-qfwmq   0/1     CrashLoopBackOff   5          3m
```

### 日志输出
Pod 没有打印任何日志，容器启动后立即退出。
```bash
$ kubectl -n kube-system logs nvidia-device-plugin-daemonset-qfwmq
# 空输出
```

### Pod 详情
```bash
$ kubectl -n kube-system describe pod nvidia-device-plugin-daemonset-qfwmq
```
关键字段：
```
State:       Terminated
  Reason:    Error
  Exit Code: 139
  ...
Environment:
  FAIL_ON_INIT_ERROR:  false
  NVIDIA_DRIVER_ROOT:  /host
  LD_LIBRARY_PATH:     /host/usr/lib/x86_64-linux-gnu:/host/usr/local/cuda/lib64
```

### 原因分析
Exit code 139 是段错误（Segmentation Fault）。我们手动设置了 `LD_LIBRARY_PATH` 以挂载宿主机的 NVIDIA 库目录，但容器内的动态链接器却因此装载了与容器内其他库不兼容的宿主库，导致程序崩溃。

### 解决方案
**移除手动库挂载和环境变量，改用 `runtimeClassName: nvidia`**，让 NVIDIA 容器运行时自动注入驱动。

修改后的 DaemonSet 关键部分：
```yaml
spec:
  runtimeClassName: nvidia   # 让运行时自动注入驱动库
  containers:
    - name: nvidia-device-plugin-ctr
      image: nvcr.io/nvidia/k8s-device-plugin:v0.14.1
      env:
        - name: FAIL_ON_INIT_ERROR
          value: "false"
      # 不再设置 NVIDIA_DRIVER_ROOT 或 LD_LIBRARY_PATH
      volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
  volumes:
    - name: device-plugin
      hostPath:
        path: /var/lib/kubelet/device-plugins
        type: DirectoryOrCreate
```
应用此配置后，Pod 可以正常启动，不再出现段错误。

---

## 故障 2：设备插件注册超时（`context deadline exceeded`）

### 现象
DaemonSet 的 Pod 运行正常，但 GPU 资源未出现在节点中，且设备插件日志反复报注册超时。
```bash
$ kubectl -n kube-system logs -l name=nvidia-device-plugin-ds --tail 20
```
输出包含：
```
I0707 03:46:12.941445  factory.go:107] Detected NVML platform: found NVML library
I0707 03:46:12.967638  server.go:165]  Starting GRPC server for 'nvidia.com/gpu'
I0707 03:46:12.968511  server.go:117]  Starting to serve 'nvidia.com/gpu' on /var/lib/kubelet/device-plugins/nvidia-gpu.sock
I0707 03:46:17.971187  server.go:121]  Could not register device plugin: context deadline exceeded
E0707 03:46:17.971326  main.go:278]     Could not contact Kubelet. Did you enable the device plugin feature gate?
```

### 检查 kubelet socket 位置
在宿主机上查找 `kubelet.sock`：
```bash
$ sudo find /var -name "kubelet.sock" 2>/dev/null
/var/lib/kubelet/device-plugins/kubelet.sock
/var/lib/kubelet/pod-resources/kubelet.sock
```

### 挂载目录检查
查看容器内设备插件期望的目录是否与宿主机匹配。我们之前将 Pod 的 `/var/lib/kubelet/device-plugins` 挂载到了 `/var/lib/rancher/k3s/agent/kubelet/device-plugins`（K3s 默认路径），但该目录下并没有 `kubelet.sock`。
```bash
$ ls -la /var/lib/rancher/k3s/agent/kubelet/device-plugins/
total 8
drwxr-xr-x 2 root root 4096 Jul  7 11:51 .
drwxr-xr-x 3 root root 4096 Jul  7 11:26 ..
```

### 原因
设备插件在容器内向 `/var/lib/kubelet/device-plugins/kubelet.sock` 发送注册请求，但实际挂载到的宿主机路径中没有该 socket 文件，导致连接超时。**K3s 的 kubelet 实际使用的设备插件目录就是 `/var/lib/kubelet/device-plugins`**，而我们错误地挂载到了另一个空目录。

### 解决方案
**将 DaemonSet 的 hostPath 直接指定为宿主机上的真实目录** `/var/lib/kubelet/device-plugins`。

```yaml
volumes:
  - name: device-plugin
    hostPath:
      path: /var/lib/kubelet/device-plugins   # 真实 kubelet device-plugins 目录
      type: DirectoryOrCreate
```

更新 DaemonSet：
```bash
kubectl -n kube-system delete daemonset nvidia-device-plugin-daemonset
kubectl apply -f nvidia-device-plugin.yaml
```

### 验证
等待 30 秒后查看日志：
```bash
$ kubectl -n kube-system logs -l name=nvidia-device-plugin-ds --tail 10
I0707 03:58:30.735384   server.go:125]  Registered device plugin for 'nvidia.com/gpu' with Kubelet
```
检查节点资源：
```bash
$ kubectl describe node | grep nvidia.com/gpu
Capacity:
  nvidia.com/gpu:  1
Allocatable:
  nvidia.com/gpu:  1
```
**GPU 资源成功暴露！**

---

## 最终稳定的 DaemonSet 配置

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
      runtimeClassName: nvidia                    # 关键1：使用 NVIDIA 运行时
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
            path: /var/lib/kubelet/device-plugins  # 关键2：K3s 真实路径
            type: DirectoryOrCreate
```

---

## 排障常用命令

| 目的 | 命令 |
|------|------|
| 查看设备插件 Pod 日志 | `kubectl -n kube-system logs -l name=nvidia-device-plugin-ds --tail 20` |
| 查看 Pod 退出码和事件 | `kubectl -n kube-system describe pod <pod-name>` |
| 查找 kubelet socket 位置 | `sudo find /var -name "kubelet.sock" 2>/dev/null` |
| 检查 GPU 驱动状态 | `nvidia-smi` |
| 验证节点 GPU 资源 | `kubectl describe node \| grep nvidia.com/gpu` |
| 强制重新部署 DaemonSet | `kubectl -n kube-system delete daemonset nvidia-device-plugin-daemonset && kubectl apply -f nvidia-device-plugin.yaml` |

---

## 经验教训

- **不要手动挂载 NVIDIA 库**。使用 `runtimeClassName: nvidia` 让运行时自动注入，避免库版本冲突导致的段错误。
- **确认 kubelet 的设备插件目录**。K3s 虽然有自己的数据目录，但 device plugin 实际仍使用宿主机上的 `/var/lib/kubelet/device-plugins`。挂载错目录会导致注册超时。
- Exit code 139 总是意味着库或内存问题，需要检查容器环境变量和挂载是否与容器内库兼容。
