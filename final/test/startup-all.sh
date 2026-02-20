#!/usr/bin/env bash
set -euo pipefail

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

# 避免背景工作印出「[1] 12345」「已完成」污染輸出
set +m 2>/dev/null || true

log "OUT_DIR=${OUT_DIR}"
log "RUN_LOG_FILE=${RUN_LOG_FILE}"

# =============================
# Namespaces / services
# =============================
NS_KONG="kong"
NS_MON="monitoring"
NS_TA="tenant-a"
NS_TB="tenant-b"

KONG_PROXY_SVC="kong-kong-proxy"
WEBHOOK_SVC="kong-throttle-webhook"
GPU_SVC="fake-gpu-metrics"
TENANT_API_SVC="tenant-api"

# 你 webhook 會 patch 的 KongPlugin 名稱（tenant-a）
TA_RL_PLUGIN="rl-5rps"

HOST_TA="a.litellm.local"
HOST_TB="b.litellm.local"
KEY_TA="tenant-a-user1-123456"
KEY_TB="tenant-b-user1-123456"

# Local port bases
KONG_LPORT_BASE="${KONG_LPORT_BASE:-18080}"
WEBHOOK_LPORT_BASE="${WEBHOOK_LPORT_BASE:-18083}"
GPU_LPORT_BASE="${GPU_LPORT_BASE:-18084}"
TENANT_API_LPORT_BASE="${TENANT_API_LPORT_BASE:-18085}"

LOW_UTIL="${LOW_UTIL:-0}"
HIGH_UTIL="${HIGH_UTIL:-70}"

DO_RESTART="${DO_RESTART:-0}"

PF_DIR="${RUN_DIR}/.pf-guards"
mkdir -p "${PF_DIR}"

# fake-gpu-metrics 的 label（你貼的 metrics 已證實固定 default/default）
GPU_METRICS_TENANT_LABEL="${GPU_METRICS_TENANT_LABEL:-default}"
GPU_METRICS_KEY_LABEL="${GPU_METRICS_KEY_LABEL:-default}"

# HIGH burst 參數
HIGH_BURST_N="${HIGH_BURST_N:-200}"
# 是否強制 HIGH 一定要看到 429（交付證據）
REQUIRE_429_ON_HIGH="${REQUIRE_429_ON_HIGH:-0}"

# 等待 Kong 設定收斂
LOW_CONVERGE_TRIES="${LOW_CONVERGE_TRIES:-30}"   # 每次 sleep 1
HIGH_CONVERGE_TRIES="${HIGH_CONVERGE_TRIES:-20}" # 每次 sleep 1

# 重要：burst 時 curl 容易超時，提供可調參數並把錯誤導到檔案
BURST_CURL_MAX_TIME="${BURST_CURL_MAX_TIME:-12}"              # 秒
BURST_CURL_CONNECT_TIMEOUT="${BURST_CURL_CONNECT_TIMEOUT:-2}" # 秒
BURST_PARALLELISM="${BURST_PARALLELISM:-50}"                  # xargs -P

# =============================
# Dumps
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

dump_kong_focus() {
  log "Dump Kong focus"
  kubectl -n "${NS_KONG}" get pod,svc,endpoints -o wide > "${OUT_DIR}/kong-obj.txt" 2>&1 || true
  kubectl -n "${NS_KONG}" logs deploy/kong-kong -c proxy --tail=250 > "${OUT_DIR}/kong-proxy-logs.txt" 2>&1 || true
  kubectl -n "${NS_KONG}" logs deploy/kong-kong -c ingress-controller --tail=250 > "${OUT_DIR}/kong-ic-logs.txt" 2>&1 || true
}

dump_webhook_focus() {
  log "Dump webhook focus"
  kubectl -n "${NS_MON}" get pod -l app=kong-throttle-webhook -o wide > "${OUT_DIR}/webhook-pods.txt" 2>&1 || true
  kubectl -n "${NS_MON}" logs deploy/kong-throttle-webhook --tail=250 > "${OUT_DIR}/webhook-logs.txt" 2>&1 || true
}

