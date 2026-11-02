#!/bin/bash

K3S_DNSNAME="k3s.vigne.com.br"

curl -sfL https://get.k3s.io | sh -s - server --tls-san "$K3S_DNSNAME"

curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add external-secrets https://charts.external-secrets.io

helm repo update

helm install --version 1.4.0 --create-namespace \
  --namespace vault-secrets-operator vault-secrets-operator \
  hashicorp/vault-secrets-operator

helm install --version 2.6.0 --create-namespace \
  --namespace external-secrets external-secrets \
  external-secrets/external-secrets

kubectl -n vault-secrets-operator create serviceaccount vault-vso-reviewer

kubectl create clusterrolebinding vault-vso-reviewer-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault-secrets-operator:vault-vso-reviewer

kubectl -n vault-secrets-operator create token vault-vso-reviewer --duration=175200h > reviewer.jwt

kubectl create ns app1
kubectl create sa vault-vso -n app1 --dry-run=client -o json \
  | jq '.automountServiceAccountToken=false' \
  | kubectl apply -f -

kubectl create ns app2
kubectl create sa vault-eso -n app2 --dry-run=client -o json \
  | jq '.automountServiceAccountToken=false' \
  | kubectl apply -f -