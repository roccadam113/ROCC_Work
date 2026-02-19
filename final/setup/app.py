import json
import re
from http.server import BaseHTTPRequestHandler, HTTPServer

from kubernetes import client, config


INGRESS_CLASS = "kong"
LITELLM_SERVICE_NAME = "litellm"
LITELLM_SERVICE_PORT = 4000


def k8s_clients():
    # Pod 用 ServiceAccount in-cluster config
    config.load_incluster_config()
    v1 = client.CoreV1Api()
    net = client.NetworkingV1Api()
    crd = client.CustomObjectsApi()
    return v1, net, crd


def ensure_namespace(v1: client.CoreV1Api, name: str):
    try:
        v1.read_namespace(name)
        return False
    except client.exceptions.ApiException as e:
        if e.status != 404:
            raise
    ns = client.V1Namespace(metadata=client.V1ObjectMeta(name=name))
    v1.create_namespace(ns)
    return True


def upsert_kongconsumer(crd: client.CustomObjectsApi, ns: str, username: str, cred_secret_name: str):
    body = {
        "apiVersion": "configuration.konghq.com/v1",
        "kind": "KongConsumer",
        "metadata": {
            "name": username,
            "namespace": ns,
            "annotations": {
                "kubernetes.io/ingress.class": INGRESS_CLASS,
                "konghq.com/ingress.class": INGRESS_CLASS,
            },
        },
        "username": username,
        "credentials": [cred_secret_name],
    }

    group = "configuration.konghq.com"
    version = "v1"
    plural = "kongconsumers"

    try:
        crd.get_namespaced_custom_object(group, version, ns, plural, username)
        crd.patch_namespaced_custom_object(
            group, version, ns, plural, username, body)
        return False
    except client.exceptions.ApiException as e:
        if e.status != 404:
            raise
    crd.create_namespaced_custom_object(group, version, ns, plural, body)
    return True


def upsert_litellm_service_externalname(v1: client.CoreV1Api, ns: str, target_fqdn: str):
    """
    在新租戶 namespace 建立 Service/litellm (ExternalName)，把流量導到既有的 litellm。
    target_fqdn 例：litellm.tenant-b.svc.cluster.local
    """
    meta = client.V1ObjectMeta(name=LITELLM_SERVICE_NAME, namespace=ns)

    svc = client.V1Service(
        api_version="v1",
        kind="Service",
        metadata=meta,
        spec=client.V1ServiceSpec(
            type="ExternalName",
            external_name=target_fqdn,
            ports=[client.V1ServicePort(
                name="http", port=LITELLM_SERVICE_PORT, target_port=LITELLM_SERVICE_PORT)],
        ),
    )

    try:
        v1.read_namespaced_service(LITELLM_SERVICE_NAME, ns)
        v1.patch_namespaced_service(LITELLM_SERVICE_NAME, ns, svc)
        return False
    except client.exceptions.ApiException as e:
        if e.status != 404:
            raise

    v1.create_namespaced_service(ns, svc)
    return True


def upsert_keyauth_secret(v1: client.CoreV1Api, ns: str, secret_name: str, consumer_username: str, apikey: str):
    # KIC key-auth secret format：stringData.key + stringData.kongCredType
    meta = client.V1ObjectMeta(
        name=secret_name,
        namespace=ns,
        labels={
            "konghq.com/credential": "key-auth",
            "konghq.com/consumer": consumer_username,
        },
        annotations={
            "kubernetes.io/ingress.class": INGRESS_CLASS,
            "konghq.com/ingress.class": INGRESS_CLASS,
        },
    )

    secret = client.V1Secret(
        api_version="v1",
        kind="Secret",
        metadata=meta,
        type="Opaque",
        string_data={
            "key": apikey,
            "kongCredType": "key-auth",
        },
    )

    try:
        v1.read_namespaced_secret(secret_name, ns)
        # 用 patch 以免覆蓋到其他欄位
        v1.patch_namespaced_secret(secret_name, ns, secret)
        return False
    except client.exceptions.ApiException as e:
        if e.status != 404:
            raise

    v1.create_namespaced_secret(ns, secret)
    return True


