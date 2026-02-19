#!/usr/bin/env bash
# 執行指令
# PARALLEL=6 N_BURST=20 REQ_MAX_TIME=20 bash ~/first/gpu-throttle-demo.sh
set -euo pipefail

KONG_LOCAL_PORT="${KONG_LOCAL_PORT:-18080}"
HOST_HEADER="${HOST_HEADER:-b.litellm.local}"
APIKEY_HEADER_NAME="${APIKEY_HEADER_NAME:-apikey}"
APIKEY_VALUE="${APIKEY_VALUE:-tenant-b-user1-123456}"
HEALTH_PATH="${HEALTH_PATH:-/health}"

FAKE_GPU_LOCAL_PORT="${FAKE_GPU_LOCAL_PORT:-18090}"
WEBHOOK_LOCAL_PORT="${WEBHOOK_LOCAL_PORT:-18083}"

N_BURST="${N_BURST:-20}"
PARALLEL="${PARALLEL:-20}"
UTIL_HIGH="${UTIL_HIGH:-95}"
UTIL_LOW="${UTIL_LOW:-10}"

TARGET_NS="${TARGET_NS:-tenant-b}"
TARGET_PLUGIN="${TARGET_PLUGIN:-rl-5per10s}"

DECIDE_TIMEOUT="${DECIDE_TIMEOUT:-8}"
DECIDE_RETRIES="${DECIDE_RETRIES:-3}"
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"

REQ_CONNECT_TIMEOUT="${REQ_CONNECT_TIMEOUT:-2}"
REQ_MAX_TIME="${REQ_MAX_TIME:-6}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少指令：$1" >&2; exit 1; }; }
need kubectl; need curl; need xargs; need sort; need uniq; need sleep; need sed; need grep; need wc

log() { printf "\n== %s ==\n" "$*"; }
check_http() { curl -s --connect-timeout 1 -m 2 "$1" >/dev/null 2>&1; }

burst_codes_once() {
  # 只打一次 burst，把所有 HTTP code 一行一個吐出來
  seq 1 "$N_BURST" | xargs -P"$PARALLEL" -I{} sh -lc "
    curl -s --connect-timeout '${REQ_CONNECT_TIMEOUT}' -m '${REQ_MAX_TIME}' \
      -o /dev/null -w '%{http_code}\n' \
      -H 'Host: ${HOST_HEADER}' \
      -H '${APIKEY_HEADER_NAME}: ${APIKEY_VALUE}' \
      http://127.0.0.1:${KONG_LOCAL_PORT}${HEALTH_PATH} || echo 000
  "
}

counts_from_codes() {
  # stdin: codes
  sort | uniq -c
}

count_429_from_codes() {
  # stdin: codes
  grep -c '^429$' || true
}

set_util() {
  local u="$1"
  curl -s --connect-timeout 1 -m 3 "http://127.0.0.1:${FAKE_GPU_LOCAL_PORT}/set?util=${u}" || true
  echo "util=$(curl -s --connect-timeout 1 -m 3 http://127.0.0.1:${FAKE_GPU_LOCAL_PORT}/gpu_util)"
}

get_disabled() {
  kubectl -n "${TARGET_NS}" get kongplugin "${TARGET_PLUGIN}" -o jsonpath='{.disabled}{"\n"}' 2>/dev/null || true
}

decide_retry() {
  local i out
  for i in $(seq 1 "$DECIDE_RETRIES"); do
    out="$(curl -s -m "${DECIDE_TIMEOUT}" -X POST "http://127.0.0.1:${WEBHOOK_LOCAL_PORT}/decide" || true)"
    if echo "$out" | grep -q '^ok '; then
      echo "$out"
      return 0
    fi
    echo "decide attempt ${i}/${DECIDE_RETRIES} failed: ${out:-"(no output)"}" >&2
    sleep 1
  done
  return 1
}

ensure_disabled() {
  local want="$1"
  local out cur
  out="$(decide_retry || true)"
  echo "${out:-"(decide failed)"}"
  cur="$(get_disabled)"
  echo "rl disabled=${cur}"
  if [ "$cur" != "$want" ]; then
    echo "ERROR: rl disabled 應為 ${want}，但實際是 ${cur}" >&2
    kubectl -n monitoring logs deploy/kong-throttle-webhook --tail=30 >&2 || true
    exit 2
  fi
  echo "等待 ${SETTLE_SECONDS}s 讓 Kong 配置收斂..."
  sleep "${SETTLE_SECONDS}"
}

safe_header_dump() {
  # 重要：就算 curl 失敗也不讓腳本退出
  ( curl -i -s --connect-timeout "${REQ_CONNECT_TIMEOUT}" -m "${REQ_MAX_TIME}" \
      -H "Host: ${HOST_HEADER}" \
      -H "${APIKEY_HEADER_NAME}: ${APIKEY_VALUE}" \
      "http://127.0.0.1:${KONG_LOCAL_PORT}${HEALTH_PATH}" | sed -n '1,30p'
  ) || echo "(header dump failed)"
}

fail_diag() {
  echo
  echo "=== 診斷資訊 ===" >&2
  echo "rl disabled=$(get_disabled)" >&2
  echo "--- one request headers ---" >&2
  safe_header_dump >&2
  echo "--- webhook logs tail ---" >&2
  kubectl -n monitoring logs deploy/kong-throttle-webhook --tail=30 >&2 || true
}

log "檢查必要 port-forward"
check_http "http://127.0.0.1:${KONG_LOCAL_PORT}${HEALTH_PATH}" || { echo "Kong 入口連不到" >&2; exit 1; }
check_http "http://127.0.0.1:${FAKE_GPU_LOCAL_PORT}/healthz" || { echo "fake-gpu-metrics 連不到" >&2; exit 1; }
check_http "http://127.0.0.1:${WEBHOOK_LOCAL_PORT}/healthz" || { echo "webhook 連不到" >&2; exit 1; }
echo "OK：三個 port-forward 皆可連線"

# ===== HIGH =====
log "HIGH util=${UTIL_HIGH}（必須看到 >=1 個 429）"
set_util "${UTIL_HIGH}"
ensure_disabled "false"
codes="$(burst_codes_once)"
echo "-- burst counts --"
printf "%s\n" "$codes" | counts_from_codes
n429="$(printf "%s\n" "$codes" | count_429_from_codes)"
if [ "${n429}" -lt 1 ]; then
  echo "ERROR: HIGH 階段應出現 429，但沒有看到（n429=${n429}）" >&2
  fail_diag
  exit 3
fi
echo "PASS: HIGH n429=${n429} (total=$(printf "%s\n" "$codes" | wc -l))"

# ===== LOW =====
log "LOW util=${UTIL_LOW}（必須 0 個 429）"
set_util "${UTIL_LOW}"
ensure_disabled "true"
echo "-- one request headers (should NOT include X-RateLimit) --"
safe_header_dump
codes="$(burst_codes_once)"
echo "-- burst counts --"
printf "%s\n" "$codes" | counts_from_codes
n429="$(printf "%s\n" "$codes" | count_429_from_codes)"
if [ "${n429}" -ne 0 ]; then
  echo "ERROR: LOW 階段不應出現 429，但看到 n429=${n429}" >&2
  fail_diag
  exit 4
fi
echo "PASS: LOW n429=0 (total=$(printf "%s\n" "$codes" | wc -l))"

log "完成（HIGH 有 429、LOW 無 429）"
