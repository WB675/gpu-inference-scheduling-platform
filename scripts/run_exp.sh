#!/bin/bash
set -e

echo "==> Cleaning up previous demo pods..."
kubectl delete pod low-priority-gpu-pod --ignore-not-found
kubectl delete pod high-priority-gpu-pod --ignore-not-found
sleep 2

echo "==> Deploying low-priority GPU pod..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: low-priority-gpu-pod
spec:
  priorityClassName: low-priority
  containers:
  - name: dummy
    image: busybox:latest
    imagePullPolicy: IfNotPresent
    command: ["sleep", "3600"]
    resources:
      limits:
        nvidia.com/gpu: 1
  runtimeClassName: nvidia
EOF

echo "==> Waiting for low-priority pod to be Running..."
kubectl wait --for=condition=Ready pod/low-priority-gpu-pod --timeout=60s

echo "==> Low-priority pod is running, GPU allocated:"
kubectl get pod low-priority-gpu-pod
kubectl describe node | grep -A5 "Allocated resources" | grep nvidia.com/gpu

echo "==> Deploying high-priority GPU pod (should trigger preemption)..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: high-priority-gpu-pod
spec:
  priorityClassName: high-priority
  containers:
  - name: dummy
    image: busybox:latest
    imagePullPolicy: IfNotPresent
    command: ["sleep", "300"]
    resources:
      limits:
        nvidia.com/gpu: 1
  runtimeClassName: nvidia
EOF

echo "==> Observing pods (low-priority should terminate, high-priority start) ..."
kubectl get pods -w