#!/bin/bash

# Configuração de hosts, portas e credenciais do ambiente.
# Esses valores direcionam a instalação e a integração do Vault com o cluster K3s e o PostgreSQL.
EXT_VAULT_DNSNAME="vault.vigne.com.br"
EXT_K8S_DNSNAME="k3s.vigne.com.br"
POSTGRESQL_HOST="psql.vigne.com.br"
POSTGRESQL_PORT="5432"
POSTGRESQL_PASSWORD="postgres"
POSTGRESQL_USERNAME="postgres"
TOKEN_REVIEWER_JWT=$(cat reviewer.jwt)

# Verifica se o token do reviewer do Kubernetes foi informado corretamente.
if [ -z "$TOKEN_REVIEWER_JWT" ]; then
  echo "Error: TOKEN_REVIEWER_JWT is not set. Please ensure the reviewer.jwt file exists and contains the correct token."
  exit 1
fi

# Cria o diretório para armazenar certificados, chaves e arquivos de bootstrap do Vault.
mkdir ~/vault
cd ~/vault

# Obtém IPs interno e externo para o certificado TLS do Vault.
EXT_VAULT_IPADDR=$(dig +short ${EXT_VAULT_DNSNAME} | head -n 1)
INT_VAULT_IPADDR=$(hostname -I | awk '{print $1}')

# Gera um certificado autoassinado para o Vault com SANs para DNS e IPs relevantes.
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout ~/vault/server.key -out ~/vault/server.crt \
  -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=${EXT_VAULT_DNSNAME}" \
  -addext "subjectAltName = DNS:${EXT_VAULT_DNSNAME}, IP:127.0.0.1, IP:${INT_VAULT_IPADDR}, IP:${EXT_VAULT_IPADDR}" \
  -set_serial 1

# Instala os utilitários necessários e o Vault a partir do repositório oficial da HashiCorp.
yum install -y yum-utils shadow-utils
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
yum install -y vault

# Coloca o certificado do Vault no caminho esperado pelo serviço e atualiza a CA local.
cp ~/vault/server.crt /opt/vault/tls/tls.crt
cp ~/vault/server.key  /opt/vault/tls/tls.key
cp ~/vault/server.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust
systemctl restart vault

# Exporta o certificado público da API do Kubernetes para o Vault confiar no cluster.
sh -c "openssl s_client -connect ${EXT_K8S_DNSNAME}:6443 -servername ${EXT_K8S_DNSNAME} </dev/null 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ~/vault/k8s.crt"
cp ~/vault/k8s.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust

# Inicializa o Vault em modo de laboratório, gera as chaves de unseal e faz login com a root token.
vault operator init -key-shares=1 -key-threshold=1 > ~/vault/init-keys.txt
UNSEAL_KEY=$(grep "Unseal Key 1:" ~/vault/init-keys.txt | awk '{print $4}')
vault operator unseal "$UNSEAL_KEY"
ROOT_TOKEN=$(grep "Initial Root Token:" ~/vault/init-keys.txt | cut -d' ' -f4-)
vault login "$ROOT_TOKEN"

# Habilita o método de autenticação do Vault usando o cluster Kubernetes.
vault auth enable -path k3s-vigne-com-br kubernetes

cd ~/vault

# Configura o auth method do Kubernetes para validar tokens de serviço e certificado do cluster.
vault write auth/k3s-vigne-com-br/config \
  kubernetes_host="https://k3s.vigne.com.br:6443" \
  disable_local_ca_jwt=true \
  disable_iss_validation=true \
  kubernetes_ca_cert=@k8s.crt \
  token_reviewer_jwt=$TOKEN_REVIEWER_JWT

# Habilita a PKI interna do Vault para emissão de certificados para aplicações do domínio lab.vigne.com.br.
vault secrets enable -path pki-k3s-vigne-com-br pki

# Ajusta o TTL máximo da PKI para um ano, equivalente a 8760 horas.
vault secrets tune -max-lease-ttl=8760h pki-k3s-vigne-com-br

# Gera a CA raiz interna e define as URLs para o certificado e CRL.
vault write pki-k3s-vigne-com-br/root/generate/internal \
  common_name=lab.vigne.com.br ttl=8760h

vault write pki-k3s-vigne-com-br/config/urls \
  issuing_certificates="http://vault.vigne.com.br:8200/v1/pki/ca" \
  crl_distribution_points="http://vault.vigne.com.br:8200/v1/pki/crl"

# Role de certificados com domínio base e subdomínios permitidos.
vault write pki-k3s-vigne-com-br/roles/lab-vigne-com-br \
  allowed_domains=lab.vigne.com.br \
  allow_subdomains=true max_ttl=8760h

# Habilita o secret engine KV v2 para armazenar segredos das aplicações.
vault secrets enable -path=secret-k3s-vigne-com-br kv-v2

# Cria segredos fictícios para os apps 1 e 2.
vault kv put secret-k3s-vigne-com-br/data/app1/app-secret user="paulo" pass="super_secret_pass"
vault kv put secret-k3s-vigne-com-br/data/app2/app-secret user="vigne" pass="super_secret_pass"

# Habilita o engine de database do Vault para credenciais dinâmicas do PostgreSQL.
vault secrets enable -path pgsql-vigne-com-br database

# Configura a conexão do Vault ao PostgreSQL e define as roles permitidas para geração dinâmica.
vault write pgsql-vigne-com-br/config/goapp \
     plugin_name=postgresql-database-plugin \
     connection_url="postgresql://{{username}}:{{password}}@${POSTGRESQL_HOST}:${POSTGRESQL_PORT}/goapp?sslmode=disable" \
     allowed_roles="goapp" \
     username="${POSTGRESQL_USERNAME}" \
     password="${POSTGRESQL_PASSWORD}"

# Define o SQL de criação da role no PostgreSQL, com credencial temporária e expiração.
tee goapp-cre.sql <<EOF
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT ALL PRIVILEGES ON SCHEMA public TO "{{name}}";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "{{name}}";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "{{name}}";
EOF

# Define o SQL de revogação para remover permissões e a role ao expirar a credencial.
tee goapp-rev.sql <<EOF
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM "{{name}}";
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM "{{name}}";
REVOKE ALL PRIVILEGES ON SCHEMA public FROM "{{name}}";
DROP ROLE "{{name}}";
EOF

# Cria a role dinâmica do Vault para a aplicação goapp com TTL curto.
vault write pgsql-vigne-com-br/roles/goapp db_name=goapp \
         creation_statements=@goapp-cre.sql \
         revocation_statements=@goapp-rev.sql \
         default_ttl=600 \
         max_ttl=600


# Política para permitir que os serviços Kubernetes emitem certificados e leiam segredos e credenciais dinâmicas.
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

# Cria e registra a política no Vault.
vault policy write k3s-vigne-com-br  ~/vault/k3s-vigne-com-br-policy.hcl

# Associa a política a uma role de autenticação baseada em service accounts do Kubernetes.
vault write auth/k3s-vigne-com-br/role/k3s-vigne-com-br \
  bound_service_account_names="vault-vso,vault-eso" \
  bound_service_account_namespaces="*" \
  alias_name_source="serviceaccount_name" \
  policies="default,k3s-vigne-com-br" \
  audience=k3s-vigne-com-br \
  ttl=2h

# Prepara o diretório de auditoria e habilita logging em arquivo para rastrear operações do Vault.
sudo mkdir -p /var/log/vault
sudo chown vault:vault /var/log/vault
sudo chmod 700 /var/log/vault
vault audit enable file file_path=/var/log/vault/vault_audit.log