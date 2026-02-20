#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BUNDLE_DIR="${RUN_DIR}/bundle-${TS}"
mkdir -p "${BUNDLE_DIR}/k8s" "${BUNDLE_DIR}/images" "${BUNDLE_DIR}/scripts" "${BUNDLE_DIR}/meta"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn(){ printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2; }
die(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

# 你要搬家的 namespaces（保守全打包）
NAMESPACES=(
  kong monitoring tenant-a tenant-b tenant-c tenant-d
  rocc rocc-full1 rocc-full2
)

# 需要時可跳過 images（例如你不想讓它 pull/save）
SKIP_IMAGES="${SKIP_IMAGES:-0}"

log "BUNDLE_DIR=${BUNDLE_DIR}"

# 0) 基本資訊
kubectl version --client=true -o yaml > "${BUNDLE_DIR}/meta/kubectl-version.yaml" 2>/dev/null || true
kubectl cluster-info > "${BUNDLE_DIR}/meta/cluster-info.txt" 2>&1 || true
kubectl get ns -o wide > "${BUNDLE_DIR}/meta/namespaces.txt" 2>&1 || true

# 1) 匯出 namespace 資源 YAML
export_ns() {
  local ns="$1"
  if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
    log "ns=${ns} not found, skip"
    return 0
  fi

  log "Export resources ns=${ns}"
  mkdir -p "${BUNDLE_DIR}/k8s/${ns}"

  local kinds=(
    deploy sts ds rs po svc endpoints ingress cm secret sa
    role rolebinding clusterrole clusterrolebinding
    hpa pdb job cronjob netpol
  )

  for kind in "${kinds[@]}"; do
    kubectl -n "${ns}" get "${kind}" -o yaml > "${BUNDLE_DIR}/k8s/${ns}/${kind}.yaml" 2>/dev/null || true
  done

  # Kong CRDs（有裝就可能存在）
  local kong_kinds=(kongplugin kongingress kongconsumer kongcredential)
  for kind in "${kong_kinds[@]}"; do
    kubectl -n "${ns}" get "${kind}" -o yaml > "${BUNDLE_DIR}/k8s/${ns}/${kind}.yaml" 2>/dev/null || true
  done

  # Cilium CRDs（有裝就可能存在）
  local cilium_kinds=(ciliumnetworkpolicy ciliumclusterwidenetworkpolicy)
  for kind in "${cilium_kinds[@]}"; do
    kubectl -n "${ns}" get "${kind}" -o yaml > "${BUNDLE_DIR}/k8s/${ns}/${kind}.yaml" 2>/dev/null || true
  done

  kubectl -n "${ns}" get all -o wide > "${BUNDLE_DIR}/k8s/${ns}/all-wide.txt" 2>&1 || true
}

for ns in "${NAMESPACES[@]}"; do
  export_ns "${ns}"
done

# 2) 收集 images（保證一行一個）
collect_images_ns() {
  local ns="$1"
  kubectl get ns "${ns}" >/dev/null 2>&1 || return 0

  # containers
  kubectl -n "${ns}" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null || true
  # initContainers（避免漏）
  kubectl -n "${ns}" get pods -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null || true
}

log "Collect images from selected namespaces"
images_file="${BUNDLE_DIR}/images/images-in-use.txt"
tmp_raw="${BUNDLE_DIR}/images/images-raw.txt"
: > "${tmp_raw}"

for ns in "${NAMESPACES[@]}"; do
  collect_images_ns "${ns}" >> "${tmp_raw}"
done

# 保險：把「同一行多個欄位」拆成多行，再去空白、去重
awk '{for(i=1;i<=NF;i++) print $i}' "${tmp_raw}" \
  | sed '/^$/d' \
  | sort -u > "${images_file}"

wc -l "${images_file}" | tee "${BUNDLE_DIR}/meta/images-count.txt"

if [[ "${SKIP_IMAGES}" == "1" ]]; then
  log "SKIP_IMAGES=1, skip docker pull/save"
else
  have docker || die "docker not found, cannot pull/save images"

  log "docker found, pull images then save tar.gz"
  while read -r img; do
    [[ -z "${img}" ]] && continue
    log "pull ${img}"
    docker pull "${img}" >/dev/null
  done < "${images_file}"

  tar_path="${BUNDLE_DIR}/images/all-images.tar"
  gz_path="${BUNDLE_DIR}/images/all-images.tar.gz"

  log "docker save -> ${gz_path}"
  # shellcheck disable=SC2046
  docker save -o "${tar_path}" $(cat "${images_file}")
  gzip -1 "${tar_path}"
  ls -lh "${gz_path}" | tee "${BUNDLE_DIR}/meta/images-tar-size.txt"
fi

# 4) 收腳本與配置（不收 .venv）
log "Copy scripts/config"
if [[ -d "${RUN_DIR}/final" ]]; then
  mkdir -p "${BUNDLE_DIR}/scripts/final"
  rsync -a --exclude '.venv' "${RUN_DIR}/final/" "${BUNDLE_DIR}/scripts/final/"
fi

for f in startup-all.sh pa.sh *.sh; do
  if [[ -f "${RUN_DIR}/${f}" ]]; then
    cp -a "${RUN_DIR}/${f}" "${BUNDLE_DIR}/scripts/" 2>/dev/null || true
  fi
done

cat > "${BUNDLE_DIR}/README.txt" <<'R'
這個 bundle 內容：
- k8s/      匯出的 namespace YAML 與狀態
- images/   images-in-use.txt 與 all-images.tar.gz（若有 docker 且未 SKIP_IMAGES）
- scripts/  你的 final/ 腳本與其他 .sh
- meta/     版本與摘要

還原建議：
- 新機器用 Docker Desktop + WSL2（Ubuntu）跑 bootstrap 容器
- bootstrap 會：建 kind、load images、apply manifests、跑驗證腳本
R

log "DONE. Bundle created at: ${BUNDLE_DIR}"
