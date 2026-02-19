cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kong-throttle-webhook
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kongplugin-toggle
rules:
  - apiGroups: ["configuration.konghq.com"]
    resources: ["kongplugins"]
    verbs: ["get", "list", "watch", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kongplugin-toggle-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kongplugin-toggle
subjects:
  - kind: ServiceAccount
    name: kong-throttle-webhook
    namespace: monitoring
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fake-gpu-metrics-code
  namespace: monitoring
data:
  server.py: |
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from urllib.parse import urlparse, parse_qs

    util_value = 10  # default

    class H(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype="text/plain; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))

        def do_GET(self):
            global util_value
            u = urlparse(self.path)
            if u.path == "/healthz":
                return self._send(200, "ok\n")
            if u.path == "/gpu_util":
                return self._send(200, f"{util_value}\n")
            if u.path == "/set":
                qs = parse_qs(u.query or "")
                if "util" not in qs:
                    return self._send(400, "missing util\n")
                try:
                    util_value = int(qs["util"][0])
                except Exception:
                    return self._send(400, "bad util\n")
                return self._send(200, f"ok util={util_value}\n")
            return self._send(404, "not found\n")

    if __name__ == "__main__":
        HTTPServer(("0.0.0.0", 8080), H).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fake-gpu-metrics
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fake-gpu-metrics
  template:
    metadata:
      labels:
        app: fake-gpu-metrics
    spec:
      containers:
        - name: server
          image: python:3.11-alpine
          ports:
            - containerPort: 8080
          command: ["python", "/app/server.py"]
          volumeMounts:
            - name: code
              mountPath: /app
      volumes:
        - name: code
          configMap:
            name: fake-gpu-metrics-code
---
apiVersion: v1
kind: Service
metadata:
  name: fake-gpu-metrics
  namespace: monitoring
spec:
  selector:
    app: fake-gpu-metrics
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kong-throttle-webhook-code
  namespace: monitoring
data:
  webhook.py: |
    import os, json, ssl
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from urllib.request import Request, urlopen
    from urllib.parse import urlparse

    METRICS_URL = os.getenv("METRICS_URL", "http://fake-gpu-metrics.monitoring.svc.cluster.local:8080/gpu_util")
    THRESHOLD = int(os.getenv("GPU_UTIL_THRESHOLD", "80"))
    TARGET_NS = os.getenv("TARGET_NS", "tenant-b")
    TARGET_PLUGIN = os.getenv("TARGET_PLUGIN", "rl-5per10s")

    SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    SA_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    KUBE_HOST = os.getenv("KUBERNETES_SERVICE_HOST")
    KUBE_PORT = os.getenv("KUBERNETES_SERVICE_PORT")
    API_BASE = f"https://{KUBE_HOST}:{KUBE_PORT}"

    def get_util():
        with urlopen(METRICS_URL, timeout=2) as r:
            s = r.read().decode("utf-8").strip()
            return int(s)

    def patch_kongplugin_disabled(disabled: bool):
        with open(SA_TOKEN_PATH, "r") as f:
            token = f.read().strip()

        url = f"{API_BASE}/apis/configuration.konghq.com/v1/namespaces/{TARGET_NS}/kongplugins/{TARGET_PLUGIN}"
        body = json.dumps({"disabled": bool(disabled)}).encode("utf-8")
        req = Request(url, data=body, method="PATCH")
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("Content-Type", "application/merge-patch+json")

        ctx = ssl.create_default_context(cafile=SA_CA_PATH)
        with urlopen(req, context=ctx, timeout=3) as r:
            return r.status, r.read().decode("utf-8")

    class H(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype="text/plain; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))

        def do_GET(self):
            p = urlparse(self.path).path
            if p == "/healthz":
                return self._send(200, "ok\n")
            return self._send(404, "not found\n")

        def do_POST(self):
            p = urlparse(self.path).path
            if p != "/decide":
                return self._send(404, "not found\n")
            try:
                util = get_util()
                # util >= threshold -> enable rate limit (disabled=false)
                desired_disabled = util < THRESHOLD
                status, _ = patch_kongplugin_disabled(desired_disabled)
                return self._send(200, f"ok util={util} threshold={THRESHOLD} disabled={str(desired_disabled).lower()} patch_status={status}\n")
            except Exception as e:
                return self._send(500, f"err {e}\n")

    if __name__ == "__main__":
        HTTPServer(("0.0.0.0", 8080), H).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kong-throttle-webhook
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kong-throttle-webhook
  template:
    metadata:
      labels:
        app: kong-throttle-webhook
    spec:
      serviceAccountName: kong-throttle-webhook
      containers:
        - name: webhook
          image: python:3.11-alpine
          ports:
            - containerPort: 8080
          env:
            - name: METRICS_URL
              value: "http://fake-gpu-metrics.monitoring.svc.cluster.local:8080/gpu_util"
            - name: GPU_UTIL_THRESHOLD
              value: "80"
            - name: TARGET_NS
              value: "tenant-b"
            - name: TARGET_PLUGIN
              value: "rl-5per10s"
          command: ["python", "/app/webhook.py"]
          volumeMounts:
            - name: code
              mountPath: /app
      volumes:
        - name: code
          configMap:
            name: kong-throttle-webhook-code
---
apiVersion: v1
kind: Service
metadata:
  name: kong-throttle-webhook
  namespace: monitoring
spec:
  selector:
    app: kong-throttle-webhook
  ports:
    - name: http
      port: 8080
      targetPort: 8080
YAML
