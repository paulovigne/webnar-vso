#!/bin/bash

EXT_VAULT_DNSNAME="vault.vigne.com.br"
EXT_VAULT_IPADDR="200.222.222.222"
EXT_K8S_DNSNAME="k3s.vigne.com.br"
TOKEN_REVIEWER_JWT="eyJhbGciOiJSUzI1NiIsImtpZCI6InB1YmxpYy1rZXktMSIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJrdWJlcm5ldGVzL3NlcnZpY2VhY2NvdW50Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9uYW1lc3BhY2UiOiJrdWJlLXN5c3RlbSIsImt1YmVybmV0ZXMuaW8vc2VydmljZWFjY291bnQvc2VydmljZS1hY2NvdW50Lm5hbWUiOiJyZXZpZXdlciIsImt1YmVybmV0ZXMuaW8vc2VydmljZWFjY291bnQvc2VydmljZS1hY2NvdW50LnVpZCI6IjE4ZjU4ZjA0LTk0NzAtNDg4NS05Njk4LWQxMDAwMDAwMDAwMCIsImt1YmVybmV0ZXMuaW8vc2VydmljZWFjY291bnQvc2VydmljZS1hY2NvdW50LnNlcnZpY2UtYWNjb3VudC51aWQiOiIxOGY1OGYwNC05NDcwLTQ4ODUtOTY5OC1kMTAwMDAwMDAwMDAiLCJzdWIiOiJzeXN0ZW06c2VydmljZWFjY291bnQ6a3ViZS1zeXN0ZW06cmV2aWV3ZXIiLCJhdWQiOlsiaHR0cHM6Ly9rdWJlcm5ldGVzLndpa2lwZWRpYS5vcmcvdGVzdC9hcGkiXSwiaWF0IjoxNzAxMjE4MDI4LCJleHAiOjE3MDEyMjE2Mjh9.CT7n7qfH7b"
POSTGRESQL_PASSWORD="postgres"
POSTGRESQL_USERNAME="postgres"
POSTGRESQL_HOST="psql.vigne.com.br"
POSTGRESQL_PORT="5432"

mkdir ~/vault
cd ~/vault
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout ~/vault/server.key -out ~/vault/server.crt \
  -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=${EXT_VAULT_DNSNAME}" \
  -addext "subjectAltName = DNS:${EXT_VAULT_DNSNAME}, IP:127.0.0.1, IP:$(hostname -I | awk '{print $1}'), IP:${EXT_VAULT_IPADDR}"

yum install -y yum-utils shadow-utils
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
yum install -y vault

cp ~/vault/server.crt /opt/vault/tls/tls.crt
cp ~/vault/server.key  /opt/vault/tls/tls.key
cp ~/vault/server.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust
systemctl restart vault

sh -c "openssl s_client -connect ${EXT_K8S_DNSNAME}:6443 -servername ${EXT_K8S_DNSNAME} </dev/null 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ~/vault/k8s.crt"
cp ~/vault/k8s.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust

vault operator init -key-shares=1 -key-threshold=1 > ~/vault/init-keys.txt
UNSEAL_KEY=$(grep "Unseal Key 1:" ~/vault/init-keys.txt | awk '{print $4}')
vault operator unseal "$UNSEAL_KEY"
ROOT_TOKEN=$(grep "Initial Root Token:" ~/vault/init-keys.txt | cut -d' ' -f4-)
vault login "$ROOT_TOKEN"

vault auth enable -path k3s-vigne-com-br kubernetes

cd ~/vault

vault write auth/k3s-vigne-com-br/config \
  kubernetes_host="https://k3s.vigne.com.br:6443" \
  disable_local_ca_jwt=true \
  disable_iss_validation=true \
  kubernetes_ca_cert=@k8s.crt \
  token_reviewer_jwt=$TOKEN_REVIEWER_JWT

vault secrets enable -path pki-k3s-vigne-com-br pki

vault secrets tune -max-lease-ttl=8760h pki-k3s-vigne-com-br

vault write pki-k3s-vigne-com-br/root/generate/internal \
  common_name=lab.vigne.com.br ttl=8760h

vault write pki-k3s-vigne-com-br/config/urls \
  issuing_certificates="http://vault.vigne.com.br:8200/v1/pki/ca" \
  crl_distribution_points="http://vault.vigne.com.br:8200/v1/pki/crl"

vault write pki-k3s-vigne-com-br/roles/lab-vigne-com-br \
  allowed_domains=lab.vigne.com.br \
  allow_subdomains=true max_ttl=8760h

vault secrets enable -path=secret-k3s-vigne-com-br kv-v2

vault kv put secret-k3s-vigne-com-br/data/app1/app-secret user="paulo" pass="super_secret_pass"
vault kv put secret-k3s-vigne-com-br/data/app2/app-secret user="vigne" pass="super_secret_pass"

vault secrets enable -path pgsql-vigne-com-br database

vault write pgsql-vigne-com-br/config/goapp \
     plugin_name=postgresql-database-plugin \
     connection_url="postgresql://{{username}}:{{password}}@${POSTGRESQL_HOST}:${POSTGRESQL_PORT}/goapp?sslmode=disable" \
     allowed_roles="goapp" \
     username="${POSTGRESQL_USERNAME}" \
     password="${POSTGRESQL_PASSWORD}"

tee goapp-cre.sql <<EOF
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT ALL PRIVILEGES ON SCHEMA public TO "{{name}}";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "{{name}}";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "{{name}}";
EOF

tee goapp-rev.sql <<EOF
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM "{{name}}";
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM "{{name}}";
REVOKE ALL PRIVILEGES ON SCHEMA public FROM "{{name}}";
DROP ROLE "{{name}}";
EOF

vault write pgsql-vigne-com-br/roles/goapp db_name=goapp \
         creation_statements=@goapp-cre.sql \
         revocation_statements=@goapp-rev.sql \
         default_ttl=600 \
         max_ttl=600


cat >  ~/vault/k3s-vigne-com-br-policy.hcl <<EOF
path "pki-k3s-vigne-com-br/issue/lab-vigne-com-br" {
  capabilities = ["create", "update"]
}
path "pki-k3s-vigne-com-br/cert/*" {
  capabilities = ["read"]
}
path "secret-k3s-vigne-com-br/*" {
  capabilities = ["read"]
}
path "pgsql-vigne-com-br/creds/goapp" {
  capabilities = ["read"]
}
EOF

vault policy write k3s-vigne-com-br  ~/vault/k3s-vigne-com-br-policy.hcl

vault write auth/k3s-vigne-com-br/role/k3s-vigne-com-br \
  bound_service_account_names="vault-vso,vault-eso" \
  bound_service_account_namespaces="*" \
  alias_name_source="serviceaccount_name" \
  policies="default,k3s-vigne-com-br" \
  audience=k3s-vigne-com-br \
  ttl=2h