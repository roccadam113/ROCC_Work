#!/usr/bin/env bash
set -euo pipefail

OLD_NAME="ai-task1"
NEW_NAME="task1"
K8S_VERSION_IMAGE="kindest/node:v1.35.0"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

log "Current kind clusters:"
kind get clusters || true

log "About to delete kind cluster: ${OLD_NAME}"
kind delete cluster --name "${OLD_NAME}"

log "Create kind cluster: ${NEW_NAME}"
cat > "kind-${NEW_NAME}.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: ${K8S_VERSION_IMAGE}
- role: worker
  image: ${K8S_VERSION_IMAGE}
- role: worker
  image: ${K8S_VERSION_IMAGE}
EOF

kind create cluster --name "${NEW_NAME}" --config "kind-${NEW_NAME}.yaml"

log "Waiting for nodes Ready"
kubectl config use-context "kind-${NEW_NAME}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s

log "Nodes:"
kubectl get nodes -o wide

log "Docker containers (kind nodes):"
docker ps --format 'table {{.Names}}\t{{.Image}}' | grep -E "${NEW_NAME}-(control-plane|worker)" || true

log "Done. Next step: re-apply your manifests/helm installs for cilium/kong/monitoring/tenants."
log "You previously dumped: all.dump.txt, ingress.dump.txt (note: those dumps are not guaranteed re-applicable)."