dump_tenant_focus() {
  log "Dump tenants focus"
  kubectl -n "${NS_TA}" get pod,svc,endpoints,ingress -o wide > "${OUT_DIR}/tenant-a-obj.txt" 2>&1 || true
  kubectl -n "${NS_TB}" get pod,svc,endpoints,ingress -o wide > "${OUT_DIR}/tenant-b-obj.txt" 2>&1 || true
  kubectl -n "${NS_TA}" logs deploy/litellm --tail=200 > "${OUT_DIR}/tenant-a-litellm-logs.txt" 2>&1 || true
  kubectl -n "${NS_TB}" logs deploy/litellm --tail=200 > "${OUT_DIR}/tenant-b-litellm-logs.txt" 2>&1 || true
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
# Cluster readiness
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
        sleep 2
        continue
      fi
      return 0
    fi
    sleep 2
  done

  dump_cluster_state
  die "Nodes not Ready in time"
}

ensure_deploy_replicas_ge_1() {
  local ns="$1" deploy="$2"

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
  kubectl get ns "${ns}" >/dev/null 2>&1 || { warn "ns=${ns} not found"; return 0; }

  log "Rollout restart ns=${ns}"
  kubectl -n "${ns}" rollout restart deploy >/dev/null 2>&1 || true
  kubectl -n "${ns}" get deploy -o name 2>/dev/null | while read -r d; do
    [[ -z "${d}" ]] && continue
    kubectl -n "${ns}" rollout status "${d}" --timeout=240s || true
  done
}

wait_pods_ready() {
  local ns="$1" selector="$2" timeout="${3:-240s}"

  log "Wait pods Ready ns=${ns} selector=${selector}"
  if ! kubectl -n "${ns}" wait --for=condition=Ready pod -l "${selector}" --timeout="${timeout}" >/dev/null 2>&1; then
    warn "Pods not ready ns=${ns} selector=${selector}"
    kubectl -n "${ns}" get pod -l "${selector}" -o wide > "${OUT_DIR}/${ns}-${selector//[^a-zA-Z0-9]/_}-pods.txt" 2>&1 || true
    return 1
  fi
  return 0
}

# =============================
# Port discovery
# =============================
svc_exists() {
  local ns="$1" svc="$2"
  kubectl -n "${ns}" get svc "${svc}" >/dev/null 2>&1
}

get_svc_port() {
  local ns="$1" svc="$2"
  local prefer_name="${3:-}"
  local prefer_number="${4:-}"

  svc_exists "${ns}" "${svc}" || { echo ""; return 0; }

  local lines
  lines="$(kubectl -n "${ns}" get svc "${svc}" -o jsonpath='{range .spec.ports[*]}{.name}{"|"}{.port}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -n "${prefer_name}" ]]; then
    local p
    p="$(printf '%s' "${lines}" | awk -F'|' -v n="${prefer_name}" '$1==n {print $2; exit}')"
    [[ -n "${p}" ]] && { echo "${p}"; return 0; }
  fi

  if [[ -n "${prefer_number}" ]]; then
    local p2
    p2="$(printf '%s' "${lines}" | awk -F'|' -v n="${prefer_number}" '$2==n {print $2; exit}')"
    [[ -n "${p2}" ]] && { echo "${p2}"; return 0; }
  fi

  printf '%s' "${lines}" | head -n 1 | awk -F'|' '{print $2}'
}

# =============================
# Self-heal port-forward guard
# =============================
is_listening() {
  local port="$1"
  if have ss; then
    ss -ltn 2>/dev/null | awk -v p=":${port}" '$1=="LISTEN" && $4 ~ p"$" {found=1} END{exit(found?0:1)}'
    return $?
  fi
  if have lsof; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  return 1
}

pick_free_port() {
  local base="$1"
  local p="${base}"
  for _ in $(seq 1 200); do
    if ! is_listening "${p}"; then
      echo "${p}"
      return 0
    fi
    p=$((p+1))
  done
  return 1
}

kill_kubectl_pf_on_port() {
  local port="$1"
  have lsof || return 0
  local pids
  pids="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $1=="kubectl" {print $2}' | sort -u || true)"
  if [[ -n "${pids}" ]]; then
    warn "Kill kubectl port-forward on :${port} PID(s)=${pids}"
    # shellcheck disable=SC2086
    kill ${pids} >/dev/null 2>&1 || true
    sleep 1
  fi
}

