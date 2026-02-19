#!/usr/bin/env bash
set -euo pipefail

POD="$(kubectl -n tenant-b get pod -l app=litellm -o jsonpath='{.items[0].metadata.name}')"
echo "POD=$POD"

echo "== config excerpt =="
kubectl -n tenant-b exec pod/$POD -- sh -lc 'sed -n "1,120p" /config/config.yaml'

echo "== upstream reachability (python) =="
kubectl -n tenant-b exec pod/$POD -- sh -lc '
python3 - <<'"'"'PY'"'"'
import urllib.request
for path in ["/health", "/healthz", "/v1/chat/completions"]:
    url="http://fake-llm.tenant-a.svc.cluster.local:8080"+path
    with urllib.request.urlopen(urllib.request.Request(url, method="GET"), timeout=5) as r:
        print(path, "->", r.status)
PY
'

echo "== proxy chat completion (python) =="
kubectl -n tenant-b exec pod/$POD -- sh -lc '
python3 - <<'"'"'PY'"'"'
import json, urllib.request
url="http://127.0.0.1:4000/v1/chat/completions"
payload={"model":"fake-gpt","messages":[{"role":"user","content":"ping"}],"max_tokens":16}
req=urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"}, method="POST")
with urllib.request.urlopen(req, timeout=10) as r:
    print("status", r.status)
    print(r.read(400).decode(errors="ignore"))
PY
'

echo "== litellm evidence (log grep) =="
kubectl -n tenant-b logs pod/$POD --tail=250 | egrep -n "Initializing OpenAI Client|POST Request Sent|fake-llm|POST /v1/chat/completions| 200 OK" || true
