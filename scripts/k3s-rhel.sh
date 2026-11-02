#!/bin/bash

# Nome DNS do cluster K3s, usado para configurar o servidor com um SAN TLS adicional.
K3S_DNSNAME="k3s.vigne.com.br"

# Instala o servidor K3s com suporte ao DNS informado, permitindo acesso externo ao cluster.
curl -sfL https://get.k3s.io | sh -s - server --tls-san "$K3S_DNSNAME"

# Instala o Helm 3 para gerenciar os charts de operadores e integrações.
curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Define o arquivo de configuração do Kubernetes para uso do kubectl/helm.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Adiciona os repositórios dos charts que serão instalados.
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add external-secrets https://charts.external-secrets.io

helm repo update

# Instala o operador Vault Secrets Operator em um namespace próprio.
helm install --version 1.4.0 --create-namespace \
  --namespace vault-secrets-operator vault-secrets-operator \
  hashicorp/vault-secrets-operator

# Instala o operador External Secrets para sincronização de segredos com providers externos.
helm install --version 2.6.0 --create-namespace \
  --namespace external-secrets external-secrets \
  external-secrets/external-secrets

# Cria o ServiceAccount que o Vault usará para revisar tokens do Kubernetes.
kubectl -n vault-secrets-operator create serviceaccount vault-vso-reviewer

# Concede ao ServiceAccount a permissão de autenticação do Kubernetes para validar tokens.
kubectl create clusterrolebinding vault-vso-reviewer-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault-secrets-operator:vault-vso-reviewer

# Gera um token JWT de longa duração para o reviewer do Vault e grava no arquivo reviewer.jwt.
kubectl -n vault-secrets-operator create token vault-vso-reviewer --duration=175200h > reviewer.jwt

# Cria os namespaces para as aplicações e os ServiceAccounts que serão usados pelo Vault.
kubectl create ns app1
kubectl create sa vault-vso -n app1 --dry-run=client -o json \
  | jq '.automountServiceAccountToken=false' \
  | kubectl apply -f -

kubectl create ns app2
kubectl create sa vault-eso -n app2 --dry-run=client -o json \
  | jq '.automountServiceAccountToken=false' \
  | kubectl apply -f -