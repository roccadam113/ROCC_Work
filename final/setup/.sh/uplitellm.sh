cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: tenant-a
spec:
  replicas: 1
  selector:
    matchLabels: {app: litellm}
  template:
    metadata:
      labels: {app: litellm}
    spec:
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main
        ports:
        - containerPort: 4000
        resources:
          requests: {cpu: "50m", memory: "64Mi"}
          limits:   {cpu: "200m", memory: "256Mi"}
        env:
        - name: LITELLM_LOG
          value: "INFO"
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: tenant-a
spec:
  selector: {app: litellm}
  ports:
  - name: http
    port: 4000
    targetPort: 4000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: tenant-b
spec:
  replicas: 1
  selector:
    matchLabels: {app: litellm}
  template:
    metadata:
      labels: {app: litellm}
    spec:
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main
        ports:
        - containerPort: 4000
        resources:
          requests: {cpu: "50m", memory: "64Mi"}
          limits:   {cpu: "200m", memory: "256Mi"}
        env:
        - name: LITELLM_LOG
          value: "INFO"
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: tenant-b
spec:
  selector: {app: litellm}
  ports:
  - name: http
    port: 4000
    targetPort: 4000
YAML
