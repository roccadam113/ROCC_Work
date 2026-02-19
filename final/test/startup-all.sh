#!/usr/bin/env bash
set -euo pipefail

# =============================
# Output folder in RUN_DIR
# =============================
RUN_DIR="$(pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${RUN_DIR}/task1-artifacts-${TS}"
mkdir -p "${OUT_DIR}"

RUN_LOG_FILE="${OUT_DIR}/run.log"
exec > >(tee -a "${RUN_LOG_FILE}") 2>&1

log()  { printf -- '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf -- '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf -- '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

log "OUT_DIR=${OUT_DIR}"
log "RUN_LOG_FILE=${RUN_LOG_FILE}"

# =============================
# Config (align with your cluster)
# =============================
KONG_LPORT="28080"
WEBHOOK_LPORT="28083"
GPU_LPORT="28084"

NS_KONG="kong"
NS_MON="monitoring"
NS_TA="tenant-a"
NS_TB="tenant-b"

KONG_PROXY_SVC="kong-kong-proxy"
WEBHOOK_SVC="kong-throttle-webhook"
GPU_SVC="fake-gpu-metrics"

TA_RL_PLUGIN="rl-5rps"

HOST_TA="a.litellm.local"
HOST_TB="b.litellm.local"
KEY_TA="tenant-a-user1-123456"
KEY_TB="tenant-b-user1-123456"

LOW_UTIL="0"
HIGH_UTIL="5"

# =============================
# Common dumps
# =============================
dump_cluster_state() {
  log "Dump cluster state"
  kubectl get nodes -o wide > "${OUT_DIR}/nodes.txt" 2>&1 || true
  kubectl get pods -A -o wide > "${OUT_DIR}/pods-all.txt" 2>&1 || true
  kubectl get svc -A -o wide > "${OUT_DIR}/svc-all.txt" 2>&1 || true
  kubectl get ingress -A -o wide > "${OUT_DIR}/ingress-all.txt" 2>&1 || true
  kubectl -n "${NS_TA}" get kongplugin -o wide > "${OUT_DIR}/tenant-a-kongplugin.txt" 2>&1 || true
  kubectl -n "${NS_TB}" get kongplugin -o wide > "${OUT_DIR}/tenant-b-kongplugin.txt" 2>&1 || true
}

dump_kong_upstream_debug() {
  log "Dump Kong/LiteLLM debug info"
  kubectl -n "${NS_KONG}" get pod -o wide > "${OUT_DIR}/kong-pods.txt" 2>&1 || true
  kubectl -n "${NS_KONG}" logs deploy/kong-kong -c proxy --tail=300 > "${OUT_DIR}/kong-proxy-logs.txt" 2>&1 || true
  kubectl -n "${NS_KONG}" logs deploy/kong-kong -c ingress-controller --tail=300 > "${OUT_DIR}/kong-ingress-controller-logs.txt" 2>&1 || true

  kubectl -n "${NS_TA}" get pod,svc,endpoints -o wide > "${OUT_DIR}/tenant-a-obj.txt" 2>&1 || true
  kubectl -n "${NS_TB}" get pod,svc,endpoints -o wide > "${OUT_DIR}/tenant-b-obj.txt" 2>&1 || true
  kubectl -n "${NS_TA}" logs deploy/litellm --tail=300 > "${OUT_DIR}/tenant-a-litellm-logs.txt" 2>&1 || true
  kubectl -n "${NS_TB}" logs deploy/litellm --tail=300 > "${OUT_DIR}/tenant-b-litellm-logs.txt" 2>&1 || true
}

dump_problem_pods() {
  kubectl get pods -A -o wide | egrep -i 'crash|error|pending|evict|imagepull|backoff' \
    > "${OUT_DIR}/pods-problems.txt" 2>&1 || true
}

dump_listening_ports() {
  if have ss; then
    ss -ltnp > "${OUT_DIR}/listening-ports-ss.txt" 2>&1 || true
  fi
}

# =============================
# Wait / ensure
# =============================
wait_k8s_ready() {
  log "Waiting for Kubernetes API"
  local ok="false"
  for _ in $(seq 1 60); do
    if kubectl cluster-info --request-timeout=3s >/dev/null 2>&1; then
      ok="true"
      break
    fi
    sleep 2
  done
  [[ "${ok}" == "true" ]] || { dump_cluster_state; die "Kubernetes API not reachable"; }

  log "Waiting for nodes Ready"
  for _ in $(seq 1 90); do
    if kubectl get nodes >/dev/null 2>&1; then
      if kubectl get nodes 2>/dev/null | awk 'NR>1 {print $2}' | grep -vq 'Ready'; then
        sleep 2; continue
      fi
      return 0
    fi
    sleep 2
  done

  dump_cluster_state
  die "Nodes not Ready in time. See ${OUT_DIR}"
}

ensure_deploy_replicas_ge_1() {
  local ns="$1"
  local deploy="$2"

  if ! kubectl -n "${ns}" get deploy "${deploy}" >/dev/null 2>&1; then
    warn "deploy/${deploy} not found in ns=${ns} (skip)"
    return 0
  fi

  local cur
  cur="$(kubectl -n "${ns}" get deploy "${deploy}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")"
  if [[ "${cur}" == "0" ]]; then
    log "Scale ns=${ns} deploy/${deploy} replicas 0 -> 1"
    kubectl -n "${ns}" scale deploy "${deploy}" --replicas=1 >/dev/null
  fi
}

rollout_restart_ns() {
  local ns="$1"
  if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
    warn "Namespace ${ns} not found. Skip restart."
    return 0
  fi

  log "Restart in ns=${ns}"
  kubectl -n "${ns}" rollout restart deploy >/dev/null 2>&1 || true
  kubectl -n "${ns}" rollout restart statefulset >/dev/null 2>&1 || true
  kubectl -n "${ns}" rollout restart daemonset >/dev/null 2>&1 || true

  kubectl -n "${ns}" get deploy -o name 2>/dev/null | while read -r d; do
    [[ -z "${d}" ]] && continue
    kubectl -n "${ns}" rollout status "${d}" --timeout=240s || true
  done
}

wait_pods_ready() {
  local ns="$1"
  local selector="$2"
  local timeout="${3:-240s}"

  log "Wait pods Ready ns=${ns} selector=${selector}"
  if ! kubectl -n "${ns}" wait --for=condition=Ready pod -l "${selector}" --timeout="${timeout}" >/dev/null 2>&1; then
    warn "Pods not ready ns=${ns} selector=${selector}"
    kubectl -n "${ns}" get pod -l "${selector}" -o wide > "${OUT_DIR}/${ns}-${selector//[^a-zA-Z0-9]/_}-pods.txt" 2>&1 || true
    return 1
  fi
  return 0
}

# =============================
# Port-forward (logs to OUT_DIR)
# =============================
wait_local_port_http() {
  local name="$1"
  local url="$2"
  local tries="${3:-30}"
  local sleep_s="${4:-2}"

  log "Wait local HTTP: ${name} url=${url}"
  for i in $(seq 1 "${tries}"); do
    if curl -sS -m 2 "${url}" >/dev/null 2>&1; then
      log "OK: ${name} local HTTP reachable on attempt ${i}"
      return 0
    fi
    sleep "${sleep_s}"
  done
  warn "Timeout waiting local HTTP: ${name} url=${url}"
  return 1
}

ensure_port_forward() {
  local ns="$1"
  local target="$2"   # svc/<name> or pod/<name>
  local mapping="$3"
  local pf_log="$4"
  local grep_pat="$5"

  set +m 2>/dev/null || true

  pkill -f "${grep_pat}" >/dev/null 2>&1 || true
  sleep 1

  if ! kubectl -n "${ns}" get "${target}" >/dev/null 2>&1; then
    warn "${target} not found in ns=${ns}"
    return 1
  fi

  log "Port-forward ns=${ns} ${target} ${mapping} (log=${pf_log})"
  nohup kubectl -n "${ns}" port-forward "${target}" "${mapping}" --address 127.0.0.1 > "${pf_log}" 2>&1 &
  disown || true
  sleep 2

  if have ss && ss -ltn | grep -q ":${mapping%%:*}\b"; then
    log "Listening OK on :${mapping%%:*}"
    return 0
  fi

  warn "Port-forward may have failed. See ${pf_log}"
  return 1
}

# 找出 kong-kong-proxy service 後面的其中一個 endpoint pod，固定打同一個 Kong Pod
pick_kong_proxy_pod() {
  kubectl -n "${NS_KONG}" get endpoints "${KONG_PROXY_SVC}" \
    -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null || true
}

pf_kong() {
  local pod
  pod="$(pick_kong_proxy_pod)"
  if [[ -n "${pod}" ]]; then
    ensure_port_forward "${NS_KONG}" "pod/${pod}" "${KONG_LPORT}:8000" "${OUT_DIR}/pf-kong.log" "kubectl.*port-forward.*${KONG_LPORT}:" || true
  else
    warn "Cannot find endpoint pod for svc/${KONG_PROXY_SVC}. Fallback to service port-forward."
    ensure_port_forward "${NS_KONG}" "svc/${KONG_PROXY_SVC}" "${KONG_LPORT}:80" "${OUT_DIR}/pf-kong.log" "kubectl.*port-forward.*${KONG_LPORT}:" || true
  fi
}

pf_webhook() { ensure_port_forward "${NS_MON}" "svc/${WEBHOOK_SVC}" "${WEBHOOK_LPORT}:8080" "${OUT_DIR}/pf-webhook.log" "kubectl.*port-forward.*${WEBHOOK_LPORT}:"; }
pf_gpu()     { ensure_port_forward "${NS_MON}" "svc/${GPU_SVC}"     "${GPU_LPORT}:8080"     "${OUT_DIR}/pf-gpu.log"     "kubectl.*port-forward.*${GPU_LPORT}:"; }

# =============================
# Task verification
# =============================
wait_http_200() {
  local name="$1"
  local cmd="$2"
  local tries="${3:-60}"
  local sleep_s="${4:-2}"

  log "Wait HTTP 200: ${name} (tries=${tries}, sleep=${sleep_s}s)"
  local i out
  : > "${OUT_DIR}/wait-${name}-history.txt" || true

  for i in $(seq 1 "${tries}"); do
    set +e
    out="$(bash -lc "${cmd}" 2>&1)"
    set -e

    printf -- '--- attempt %s ---\n%s\n' "${i}" "${out}" >> "${OUT_DIR}/wait-${name}-history.txt" || true
    printf -- '%s\n' "${out}" | sed -n '1,160p' > "${OUT_DIR}/wait-${name}-last.txt" || true

    if echo "${out}" | grep -qE 'HTTP/1\.[01] 200|^200$'; then
      log "OK: ${name} became HTTP 200 on attempt ${i}"
      return 0
    fi

    sleep "${sleep_s}"
  done

  warn "Timeout waiting for HTTP 200: ${name}. See ${OUT_DIR}/wait-${name}-last.txt"
  return 1
}

curl_kong_health() {
  local host="$1"
  local key="$2"
  curl -sS -m 8 -i \
    -H "Host: ${host}" \
    -H "apikey: ${key}" \
    "http://127.0.0.1:${KONG_LPORT}/health"
}

curl_models_code() {
  local host="$1"
  local key="$2"
  curl -sS -m 8 -o /dev/null -w '%{http_code}\n' \
    -H "Host: ${host}" \
    -H "apikey: ${key}" \
    "http://127.0.0.1:${KONG_LPORT}/v1/models"
}

webhook_decide() {
  curl -sS -m 10 -i \
    -H 'Content-Type: application/json' \
    -d '{"tenant":"tenant-a"}' \
    "http://127.0.0.1:${WEBHOOK_LPORT}/decide"
}

gpu_set_util() {
  local util="$1"
  curl -sS -m 8 "http://127.0.0.1:${GPU_LPORT}/set?util=${util}"
}

gpu_get_util() {
  curl -sS -m 8 "http://127.0.0.1:${GPU_LPORT}/gpu_util"
}

get_rl_disabled() {
  kubectl -n "${NS_TA}" get kongplugin "${TA_RL_PLUGIN}" -o jsonpath='{.disabled}' 2>/dev/null || echo ""
}

sync_to_next_second() {
  local s
  s="$(date +%s)"
  while [[ "$(date +%s)" == "${s}" ]]; do
    :
  done
}

verify_end_to_end() {
  log "=== Verify start (task requirement proof) ==="

  local cmd_health_ta cmd_health_tb cmd_models_ta
  cmd_health_ta="curl -sS -m 6 -i -H 'Host: ${HOST_TA}' -H 'apikey: ${KEY_TA}' http://127.0.0.1:${KONG_LPORT}/health"
  cmd_health_tb="curl -sS -m 6 -i -H 'Host: ${HOST_TB}' -H 'apikey: ${KEY_TB}' http://127.0.0.1:${KONG_LPORT}/health"
  cmd_models_ta="curl -sS -m 6 -o /dev/null -w '%{http_code}\n' -H 'Host: ${HOST_TA}' -H 'apikey: ${KEY_TA}' http://127.0.0.1:${KONG_LPORT}/v1/models"

  wait_http_200 "kong-health-tenant-a" "${cmd_health_ta}" 60 2 || { dump_kong_upstream_debug; die "tenant-a /health not ready (still not 200)"; }
  wait_http_200 "kong-health-tenant-b" "${cmd_health_tb}" 60 2 || { dump_kong_upstream_debug; die "tenant-b /health not ready (still not 200)"; }
  wait_http_200 "kong-models-tenant-a" "${cmd_models_ta}" 60 2 || { dump_kong_upstream_debug; die "tenant-a /v1/models not ready (still not 200)"; }

  log "[A] Health checks"
  curl_kong_health "${HOST_TA}" "${KEY_TA}" | tee "${OUT_DIR}/health-tenant-a.txt"
  curl_kong_health "${HOST_TB}" "${KEY_TB}" | tee "${OUT_DIR}/health-tenant-b.txt"
  gpu_get_util | tee "${OUT_DIR}/gpu-util-before.txt"

  log "[B] LOW util -> expect rl disabled=true -> no 429"
  gpu_set_util "${LOW_UTIL}" | tee "${OUT_DIR}/gpu-set-low.txt"
  gpu_get_util | tee "${OUT_DIR}/gpu-util-low.txt"
  webhook_decide | tee "${OUT_DIR}/decide-low.txt"
  printf -- 'rl_disabled=%s\n' "$(get_rl_disabled)" | tee "${OUT_DIR}/rl-disabled-low.txt"

  for i in $(seq 1 10); do
    curl_models_code "${HOST_TA}" "${KEY_TA}"
  done | tee "${OUT_DIR}/models-10-low.txt"

  log "[C] HIGH util -> expect rl disabled=false -> see 429"
  gpu_set_util "${HIGH_UTIL}" | tee "${OUT_DIR}/gpu-set-high.txt"
  gpu_get_util | tee "${OUT_DIR}/gpu-util-high.txt"
  webhook_decide | tee "${OUT_DIR}/decide-high.txt"
  printf -- 'rl_disabled=%s\n' "$(get_rl_disabled)" | tee "${OUT_DIR}/rl-disabled-high.txt"

  sync_to_next_second

  # 50 併發
  seq 1 50 | xargs -n1 -P50 bash -lc \
    "curl -sS -m 8 -o /dev/null -w '%{http_code}\n' \
      -H 'Host: ${HOST_TA}' \
      -H 'apikey: ${KEY_TA}' \
      http://127.0.0.1:${KONG_LPORT}/v1/models" \
    | tee "${OUT_DIR}/models-50-high.txt"

  log "=== Verify end ==="
}

# =============================
# Main
# =============================
main() {
  log "=== Startup begin ==="
  wait_k8s_ready

  dump_cluster_state

  ensure_deploy_replicas_ge_1 "${NS_KONG}" "kong-kong"
  ensure_deploy_replicas_ge_1 "${NS_MON}"  "fake-gpu-metrics"
  ensure_deploy_replicas_ge_1 "${NS_MON}"  "kong-throttle-webhook"
  ensure_deploy_replicas_ge_1 "${NS_MON}"  "tenant-api"
  ensure_deploy_replicas_ge_1 "${NS_TA}"   "fake-llm"
  ensure_deploy_replicas_ge_1 "${NS_TA}"   "litellm"
  ensure_deploy_replicas_ge_1 "${NS_TB}"   "litellm"

  rollout_restart_ns "${NS_KONG}"
  rollout_restart_ns "${NS_MON}"
  rollout_restart_ns "${NS_TA}"
  rollout_restart_ns "${NS_TB}"

  wait_pods_ready "${NS_MON}" "app=fake-gpu-metrics" 240s || true
  wait_pods_ready "${NS_MON}" "app=kong-throttle-webhook" 240s || true
  wait_pods_ready "${NS_TA}"  "app=fake-llm" 240s || true
  wait_pods_ready "${NS_TA}"  "app=litellm" 240s || true
  wait_pods_ready "${NS_TB}"  "app=litellm" 240s || true

  pf_kong
  pf_webhook || true
  pf_gpu     || true

  wait_local_port_http "webhook" "http://127.0.0.1:${WEBHOOK_LPORT}/healthz" 30 2 || true
  wait_local_port_http "gpu"     "http://127.0.0.1:${GPU_LPORT}/healthz"     30 2 || true

  dump_listening_ports
  dump_problem_pods

  verify_end_to_end

  {
    echo "OUT_DIR=${OUT_DIR}"
    echo "Kong:    http://127.0.0.1:${KONG_LPORT}"
    echo "Webhook: http://127.0.0.1:${WEBHOOK_LPORT}"
    echo "GPU:     http://127.0.0.1:${GPU_LPORT}"
  } | tee "${OUT_DIR}/endpoints.txt"

  log "=== Startup end ==="
  log "Artifacts saved: ${OUT_DIR}"
}

main "$@"