def upsert_ingress(net: client.NetworkingV1Api, ns: str, name: str, host: str):
    meta = client.V1ObjectMeta(
        name=name,
        namespace=ns,
        annotations={
            "kubernetes.io/ingress.class": INGRESS_CLASS,
            "konghq.com/ingress.class": INGRESS_CLASS,
        },
    )

    backend = client.V1IngressBackend(
        service=client.V1IngressServiceBackend(
            name=LITELLM_SERVICE_NAME,
            port=client.V1ServiceBackendPort(number=LITELLM_SERVICE_PORT),
        )
    )

    rule = client.V1IngressRule(
        host=host,
        http=client.V1HTTPIngressRuleValue(
            paths=[
                client.V1HTTPIngressPath(
                    path="/",
                    path_type="Prefix",
                    backend=backend,
                )
            ]
        ),
    )

    spec = client.V1IngressSpec(rules=[rule], ingress_class_name=INGRESS_CLASS)
    ing = client.V1Ingress(api_version="networking.k8s.io/v1",
                           kind="Ingress", metadata=meta, spec=spec)

    try:
        net.read_namespaced_ingress(name, ns)
        net.patch_namespaced_ingress(name, ns, ing)
        return False
    except client.exceptions.ApiException as e:
        if e.status != 404:
            raise

    net.create_namespaced_ingress(ns, ing)
    return True


class H(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/healthz", "/health"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/tenants":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            req = json.loads(raw.decode("utf-8"))
        except Exception as e:
            return self._json(400, {"error": "invalid_json", "detail": str(e)})

        tenant = req.get("tenant")
        if not tenant or not isinstance(tenant, str):
            return self._json(400, {"error": "missing_tenant", "detail": "body.tenant is required"})

        # tenant 必須是 DNS label 風格
        if not re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", tenant):
            return self._json(400, {"error": "invalid_tenant", "detail": "must match DNS label pattern"})

        # 允許外部傳 apikey，不傳就用固定規則產生（原型用）
        apikey = req.get("apikey")
        if apikey is None:
            apikey = f"{tenant}-user1-123456"
        if not isinstance(apikey, str) or len(apikey) < 8:
            return self._json(400, {"error": "invalid_apikey", "detail": "body.apikey must be a string (len>=8)"})

        # 命名規則（跟你前面 tenant-b 做法一致）
        consumer_name = f"{tenant}-user1"
        secret_name = f"{consumer_name}-keyauth"
        ingress_name = "litellm"
        host = f"{tenant}.litellm.local"

        v1, net, crd = k8s_clients()

        try:
            ns_created = ensure_namespace(v1, tenant)
            sec_created = upsert_keyauth_secret(
                v1, tenant, secret_name, consumer_name, apikey)
            kc_created = upsert_kongconsumer(
                crd, tenant, consumer_name, secret_name)
            ing_created = upsert_ingress(net, tenant, ingress_name, host)
        except client.exceptions.ApiException as e:
            return self._json(500, {"error": "k8s_error", "status": e.status, "detail": e.body or e.reason})
        except Exception as e:
            return self._json(500, {"error": "internal_error", "detail": str(e)})

        # 以「是否新增」回報；但即使是 False，也代表已 reconcile（補齊/更新）
        return self._json(
            201 if ns_created else 200,
            {
                "ok": True,
                "tenant": tenant,
                "host": host,
                "consumer": consumer_name,
                "secret": secret_name,
                "created": ns_created,
                "changes": {
                    "secret_created_or_patched": True,
                    "kongconsumer_created_or_patched": True,
                    "ingress_created_or_patched": True,
                },
            },
        )


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), H).serve_forever()