wait_local_listen() {
  local port="$1"
  local tries="${2:-60}"
  for _ in $(seq 1 "${tries}"); do
    if is_listening "${port}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_local_http_ok() {
  local url="$1"
  local tries="${2:-60}"
  for _ in $(seq 1 "${tries}"); do
    if curl -sS -m 2 "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

pick_kong_proxy_pod() {
  kubectl -n "${NS_KONG}" get pod -l app=kong-kong -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

start_pf_guard() {
  local name="$1" ns="$2" target="$3" rport="$4" lport_base="$5" health_url_tpl="${6:-}"

  if [[ -z "${rport}" ]]; then
    warn "${name}: rport empty, skip"
    echo ""
    return 0
  fi

  if ! kubectl -n "${ns}" get "${target}" >/dev/null 2>&1; then
    warn "${name}: ${target} not found in ns=${ns}, skip"
    echo ""
    return 0
  fi

  local lport
  lport="$(pick_free_port "${lport_base}")" || die "${name}: cannot pick free port"

  if is_listening "${lport}"; then
    kill_kubectl_pf_on_port "${lport}"
  fi

  local pidfile="${PF_DIR}/pf-${name}.pid"
  local logfile="${OUT_DIR}/pf-${name}.log"

  if [[ -f "${pidfile}" ]]; then
    local oldpid
    oldpid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -n "${oldpid}" ]] && kill -0 "${oldpid}" >/dev/null 2>&1; then
      kill "${oldpid}" >/dev/null 2>&1 || true
      sleep 1
    fi
    rm -f "${pidfile}" >/dev/null 2>&1 || true
  fi

  local hu=""
  if [[ -n "${health_url_tpl}" ]]; then
    hu="${health_url_tpl/__LP__/${lport}}"
  fi

  nohup bash -lc "
set -euo pipefail
ts(){ date '+%F %T'; }
ns='${ns}'; target='${target}'; lport='${lport}'; rport='${rport}'; hu='${hu}'; logfile='${logfile}'; name='${name}';

is_listen() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p=\":\${lport}\" '\$1==\"LISTEN\" && \$4 ~ p\"$\" {found=1} END{exit(found?0:1)}'
    return \$?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:\"\${lport}\" -sTCP:LISTEN >/dev/null 2>&1
    return \$?
  fi
  return 1
}

start_pf() {
  printf '[%s] start kubectl -n %s port-forward %s %s:%s\n' \"\$(ts)\" \"\${ns}\" \"\${target}\" \"\${lport}\" \"\${rport}\" >> \"\${logfile}\"
  nohup kubectl -n \"\${ns}\" port-forward \"\${target}\" \"\${lport}:\${rport}\" --address 127.0.0.1 >> \"\${logfile}\" 2>&1 &
  echo \$! > \"/tmp/pf-\${name}-\${lport}.pid\"
  sleep 1
}

