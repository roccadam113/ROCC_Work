import os
import re
from datetime import datetime, timezone
from typing import Optional, Dict, Any

import requests
from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel, Field

from kubernetes import client, config
from kubernetes.client.rest import ApiException

APP_NAME = "tenant-admin-api"

# ============ Auth ============
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "change-me")

# ============ Grafana ============
GRAFANA_URL = os.getenv("GRAFANA_URL", "")
GRAFANA_USER = os.getenv("GRAFANA_USER", "")
GRAFANA_PASS = os.getenv("GRAFANA_PASS", "")
GRAFANA_VERIFY_TLS = os.getenv("GRAFANA_VERIFY_TLS", "true").lower() == "true"

# Grafana Prometheus datasource UID (from /api/datasources)
# Your current Grafana shows Prometheus datasource uid: PBFA97CFB590B2093
GRAFANA_PROM_DS_UID = os.getenv("GRAFANA_PROM_DS_UID", "PBFA97CFB590B2093")


def grafana_enabled() -> bool:
    return bool(GRAFANA_URL and GRAFANA_USER and GRAFANA_PASS)


def grafana_create_folder(title: str) -> Dict[str, Any]:
    base = GRAFANA_URL.rstrip("/")
    url = f"{base}/api/folders"
    payload = {"title": title}

    try:
        r = requests.post(
            url,
            json=payload,
            auth=(GRAFANA_USER, GRAFANA_PASS),
            timeout=10,
            verify=GRAFANA_VERIFY_TLS,
        )
    except requests.exceptions.RequestException as e:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "GRAFANA_UNREACHABLE",
                "message": "Cannot reach Grafana API (create folder)",
                "details": {"exception": str(e), "grafana_url": GRAFANA_URL, "title": title},
            },
        )

    # 200/201 ok
    if r.status_code in (200, 201):
        return r.json()

    # 412 often means folder already exists -> list and find it
    if r.status_code == 412:
        try:
            lr = requests.get(
                f"{base}/api/folders",
                auth=(GRAFANA_USER, GRAFANA_PASS),
                timeout=10,
                verify=GRAFANA_VERIFY_TLS,
            )
        except requests.exceptions.RequestException as e:
            raise HTTPException(
                status_code=502,
                detail={
                    "error": "GRAFANA_UNREACHABLE",
                    "message": "Cannot reach Grafana API (list folders)",
                    "details": {"exception": str(e), "grafana_url": GRAFANA_URL},
                },
            )
        if lr.status_code == 200:
            for f in lr.json():
                if f.get("title") == title:
                    return f

    raise HTTPException(
        status_code=502,
        detail={
            "error": "GRAFANA_CREATE_FOLDER_FAILED",
            "message": f"Grafana API returned {r.status_code}",
            "details": {"status_code": r.status_code, "body": r.text[:300], "title": title},
        },
    )


