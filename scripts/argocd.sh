#!/bin/bash

kubectl -n argocd apply --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/refs/tags/stable/manifests/install.yaml
kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-server

cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`argocd.lab.vigne.com.br\`)
      priority: 10
      services:
        - name: argocd-server
          port: 80
    - kind: Rule
      match: Host(\`argocd.lab.vigne.com.br\`) && Header(\`Content-Type\`, \`application/grpc\`)
      priority: 11
      services:
        - name: argocd-server
          port: 80
          scheme: h2c
  tls: {}
---
apiVersion: v1
data:
  server.insecure: "true"
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/name: argocd-cmd-params-cm
    app.kubernetes.io/part-of: argocd
  name: argocd-cmd-params-cm
  namespace: argocd    
EOF

kubectl -n argocd rollout restart deployment argocd-server
echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
echo
echo "ArgoCD URL: https://argocd.lab.vigne.com.br"
echo "ArgoCD Admin Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o json | jq -r .data.password | base64 -d)"