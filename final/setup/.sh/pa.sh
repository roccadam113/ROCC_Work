cat > tenant-a-litellm-ingress.yaml <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm
  namespace: tenant-a
  annotations:
    konghq.com/strip-path: "false"
spec:
  ingressClassName: kong
  rules:
  - host: a.litellm.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: litellm
            port:
              number: 4000
YAML

kubectl apply -f tenant-a-litellm-ingress.yaml
kubectl -n tenant-a get ingress litellm -o wide
