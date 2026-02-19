#!/usr/bin/env bash
set -euo pipefail

# reinstall-all.sh
# 目標：在全新 kind-task1 上，重建最小可驗收鏈路
# Cilium + Kong(KIC) + tenant-a/tenant-b(LiteLLM) + Kong Host 路由 + key-auth(API key)

# === Run-folder log (每行加時間戳) ===
RUN_DIR="$(pwd)"
RUN_LOG_FILE="${RUN_DIR}/reinstall-all.$(date +%Y%m%d-%H%M%S).log"

ts() {
  while IFS= read -r line; do
    printf '[%s] %s\n' "$(date '+%F %T')" "$line"
  done
}

exec > >(ts | tee -a "${RUN_LOG_FILE}") 2>&1

log() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }; }

log "Run log file: ${RUN_LOG_FILE}"

need kubectl
need docker
need kind
need helm
need curl

CTX="$(kubectl config current-context)"
if [[ "${CTX}" != "kind-task1" ]]; then
  log "ERROR: current-context is ${CTX}, expected kind-task1"
  exit 1
fi

log "Waiting for nodes Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -o wide

KIND_CLUSTER="task1"

preload() {
  local img="$1"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    log "docker pull ${img}"
    docker pull "$img"
  else
    log "Host already has ${img}"
  fi
  log "kind load docker-image ${img} --name ${KIND_CLUSTER}"
  kind load docker-image "$img" --name "${KIND_CLUSTER}" >/dev/null
}

log "Preloading images (avoid ImagePullBackOff on kind nodes)"
preload "postgres:15-alpine" || true
preload "python:3.11-slim"   || true
# 若你 ghcr 常被擋才開：
# preload "ghcr.io/berriai/litellm:main" || true

log "Adding Helm repos"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update

# --- Cilium ---
# 你剛剛已經成功裝起來了；這裡做成可重跑：已存在就 upgrade
log "Installing/Upgrading Cilium"
kubectl create ns kube-system >/dev/null 2>&1 || true
helm upgrade --install cilium cilium/cilium \
  -n kube-system \
  --set kubeProxyReplacement=false \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1

kubectl -n kube-system rollout status ds/cilium --timeout=300s
kubectl -n kube-system get ds cilium -o wide
kubectl -n kube-system get pods -l k8s-app=cilium -o wide

# --- Kong (DB-less) ---
log "Installing Kong (DB-less, ingressController enabled, proxy NodePort)"
kubectl create ns kong >/dev/null 2>&1 || true
helm upgrade --install kong kong/kong \
  -n kong \
  --set ingressController.enabled=true \
  --set ingressController.installCRDs=true \
  --set env.database=off \
  --set admin.enabled=true \
  --set admin.type=ClusterIP \
  --set proxy.type=NodePort \
  --set proxy.http.nodePort=31451 \
  --set proxy.tls.nodePort=31832

kubectl -n kong rollout status deploy/kong-kong --timeout=300s || true
kubectl -n kong rollout status deploy/kong-kong-ingress-controller --timeout=300s || true
kubectl -n kong get svc -o wide

# --- Monitoring (可選) ---
log "Installing kube-prometheus-stack (monitoring namespace)"
kubectl create ns monitoring >/dev/null 2>&1 || true
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --set grafana.enabled=true \
  --set alertmanager.enabled=true

kubectl -n monitoring rollout status deploy/kps-grafana --timeout=300s || true

# --- Tenants + quotas ---
log "Creating tenant namespaces and quotas"
kubectl create ns tenant-a >/dev/null 2>&1 || true
kubectl create ns tenant-b >/dev/null 2>&1 || true

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rq-tenant-a
  namespace: tenant-a
spec:
  hard:
    requests.cpu: "750m"
    limits.cpu: "1500m"
    requests.memory: "512Mi"
    limits.memory: "1Gi"
    pods: "10"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rq-tenant-b
  namespace: tenant-b
spec:
  hard:
    requests.cpu: "750m"
    limits.cpu: "1500m"
    requests.memory: "512Mi"
    limits.memory: "1Gi"
    pods: "10"
YAML

# --- LiteLLM ---
log "Deploying LiteLLM to tenant-a / tenant-b"
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: tenant-a
spec:
  replicas: 1
  selector:
    matchLabels: {app: litellm}
  template:
    metadata:
      labels: {app: litellm}
    spec:
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main
        ports:
        - containerPort: 4000
        resources:
          requests: {cpu: "100m", memory: "128Mi"}
          limits:   {cpu: "300m", memory: "512Mi"}
        env:
        - name: LITELLM_LOG
          value: "INFO"
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: tenant-a
spec:
  selector: {app: litellm}
  ports:
  - name: http
    port: 4000
    targetPort: 4000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: tenant-b
spec:
  replicas: 1
  selector:
    matchLabels: {app: litellm}
  template:
    metadata:
      labels: {app: litellm}
    spec:
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main
        ports:
        - containerPort: 4000
        resources:
          requests: {cpu: "100m", memory: "128Mi"}
          limits:   {cpu: "300m", memory: "512Mi"}
        env:
        - name: LITELLM_LOG
          value: "INFO"
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: tenant-b
spec:
  selector: {app: litellm}
  ports:
  - name: http
    port: 4000
    targetPort: 4000
YAML

kubectl -n tenant-a rollout status deploy/litellm --timeout=300s || true
kubectl -n tenant-b rollout status deploy/litellm --timeout=300s || true

# --- Kong key-auth + ingress routing ---
log "Configuring Kong key-auth + routing"
cat <<'YAML' | kubectl apply -f -
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: key-auth
  namespace: kong
plugin: key-auth
config:
  key_names:
  - apikey
  hide_credentials: false
---
apiVersion: v1
kind: Secret
metadata:
  name: tenant-a-user1-key
  namespace: kong
type: Opaque
stringData:
  key: tenant-a-user1-123456
---
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: tenant-a-user1
  namespace: kong
username: tenant-a-user1
credentials:
- tenant-a-user1-key
---
apiVersion: v1
kind: Secret
metadata:
  name: tenant-b-user1-key
  namespace: kong
type: Opaque
stringData:
  key: tenant-b-user1-123456
---
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: tenant-b-user1
  namespace: kong
username: tenant-b-user1
credentials:
- tenant-b-user1-key
YAML

cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm
  namespace: tenant-a
  annotations:
    kubernetes.io/ingress.class: kong
    konghq.com/plugins: key-auth
spec:
  rules:
  - host: a.litellm.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: litellm
            port:
              number: 4000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm
  namespace: tenant-b
  annotations:
    kubernetes.io/ingress.class: kong
    konghq.com/plugins: key-auth
spec:
  rules:
  - host: b.litellm.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: litellm
            port:
              number: 4000
YAML

log "Port-forward 127.0.0.1:18080 -> svc/kong-kong-proxy:80"
pkill -f "kubectl.*port-forward.*18080:" >/dev/null 2>&1 || true
nohup kubectl -n kong port-forward svc/kong-kong-proxy 18080:80 --address 127.0.0.1 > "${RUN_DIR}/kong-portforward-18080.log" 2>&1 &
sleep 2

log "Smoke test"
set +e
curl -i -m 5 -H 'Host: a.litellm.local' http://127.0.0.1:18080/ | head -n 20
curl -i -m 5 -H 'Host: a.litellm.local' -H 'apikey: tenant-a-user1-123456' http://127.0.0.1:18080/health | head -n 40
curl -i -m 5 -H 'Host: b.litellm.local' -H 'apikey: tenant-b-user1-123456' http://127.0.0.1:18080/health | head -n 40
set -e

log "Done."
