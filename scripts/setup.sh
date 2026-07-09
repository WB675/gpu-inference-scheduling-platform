#!/bin/bash
set -e

echo "########## Deploying NVIDIA Device Plugin ##########"
kubectl apply -f deploy/nvidia-device-plugin.yaml

echo "########## Deploying Volcano Queue & PriorityClasses ##########"
kubectl apply -f deploy/volcano/queue-and-priority.yaml

echo "########## Deploying Monitoring Stack ##########"
kubectl apply -f deploy/monitoring/monitoring-components.yaml

echo "########## Waiting for Grafana deployment to be ready ##########"
kubectl -n monitoring rollout status deployment/grafana --timeout=120s || true

echo "########## Setup complete. Run 'scripts/run_exp.sh' for demo. ##########"
