cat > /tmp/webhook.py <<'PY'
import os, json, ssl, re
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.request import Request, urlopen
from urllib.parse import urlparse

# ======================
# Env
# ======================
METRICS_URL = os.getenv(
    "METRICS_URL",
    "http://fake-gpu-metrics.monitoring.svc.cluster.local:8080/metrics"
).rstrip("/")

THRESHOLD = float(os.getenv("GPU_UTIL_THRESHOLD", "80"))
TARGET_NS = os.getenv("TARGET_NS", "tenant-a")
TARGET_PLUGIN = os.getenv("TARGET_PLUGIN", "rl-5rps")

# How to match tenant label in metrics:
# - "strict": only accept series where labels.tenant == requested tenant
# - "auto"  : try requested tenant, then "default", then fallback to ANY (max)
# - "any"   : ignore tenant label and take max
MATCH_TENANT_LABEL = os.getenv("MATCH_TENANT_LABEL", "auto").strip().lower()

SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
KUBE_HOST = os.getenv("KUBERNETES_SERVICE_HOST")
KUBE_PORT = os.getenv("KUBERNETES_SERVICE_PORT")
API_BASE = f"https://{KUBE_HOST}:{KUBE_PORT}"

UTIL_METRIC_NAME = os.getenv("UTIL_METRIC_NAME", "fake_gpu_utilization_percent")

# ======================
# Helpers
# ======================
def _read_sa_token() -> str:
    with open(SA_TOKEN_PATH, "r", encoding="utf-8") as f:
        return f.read().strip()

def _http_json(url: str, method: str, body_obj=None, headers=None, timeout=3):
    token = _read_sa_token()
    ctx = ssl.create_default_context(cafile=SA_CA_PATH)

    data = None
    if body_obj is not None:
        data = json.dumps(body_obj).encode("utf-8")

    req = Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)

    with urlopen(req, context=ctx, timeout=timeout) as r:
        raw = r.read()
        return r.status, raw.decode("utf-8", "ignore")

# ======================
# Metrics parsing
# ======================
_METRIC_LINE_RE = re.compile(
    r'^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)\{(?P<labels>[^}]*)\}\s+(?P<val>[-+]?\d+(\.\d+)?)\s*$'
)

def _parse_labels(labels_str: str) -> dict:
    out = {}
    parts = [p.strip() for p in labels_str.split(",") if p.strip()]
    for p in parts:
        if "=" not in p:
            continue
        k, v = p.split("=", 1)
        k = k.strip()
        v = v.strip()
        if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            v = v[1:-1]
        out[k] = v
    return out

def _read_metrics_text() -> str:
    with urlopen(METRICS_URL, timeout=3) as r:
        return r.read().decode("utf-8", "ignore")

def _collect_util_values(metrics_text: str, tenant_filter: str | None) -> list[float]:
    vals = []
    for line in metrics_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _METRIC_LINE_RE.match(line)
        if not m:
            continue
        if m.group("name") != UTIL_METRIC_NAME:
            continue
        labels = _parse_labels(m.group("labels"))
        if tenant_filter is not None:
            if labels.get("tenant") != tenant_filter:
                continue
        try:
            vals.append(float(m.group("val")))
        except ValueError:
            continue
    return vals

def get_util_for_tenant(tenant: str) -> float:
    text = _read_metrics_text()

    mode = MATCH_TENANT_LABEL
    if mode not in ("strict", "auto", "any"):
        mode = "auto"

    if mode == "any":
        vals = _collect_util_values(text, tenant_filter=None)
        return max(vals) if vals else 0.0

    # strict / auto: first try requested tenant
    vals = _collect_util_values(text, tenant_filter=tenant)
    if vals:
        return sum(vals) / len(vals)

    if mode == "strict":
        return 0.0

    # auto fallback 1: tenant="default"
    vals = _collect_util_values(text, tenant_filter="default")
    if vals:
        return sum(vals) / len(vals)

    # auto fallback 2: ignore tenant, take max
    vals = _collect_util_values(text, tenant_filter=None)
    return max(vals) if vals else 0.0

# ======================
# K8s patch
# ======================
def patch_kongplugin_disabled(namespace: str, plugin: str, disabled: bool):
    body = {"disabled": bool(disabled)}
    headers = {"Content-Type": "application/merge-patch+json"}

    candidates = [
        f"{API_BASE}/apis/configuration.konghq.com/v1/namespaces/{namespace}/kongplugins/{plugin}",
        f"{API_BASE}/apis/configuration.konghq.com/v1beta1/namespaces/{namespace}/kongplugins/{plugin}",
    ]

    last_err = None
    for url in candidates:
        try:
            status, resp = _http_json(url, "PATCH", body_obj=body, headers=headers, timeout=3)
            return {"status": status, "url": url, "response": resp[:300]}
        except Exception as e:
            last_err = (url, str(e))

    raise RuntimeError(f"patch failed; last={last_err}")

# ======================
# HTTP server
# ======================
class H(BaseHTTPRequestHandler):
    def _send(self, code: int, body: str, ctype="application/json; charset=utf-8"):
        payload = body.encode("utf-8", "ignore")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        p = urlparse(self.path).path
        if p == "/healthz":
            return self._send(200, json.dumps({"status": "ok"}))
        return self._send(404, json.dumps({"error": "not_found"}))

    def do_POST(self):
        p = urlparse(self.path).path
        if p != "/decide":
            return self._send(404, json.dumps({"error": "not_found"}))

        try:
            n = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(n) if n > 0 else b"{}"
            req = json.loads(raw.decode("utf-8", "ignore")) if raw else {}
            tenant = (req.get("tenant") or TARGET_NS)

            util = get_util_for_tenant(tenant)

            desired_disabled = util < THRESHOLD
            patch = patch_kongplugin_disabled(tenant, TARGET_PLUGIN, desired_disabled)

            out = {
                "tenant": tenant,
                "plugin": TARGET_PLUGIN,
                "metrics_url": METRICS_URL,
                "metric": UTIL_METRIC_NAME,
                "util": util,
                "threshold": THRESHOLD,
                "disabled": bool(desired_disabled),
                "match_tenant_label": MATCH_TENANT_LABEL,
                "patch": patch,
            }
            return self._send(200, json.dumps(out))
        except Exception as e:
            return self._send(500, json.dumps({"error": "internal", "message": str(e)}))

if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), H).serve_forever()
PY