def grafana_create_dashboard(folder_uid: str, title: str) -> Dict[str, Any]:
    """
    Create a dashboard containing:
    - Variables: tenant, api_key
    - Panels: GPU Util %, GPU Mem (MB), GPU Power (W)
    Datasource is fixed by Grafana Prometheus datasource UID (GRAFANA_PROM_DS_UID).
    """
    base = GRAFANA_URL.rstrip("/")
    url = f"{base}/api/dashboards/db"
    ds_uid = GRAFANA_PROM_DS_UID

    dashboard = {
        "uid": None,
        "title": title,
        "timezone": "browser",
        "schemaVersion": 39,
        "version": 0,
        "refresh": "10s",
        "tags": ["tenant", "gpu", "fake-dcgm"],
        "templating": {
            "list": [
                {
                    "type": "query",
                    "name": "tenant",
                    "label": "Tenant",
                    "datasource": {"type": "prometheus", "uid": ds_uid},
                    "query": {"query": "label_values(fake_gpu_utilization_percent, tenant)", "refId": "PromQ"},
                    "includeAll": True,
                    "allValue": ".*",
                    "multi": True,
                    "refresh": 1,
                    "current": {"selected": True, "text": "All", "value": [".*"]},
                },
                {
                    "type": "query",
                    "name": "api_key",
                    "label": "API Key",
                    "datasource": {"type": "prometheus", "uid": ds_uid},
                    "query": {
                        "query": "label_values(fake_gpu_utilization_percent{tenant=~\"$tenant\"}, api_key)",
                        "refId": "PromQ",
                    },
                    "includeAll": True,
                    "allValue": ".*",
                    "multi": True,
                    "refresh": 1,
                    "current": {"selected": True, "text": "All", "value": [".*"]},
                },
            ]
        },
        "panels": [
            {
                "type": "timeseries",
                "title": "GPU Utilization (%)",
                "datasource": {"type": "prometheus", "uid": ds_uid},
                "gridPos": {"h": 9, "w": 24, "x": 0, "y": 0},
                "targets": [
                    {
                        "refId": "A",
                        "expr": (
                            "avg by (tenant, api_key) "
                            "(fake_gpu_utilization_percent{tenant=~\"$tenant\", api_key=~\"$api_key\"})"
                        ),
                        "legendFormat": "{{tenant}} / {{api_key}}",
                    }
                ],
            },
            {
                "type": "timeseries",
                "title": "GPU Memory Used (MB)",
                "datasource": {"type": "prometheus", "uid": ds_uid},
                "gridPos": {"h": 9, "w": 24, "x": 0, "y": 9},
                "targets": [
                    {
                        "refId": "A",
                        "expr": (
                            "avg by (tenant, api_key) "
                            "(fake_gpu_memory_used_megabytes{tenant=~\"$tenant\", api_key=~\"$api_key\"})"
                        ),
                        "legendFormat": "{{tenant}} / {{api_key}}",
                    }
                ],
            },
            {
                "type": "timeseries",
                "title": "GPU Power (W)",
                "datasource": {"type": "prometheus", "uid": ds_uid},
                "gridPos": {"h": 9, "w": 24, "x": 0, "y": 18},
                "targets": [
                    {
                        "refId": "A",
                        "expr": (
                            "avg by (tenant, api_key) "
                            "(fake_gpu_power_watts{tenant=~\"$tenant\", api_key=~\"$api_key\"})"
                        ),
                        "legendFormat": "{{tenant}} / {{api_key}}",
                    }
                ],
            },
        ],
    }

    payload = {"folderUid": folder_uid,
               "overwrite": True, "dashboard": dashboard}

    try:
        r = requests.post(
            url,
            json=payload,
            auth=(GRAFANA_USER, GRAFANA_PASS),
            timeout=10,
            verify=GRAFANA_VERIFY_TLS,
        )
    except requests.exceptions.RequestException as e:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "GRAFANA_UNREACHABLE",
                "message": "Cannot reach Grafana API (create dashboard)",
                "details": {"exception": str(e), "grafana_url": GRAFANA_URL, "folder_uid": folder_uid},
            },
        )

    if r.status_code == 200:
        return r.json()

    raise HTTPException(
        status_code=502,
        detail={
            "error": "GRAFANA_CREATE_DASHBOARD_FAILED",
            "message": f"Grafana API returned {r.status_code}",
            "details": {"status_code": r.status_code, "body": r.text[:300], "folder_uid": folder_uid},
        },
    )


# ============ Harbor ============
HARBOR_URL = os.getenv("HARBOR_URL", "")
HARBOR_USER = os.getenv("HARBOR_USER", "")
HARBOR_PASS = os.getenv("HARBOR_PASS", "")
HARBOR_VERIFY_TLS = os.getenv("HARBOR_VERIFY_TLS", "true").lower() == "true"


def harbor_enabled() -> bool:
    return bool(HARBOR_URL and HARBOR_USER and HARBOR_PASS)


