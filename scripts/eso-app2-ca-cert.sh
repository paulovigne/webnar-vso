#!/bin/bash

VAULT_DNSNAME="vault.vigne.com.br"

sh -c "openssl s_client -connect ${VAULT_DNSNAME}:8200 -servername ${VAULT_DNSNAME} </dev/null 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > vault.crt"
cp vault.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust

kubectl create secret generic vault-ca-cert-secret \
  --namespace app2 \
  --from-file=ca.crt=vault.crt