stop_pf() {
  if [[ -f \"/tmp/pf-\${name}-\${lport}.pid\" ]]; then
    pfpid=\"\$(cat \"/tmp/pf-\${name}-\${lport}.pid\" 2>/dev/null || true)\"
    if [[ -n \"\${pfpid}\" ]] && kill -0 \"\${pfpid}\" >/dev/null 2>&1; then
      kill \"\${pfpid}\" >/dev/null 2>&1 || true
    fi
    rm -f \"/tmp/pf-\${name}-\${lport}.pid\" >/dev/null 2>&1 || true
  fi
}

check_ok() {
  if [[ -z \"\${hu}\" ]]; then
    is_listen
    return \$?
  fi
  curl -sS -m 2 \"\${hu}\" >/dev/null 2>&1
}

start_pf

while true; do
  if ! check_ok; then
    printf '[%s] health/listen failed -> restart\n' \"\$(ts)\" >> \"\${logfile}\"
    stop_pf
    start_pf
  fi
  sleep 2
done
" >/dev/null 2>&1 &

  echo $! > "${pidfile}"

  if ! wait_local_listen "${lport}" 60; then
    warn "${name}: port-forward did not listen in time (port=${lport}), see ${logfile}"
  fi

  echo "${lport}"
}

start_kong_pf() {
  local _svc_port="$1"
  local pod
  pod="$(pick_kong_proxy_pod)"
  if [[ -z "${pod}" ]]; then
    warn "Cannot find kong proxy pod; fallback to svc port-forward"
    start_pf_guard "kong" "${NS_KONG}" "svc/${KONG_PROXY_SVC}" "${_svc_port}" "${KONG_LPORT_BASE}" ""
    return 0
  fi
  start_pf_guard "kong" "${NS_KONG}" "pod/${pod}" "8000" "${KONG_LPORT_BASE}" ""
}

# =============================
# Verify helpers
# =============================
wait_http_200() {
  local name="$1" cmd="$2" tries="${3:-100}" sleep_s="${4:-2}"
  log "Wait HTTP 200: ${name}"
  local i out
  : > "${OUT_DIR}/wait-${name}-history.txt" || true
  for i in $(seq 1 "${tries}"); do
    set +e
    out="$(bash -lc "${cmd}" 2>&1)"
    set -e
    printf -- '--- attempt %s ---\n%s\n' "${i}" "${out}" >> "${OUT_DIR}/wait-${name}-history.txt" || true
    if echo "${out}" | grep -qE 'HTTP/1\.[01] 200|^200$'; then
      log "OK: ${name} became HTTP 200 on attempt ${i}"
      return 0
    fi
    sleep "${sleep_s}"
  done
  warn "Timeout waiting for HTTP 200: ${name}"
  return 1
}

sync_to_next_second() {
  local s
  s="$(date +%s)"
  while [[ "$(date +%s)" == "${s}" ]]; do :; done
}

get_rl_disabled() {
  kubectl -n "${NS_TA}" get kongplugin "${TA_RL_PLUGIN}" -o jsonpath='{.disabled}' 2>/dev/null || echo ""
}

curl_models_code() {
  local lport="$1" host="$2" key="$3"
  curl -sS -m 8 -o /dev/null -w '%{http_code}\n' \
    -H "Host: ${host}" -H "apikey: ${key}" \
    "http://127.0.0.1:${lport}/v1/models"
}

curl_kong_health() {
  local lport="$1" host="$2" key="$3"
  curl -sS -m 8 -i -H "Host: ${host}" -H "apikey: ${key}" \
    "http://127.0.0.1:${lport}/health"
}

webhook_decide_raw() {
  local lport="$1"
  curl -sS -m 10 -i \
    -H 'Content-Type: application/json' \
    -d '{"tenant":"tenant-a"}' \
    "http://127.0.0.1:${lport}/decide"
}

gpu_set_util() {
  local lport="$1" util="$2"
  curl -sS -m 8 "http://127.0.0.1:${lport}/set?util=${util}"
}

gpu_get_util_from_metrics() {
  local lport="$1"
  local t="${GPU_METRICS_TENANT_LABEL}"
  local k="${GPU_METRICS_KEY_LABEL}"

  curl -sS -m 8 "http://127.0.0.1:${lport}/metrics" \
    | awk -v t="${t}" -v k="${k}" '
      $1 ~ /^fake_gpu_utilization_percent/ && $0 ~ "tenant=\""t"\"" && $0 ~ "api_key=\""k"\"" {
        print $2; found=1; exit
      }
      END { if (!found) exit 1 }
    '
}

parse_decide_util() {
  sed -n 's/.*"util":[[:space:]]*\([0-9]\+\(\.[0-9]\+\)\?\).*/\1/p' | head -n 1
}

# =============================
# FIXED burst: 不依賴父 shell function，xargs worker 直接跑 curl
# =============================
burst_models_codes() {
  local n="$1"
  local url="$2"
  local host="$3"
  local key="$4"
  local out_file="$5"

  local err_file="${out_file%.txt}-errors.txt"
  : > "${out_file}"
  : > "${err_file}"

  sync_to_next_second

  local P="${BURST_PARALLELISM:-50}"

  if have xargs; then
    # 用「參數」傳入 worker，避免環境變數在 pipeline 中遺失
    seq 1 "${n}" | xargs -P "${P}" -I{} bash -lc '
      URL="$1"; HOST="$2"; KEY="$3"; ERR="$4"; CONNECT_TO="$5"; MAX_TIME="$6"

      code="$(
        curl --http1.1 -sS \
          --connect-timeout "${CONNECT_TO}" \
          --max-time "${MAX_TIME}" \
          -o /dev/null -w "%{http_code}" \
          -H "Host: ${HOST}" \
          -H "apikey: ${KEY}" \
          "${URL}" 2>>"${ERR}"
      )"
      rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$code" ]; then
        echo 000
      else
        echo "$code"
      fi
    ' _ "${url}" "${host}" "${key}" "${err_file}" "${BURST_CURL_CONNECT_TIMEOUT}" "${BURST_CURL_MAX_TIME}" \
      >> "${out_file}"
  else
    # fallback：背景 subshell，但 stderr 一樣導到 err_file
    for _ in $(seq 1 "${n}"); do
      (
        set +e
        code="$(
          curl --http1.1 -sS \
            --connect-timeout "${BURST_CURL_CONNECT_TIMEOUT}" \
            --max-time "${BURST_CURL_MAX_TIME}" \
            -o /dev/null -w "%{http_code}" \
            -H "Host: ${host}" \
            -H "apikey: ${key}" \
            "${url}" 2>>"${err_file}"
        )"
        rc=$?
        set -e
        if [[ $rc -ne 0 || -z "${code}" ]]; then
          echo 000
        else
          echo "${code}"
        fi
      ) >> "${out_file}" &
    done
    wait || true
  fi

  local c200 c429 c000
  c200="$(grep -xc '200' "${out_file}" 2>/dev/null || true)"
  c429="$(grep -xc '429' "${out_file}" 2>/dev/null || true)"
  c000="$(grep -xc '000' "${out_file}" 2>/dev/null || true)"
  printf 'count_200=%s count_429=%s count_000=%s parallel=%s max_time=%ss\n' \
    "${c200:-0}" "${c429:-0}" "${c000:-0}" "${P}" "${BURST_CURL_MAX_TIME}"
}

# LOW 收斂判定：連續 10 次 models 都 200
low_converged() {
  local kong_port="$1"
  local tmp="${OUT_DIR}/_low-probe.txt"
  : > "${tmp}"
  for _ in $(seq 1 10); do
    curl_models_code "${kong_port}" "${HOST_TA}" "${KEY_TA}" >> "${tmp}"
  done
  local c429
  c429="$(grep -xc '429' "${tmp}" 2>/dev/null || true)"
  cp -f "${tmp}" "${OUT_DIR}/models-10-low-probe-latest.txt" >/dev/null 2>&1 || true
  [[ "${c429:-0}" == "0" ]]
}

high_converged() {
  local kong_port="$1"
  local out_file="$2"
  local sum
  sum="$(burst_models_codes "${HIGH_BURST_N}" \
    "http://127.0.0.1:${kong_port}/v1/models" \
    "${HOST_TA}" "${KEY_TA}" \
    "${out_file}"
  )"
  printf '%s\n' "${sum}"
  printf '%s' "${sum}" | grep -q 'count_429=[1-9]'
}

verify_end_to_end() {
  local KONG_LPORT="$1"
  local WEBHOOK_LPORT="$2"
  local GPU_LPORT="$3"

  log "=== Verify start ==="

  local cmd_health_ta
  cmd_health_ta="curl -sS -m 6 -i -H 'Host: ${HOST_TA}' -H 'apikey: ${KEY_TA}' http://127.0.0.1:${KONG_LPORT}/health"
  wait_http_200 "kong-health-tenant-a" "${cmd_health_ta}" 100 2 || {
    dump_kong_focus
    dump_tenant_focus
    die "tenant-a /health not ready"
  }

  log "[A] Health checks"
  curl_kong_health "${KONG_LPORT}" "${HOST_TA}" "${KEY_TA}" | tee "${OUT_DIR}/health-tenant-a.txt"
  curl_kong_health "${KONG_LPORT}" "${HOST_TB}" "${KEY_TB}" | tee "${OUT_DIR}/health-tenant-b.txt"

  log "GPU util (from /metrics) label tenant=${GPU_METRICS_TENANT_LABEL} api_key=${GPU_METRICS_KEY_LABEL}"
  (gpu_get_util_from_metrics "${GPU_LPORT}" || echo "N/A") | tee "${OUT_DIR}/gpu-util-before.txt"

  log "[B] LOW util -> expect rl disabled=true AND models mostly 200"
  gpu_set_util "${GPU_LPORT}" "${LOW_UTIL}" | tee "${OUT_DIR}/gpu-set-low.txt"

  local util_m decide_util_low
  util_m="$(gpu_get_util_from_metrics "${GPU_LPORT}" || true)"
  printf 'metrics_util=%s\n' "${util_m:-N/A}" | tee "${OUT_DIR}/gpu-util-low.txt"

  sleep 1

  webhook_decide_raw "${WEBHOOK_LPORT}" | tee "${OUT_DIR}/decide-low.txt" >/dev/null
  decide_util_low="$(sed -n '/^{/,$p' "${OUT_DIR}/decide-low.txt" | parse_decide_util || true)"
  printf 'decide_util=%s\n' "${decide_util_low:-N/A}" | tee "${OUT_DIR}/decide-low-util.txt"

  if [[ -n "${util_m}" ]] && [[ -n "${decide_util_low}" ]]; then
    if [[ "${decide_util_low%.*}" != "${util_m%.*}" ]]; then
      dump_webhook_focus
      die "LOW: decide util (${decide_util_low}) != metrics util (${util_m})"
    fi
  fi

  printf -- 'rl_disabled=%s\n' "$(get_rl_disabled)" | tee "${OUT_DIR}/rl-disabled-low.txt"

  local ok_low="false"
  for t in $(seq 1 "${LOW_CONVERGE_TRIES}"); do
    if low_converged "${KONG_LPORT}"; then
      ok_low="true"
      log "LOW converged on attempt ${t}: models x10 all 200"
      break
    fi
    warn "LOW not converged yet (still seeing 429). retry in 1s (attempt ${t}/${LOW_CONVERGE_TRIES})"
    sleep 1
  done

  cp -f "${OUT_DIR}/models-10-low-probe-latest.txt" "${OUT_DIR}/models-10-low.txt" >/dev/null 2>&1 || true

  if [[ "${ok_low}" != "true" ]]; then
    dump_kong_focus
    die "LOW: still seeing 429 after waiting ${LOW_CONVERGE_TRIES}s. Likely Kong plugins not actually disabled on dataplane (or another rate-limit plugin attached)."
  fi

  log "[C] HIGH util -> expect rl disabled=false AND see some 429 under burst"
  gpu_set_util "${GPU_LPORT}" "${HIGH_UTIL}" | tee "${OUT_DIR}/gpu-set-high.txt"
  util_m="$(gpu_get_util_from_metrics "${GPU_LPORT}" || true)"
  printf 'metrics_util=%s\n' "${util_m:-N/A}" | tee "${OUT_DIR}/gpu-util-high.txt"

  sleep 1

  webhook_decide_raw "${WEBHOOK_LPORT}" | tee "${OUT_DIR}/decide-high.txt" >/dev/null
  local decide_util_high
  decide_util_high="$(sed -n '/^{/,$p' "${OUT_DIR}/decide-high.txt" | parse_decide_util || true)"
  printf 'decide_util=%s\n' "${decide_util_high:-N/A}" | tee "${OUT_DIR}/decide-high-util.txt"

  if [[ -n "${util_m}" ]] && [[ -n "${decide_util_high}" ]]; then
    if [[ "${decide_util_high%.*}" != "${util_m%.*}" ]]; then
      dump_webhook_focus
      die "HIGH: decide util (${decide_util_high}) != metrics util (${util_m})"
    fi
  fi

  printf -- 'rl_disabled=%s\n' "$(get_rl_disabled)" | tee "${OUT_DIR}/rl-disabled-high.txt"

  local burst_out="${OUT_DIR}/models-burst-high.txt"
  local burst_sum
  burst_sum="$(burst_models_codes "${HIGH_BURST_N}" \
    "http://127.0.0.1:${KONG_LPORT}/v1/models" \
    "${HOST_TA}" "${KEY_TA}" \
    "${burst_out}"
  )"
  printf '%s\n' "${burst_sum}" | tee "${OUT_DIR}/models-burst-high-summary.txt"

  if [[ -f "${burst_out%.txt}-errors.txt" ]]; then
    cp -f "${burst_out%.txt}-errors.txt" "${OUT_DIR}/models-burst-high-errors.txt" >/dev/null 2>&1 || true
  fi

  if [[ "${REQUIRE_429_ON_HIGH}" == "1" ]]; then
    local ok_high="false"
    for t in $(seq 1 "${HIGH_CONVERGE_TRIES}"); do
      if high_converged "${KONG_LPORT}" "${burst_out}"; then
        ok_high="true"
        log "HIGH converged on attempt ${t}: burst shows some 429"
        break
      fi
      warn "HIGH not converged yet (no 429). retry in 1s (attempt ${t}/${HIGH_CONVERGE_TRIES})"
      sleep 1
    done

    if [[ "${ok_high}" != "true" ]]; then
      dump_kong_focus
      die "HIGH: expected some 429 under burst but still none after waiting ${HIGH_CONVERGE_TRIES}s. Either rate-limiting not attached/enforced, or burst not truly concurrent in this run."
    fi
  fi

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

  if [[ "${DO_RESTART}" == "1" ]]; then
    log "DO_RESTART=1, rollout restarts"
    rollout_restart_ns "${NS_KONG}"
    rollout_restart_ns "${NS_MON}"
    rollout_restart_ns "${NS_TA}"
    rollout_restart_ns "${NS_TB}"
  else
    log "DO_RESTART=0, skip rollout restarts"
  fi

  wait_pods_ready "${NS_MON}" "app=fake-gpu-metrics" 240s || true
  wait_pods_ready "${NS_MON}" "app=kong-throttle-webhook" 240s || true
  wait_pods_ready "${NS_TA}"  "app=litellm" 240s || true
  wait_pods_ready "${NS_TB}"  "app=litellm" 240s || true

  local kong_rport webhook_rport gpu_rport tenant_api_rport
  kong_rport="$(get_svc_port "${NS_KONG}" "${KONG_PROXY_SVC}" "proxy" "80")"
  webhook_rport="$(get_svc_port "${NS_MON}" "${WEBHOOK_SVC}" "" "8080")"
  gpu_rport="$(get_svc_port "${NS_MON}" "${GPU_SVC}" "" "8080")"
  tenant_api_rport="$(get_svc_port "${NS_MON}" "${TENANT_API_SVC}" "" "8080")"

  log "Discovered ports: kong=${kong_rport:-n/a} webhook=${webhook_rport:-n/a} gpu=${gpu_rport:-n/a} tenant-api=${tenant_api_rport:-n/a}"

  local KONG_LPORT WEBHOOK_LPORT GPU_LPORT TENANT_API_LPORT
  KONG_LPORT="$(start_kong_pf "${kong_rport}")"
  WEBHOOK_LPORT="$(start_pf_guard "webhook" "${NS_MON}" "svc/${WEBHOOK_SVC}" "${webhook_rport}" "${WEBHOOK_LPORT_BASE}" "http://127.0.0.1:__LP__/healthz")"
  GPU_LPORT="$(start_pf_guard "gpu" "${NS_MON}" "svc/${GPU_SVC}" "${gpu_rport}" "${GPU_LPORT_BASE}" "http://127.0.0.1:__LP__/healthz")"

  if [[ -n "${tenant_api_rport}" ]] && svc_exists "${NS_MON}" "${TENANT_API_SVC}"; then
    TENANT_API_LPORT="$(start_pf_guard "tenant-api" "${NS_MON}" "svc/${TENANT_API_SVC}" "${tenant_api_rport}" "${TENANT_API_LPORT_BASE}" "")"
  else
    TENANT_API_LPORT=""
  fi

  wait_local_http_ok "http://127.0.0.1:${WEBHOOK_LPORT}/healthz" 60 || warn "webhook healthz not ready yet (port=${WEBHOOK_LPORT})"
  wait_local_http_ok "http://127.0.0.1:${GPU_LPORT}/healthz" 60 || warn "gpu healthz not ready yet (port=${GPU_LPORT})"

  dump_listening_ports
  dump_problem_pods

  {
    echo "OUT_DIR=${OUT_DIR}"
    echo "Kong:        http://127.0.0.1:${KONG_LPORT}"
    echo "Webhook:     http://127.0.0.1:${WEBHOOK_LPORT}"
    echo "GPU Metrics: http://127.0.0.1:${GPU_LPORT}"
    if [[ -n "${TENANT_API_LPORT}" ]]; then
      echo "Tenant API:  http://127.0.0.1:${TENANT_API_LPORT}"
    else
      echo "Tenant API:  (not found / not exposed)"
    fi
  } | tee "${OUT_DIR}/endpoints.txt"

  verify_end_to_end "${KONG_LPORT}" "${WEBHOOK_LPORT}" "${GPU_LPORT}"

  log "=== Startup end ==="
  log "Artifacts saved: ${OUT_DIR}"
  log "Endpoints: ${OUT_DIR}/endpoints.txt"
  log "Burst curl errors (if any): ${OUT_DIR}/models-burst-high-errors.txt"
}

main "$@"