def harbor_create_project(project_name: str, visibility: str) -> Dict[str, Any]:
    is_public = (visibility == "public")
    base = HARBOR_URL.rstrip("/")
    url = f"{base}/api/v2.0/projects"
    payload = {"project_name": project_name, "public": is_public}

    # Create project
    try:
        r = requests.post(
            url,
            json=payload,
            auth=(HARBOR_USER, HARBOR_PASS),
            timeout=10,
            verify=HARBOR_VERIFY_TLS,
        )
    except requests.exceptions.RequestException as e:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "HARBOR_UNREACHABLE",
                "message": "Cannot reach Harbor API",
                "details": {"exception": str(e), "harbor_url": HARBOR_URL, "project": project_name},
            },
        )

    if r.status_code == 409:
        # already exists -> try lookup id for nicer response
        try:
            pr = requests.get(
                f"{base}/api/v2.0/projects",
                params={"name": project_name},
                auth=(HARBOR_USER, HARBOR_PASS),
                timeout=10,
                verify=HARBOR_VERIFY_TLS,
            )
        except requests.exceptions.RequestException:
            return {"project_name": project_name, "project_id": None, "already_exists": True}

        pid = None
        if pr.status_code == 200:
            try:
                data = pr.json()
            except ValueError:
                data = None
            if isinstance(data, list) and len(data) > 0:
                pid = data[0].get("project_id")

        return {"project_name": project_name, "project_id": pid, "already_exists": True}

    if r.status_code != 201:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "HARBOR_CREATE_PROJECT_FAILED",
                "message": f"Harbor API returned {r.status_code}",
                "details": {"status_code": r.status_code, "body": r.text[:300], "project": project_name},
            },
        )

    # Lookup project id
    try:
        pr = requests.get(
            f"{base}/api/v2.0/projects",
            params={"name": project_name},
            auth=(HARBOR_USER, HARBOR_PASS),
            timeout=10,
            verify=HARBOR_VERIFY_TLS,
        )
    except requests.exceptions.RequestException as e:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "HARBOR_UNREACHABLE",
                "message": "Cannot reach Harbor API (project lookup)",
                "details": {"exception": str(e), "harbor_url": HARBOR_URL, "project": project_name},
            },
        )

    pid = None
    if pr.status_code == 200:
        try:
            data = pr.json()
        except ValueError:
            data = None
        if isinstance(data, list) and len(data) > 0:
            pid = data[0].get("project_id")

    return {"project_name": project_name, "project_id": pid}


def require_admin(auth_header: Optional[str]):
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail={
                            "error": "UNAUTHORIZED", "message": "Missing Bearer token"})
    token = auth_header.split(" ", 1)[1].strip()
    if token != ADMIN_TOKEN:
        raise HTTPException(status_code=403, detail={
                            "error": "FORBIDDEN", "message": "Invalid token"})


# ============ Tenant name validation ============
TENANT_RE = re.compile(
    r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")  # K8s DNS label


def validate_tenant_name(name: str):
    if not TENANT_RE.match(name):
        raise HTTPException(
            status_code=400,
            detail={
                "error": "INVALID_TENANT_NAME",
                "message": "tenant must be DNS-safe: lower-case alnum and '-', 1-63 chars, cannot start/end with '-'",
                "details": {"tenant": name},
            },
        )


# ============ K8s client ============
def k8s_core() -> client.CoreV1Api:
    """
    In-cluster: config.load_incluster_config()
    Local dev:  config.load_kube_config()
    Controlled by K8S_MODE env: incluster|kubeconfig
    """
    mode = os.getenv("K8S_MODE", "incluster")
    if mode == "kubeconfig":
        config.load_kube_config()
    else:
        config.load_incluster_config()
    return client.CoreV1Api()


# ============ API models ============
class QuotaModel(BaseModel):
    requests_per_second: int = Field(default=5, ge=1, le=1000)
    burst: int = Field(default=10, ge=1, le=5000)


class ObservabilityModel(BaseModel):
    create_grafana_folder: bool = True
    create_grafana_dashboard: bool = True


class RegistryModel(BaseModel):
    create_harbor_project: bool = True
    visibility: str = Field(default="private", pattern="^(private|public)$")


class CreateTenantRequest(BaseModel):
    tenant: str
    display_name: Optional[str] = None
    quota: QuotaModel = QuotaModel()
    observability: ObservabilityModel = ObservabilityModel()
    registry: RegistryModel = RegistryModel()


class CreateTenantResponse(BaseModel):
    tenant: str
    status: str
    k8s: Dict[str, Any]
    harbor: Optional[Dict[str, Any]] = None
    grafana: Optional[Dict[str, Any]] = None
    created_at: str


app = FastAPI(title=APP_NAME)


@app.post("/v1/tenants", response_model=CreateTenantResponse, status_code=201)
def create_tenant(req: CreateTenantRequest, authorization: Optional[str] = Header(default=None)):
    require_admin(authorization)
    validate_tenant_name(req.tenant)

    v1 = k8s_core()

    # Check exists
    try:
        v1.read_namespace(req.tenant)
        raise HTTPException(
            status_code=409,
            detail={"error": "TENANT_ALREADY_EXISTS",
                    "message": "namespace already exists", "details": {"tenant": req.tenant}},
        )
    except ApiException as e:
        if e.status != 404:
            raise HTTPException(
                status_code=500,
                detail={"error": "K8S_ERROR", "message": f"read_namespace failed: {e.reason}", "details": {
                    "tenant": req.tenant}},
            )

    # Create namespace with labels for future aggregation
    ns_body = client.V1Namespace(
        metadata=client.V1ObjectMeta(
            name=req.tenant,
            labels={"tenant": req.tenant, "managed-by": APP_NAME},
        )
    )
    try:
        v1.create_namespace(ns_body)
    except ApiException as e:
        if e.status == 409:
            raise HTTPException(
                status_code=409,
                detail={"error": "TENANT_ALREADY_EXISTS",
                        "message": "namespace already exists", "details": {"tenant": req.tenant}},
            )
        raise HTTPException(
            status_code=500,
            detail={"error": "K8S_CREATE_NAMESPACE_FAILED",
                    "message": f"{e.reason}", "details": {"tenant": req.tenant}},
        )

    harbor_info = None
    grafana_info = None

    # Harbor (optional)
    if req.registry.create_harbor_project:
        if not harbor_enabled():
            raise HTTPException(
                status_code=502,
                detail={
                    "error": "HARBOR_NOT_CONFIGURED",
                    "message": "Harbor env vars missing: HARBOR_URL/HARBOR_USER/HARBOR_PASS",
                    "details": {"tenant": req.tenant},
                },
            )
        harbor_info = harbor_create_project(
            req.tenant, req.registry.visibility)

    # Grafana (optional)
    if req.observability.create_grafana_folder:
        if not grafana_enabled():
            raise HTTPException(
                status_code=502,
                detail={
                    "error": "GRAFANA_NOT_CONFIGURED",
                    "message": "Grafana env vars missing: GRAFANA_URL/GRAFANA_USER/GRAFANA_PASS",
                    "details": {"tenant": req.tenant},
                },
            )

        folder = grafana_create_folder(f"tenant-{req.tenant}")

        dash_info = None
        if req.observability.create_grafana_dashboard:
            dash = grafana_create_dashboard(folder.get(
                "uid"), f"tenant-{req.tenant}-overview")
            dash_info = {"dashboard_uid": dash.get(
                "uid"), "dashboard_url": dash.get("url")}

        grafana_info = {"folder_uid": folder.get("uid"), **(dash_info or {})}

    now = datetime.now(timezone.utc).isoformat()
    return CreateTenantResponse(
        tenant=req.tenant,
        status="created",
        k8s={"namespace": req.tenant},
        harbor=harbor_info,
        grafana=grafana_info,
        created_at=now,
    )


@app.get("/v1/tenants/{tenant}")
def get_tenant(tenant: str, authorization: Optional[str] = Header(default=None)):
    require_admin(authorization)
    validate_tenant_name(tenant)

    v1 = k8s_core()
    try:
        ns = v1.read_namespace(tenant)
        return {
            "tenant": tenant,
            "status": "created",
            "k8s": {
                "namespace": tenant,
                "labels": ns.metadata.labels or {},
                "created_at": ns.metadata.creation_timestamp.isoformat() if ns.metadata.creation_timestamp else None,
            },
        }
    except ApiException as e:
        if e.status == 404:
            return {"tenant": tenant, "status": "not_found"}
        raise HTTPException(status_code=500, detail={
                            "error": "K8S_ERROR", "message": f"{e.reason}", "details": {"tenant": tenant}})
