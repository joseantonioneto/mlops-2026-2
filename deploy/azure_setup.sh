#!/usr/bin/env bash
# Lab 4 (IMD3005 MLOps) - cria no Azure tudo que a Parte 2 do roteiro pede, de uma vez.
# Rode no Azure Cloud Shell (Bash), que ja esta logado. Tudo fica num resource group PROPRIO
# (mlops-2026-2-neto) para nao se misturar com nada que ja exista na assinatura.
#
#   curl -fsSL https://raw.githubusercontent.com/joseantonioneto/mlops-2026-2/main/deploy/azure_setup.sh -o azure_setup.sh
#   bash azure_setup.sh
set -euo pipefail

RG="mlops-2026-2-neto"
APP="intent-clf2"
ENV_NAME="mlops-env-neto"
IDENT="github-deploy-neto"
GH_REPO="joseantonioneto/mlops-2026-2"
IMAGE="ghcr.io/joseantonioneto/mlops-2026-2:v1.0.0"
VERSION="v1.0.0"
W_PROJECT="mlops-2026-2"
W_MODELS="tomsouzneto-ufrn/mlops-2026-2/confusion-clf:v0"
# o plano Students so libera algumas regioes: o script tenta uma por vez ate uma servir
REGIOES=(brazilsouth eastus2 centralus canadacentral westus3 southcentralus eastus northeurope westeurope swedencentral)

# Gera o YAML do Container App: 2 containers (a API e o MongoDB) no mesmo app, falando por localhost.
# $1 = id do environment, $2 = regiao, $3 = chave do W&B (vira "secret" do app)
gerar_yaml() {
  cat <<EOF
location: $2
properties:
  managedEnvironmentId: $1
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: true
      targetPort: 8000
      transport: auto
    secrets:
      - name: wandb-api-key
        value: "$3"
  template:
    containers:
      - name: api
        image: ${IMAGE}
        resources:
          cpu: 2.0
          memory: 4Gi
        env:
          - name: APP_VERSION
            value: ${VERSION}
          - name: WANDB_PROJECT
            value: ${W_PROJECT}
          - name: WANDB_MODELS
            value: ${W_MODELS}
          - name: WANDB_API_KEY
            secretRef: wandb-api-key
          - name: MONGO_URL
            value: mongodb://localhost:27017/
      - name: mongo
        image: mongo:7
        resources:
          cpu: 0.5
          memory: 1Gi
    scale:
      minReplicas: 1
      maxReplicas: 1
EOF
}

main() {
  echo "== Assinatura em uso =="
  az account show --query "{nome:name, id:id}" -o table
  read -r -p "Criar os recursos NESSA assinatura, no grupo '$RG'? [s/N] " resp
  [[ "$resp" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 1; }

  if [ "$(az group exists -n "$RG")" = "true" ]; then
    echo "ERRO: o grupo '$RG' ja existe. Nao vou mexer nele. Troque o nome em RG, no topo do script."
    exit 1
  fi

  read -r -s -p "Cole a chave de API do W&B (nao aparece na tela) e tecle Enter: " W_KEY; echo
  W_KEY=$(printf '%s' "$W_KEY" | tr -d '\r\n\t ')
  [ -n "$W_KEY" ] || { echo "Chave vazia."; exit 1; }

  for p in Microsoft.App Microsoft.OperationalInsights; do
    s=$(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null || echo NotRegistered)
    if [ "$s" != "Registered" ]; then echo "Registrando $p ..."; az provider register -n "$p" --wait; fi
  done
  az extension add --name containerapp --upgrade -y --only-show-errors >/dev/null

  LOC=""
  for reg in "${REGIOES[@]}"; do
    echo "Tentando a regiao $reg ..."
    if az group create -n "$RG" -l "$reg" --tags lab=mlops-2026-2 --only-show-errors >/dev/null 2>&1; then
      if az containerapp env create -n "$ENV_NAME" -g "$RG" -l "$reg" --only-show-errors >/dev/null 2>&1; then
        LOC="$reg"; break
      fi
      echo "  (Container Apps indisponivel em $reg para esta assinatura)"
      # so apaga o grupo que ESTE script acabou de criar (conferimos acima que nao existia)
      az group delete -n "$RG" --yes --only-show-errors >/dev/null 2>&1 || true
    else
      echo "  (regiao nao permitida nesta assinatura)"
    fi
  done
  [ -n "$LOC" ] || { echo "Nenhuma regiao serviu. Veja Policy > Allowed locations no portal."; exit 1; }
  echo "Regiao escolhida: $LOC"

  echo "Criando a identidade e a credencial do GitHub (login sem senha) ..."
  az identity create -n "$IDENT" -g "$RG" -l "$LOC" --only-show-errors >/dev/null
  CLIENT_ID=$(az identity show -n "$IDENT" -g "$RG" --query clientId -o tsv)
  PRINCIPAL_ID=$(az identity show -n "$IDENT" -g "$RG" --query principalId -o tsv)
  TENANT_ID=$(az account show --query tenantId -o tsv)
  SUB_ID=$(az account show --query id -o tsv)
  RG_ID=$(az group show -n "$RG" --query id -o tsv)
  sleep 20   # a identidade leva alguns segundos para aparecer no diretorio
  az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
    --role Contributor --scope "$RG_ID" --only-show-errors >/dev/null
  az identity federated-credential create --name github-production --identity-name "$IDENT" -g "$RG" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "repo:${GH_REPO}:environment:production" \
    --audiences "api://AzureADTokenExchange" --only-show-errors >/dev/null

  echo "Criando o Container App '$APP' (API + MongoDB) ..."
  ENV_ID=$(az containerapp env show -n "$ENV_NAME" -g "$RG" --query id -o tsv)
  YAML=$(mktemp); chmod 600 "$YAML"; trap 'rm -f "$YAML"' EXIT
  gerar_yaml "$ENV_ID" "$LOC" "$W_KEY" > "$YAML"
  az containerapp create -n "$APP" -g "$RG" --yaml "$YAML" --only-show-errors >/dev/null
  rm -f "$YAML"
  FQDN=$(az containerapp show -n "$APP" -g "$RG" --query properties.configuration.ingress.fqdn -o tsv)

  echo "Esperando a API subir (ela baixa o modelo do W&B; pode levar alguns minutos) ..."
  ok=0
  for _ in $(seq 60); do
    if curl -fsS "https://$FQDN/" 2>/dev/null | grep -q "\"$VERSION\""; then ok=1; break; fi
    sleep 10
  done
  [ "$ok" = 1 ] && echo "NO AR: $(curl -fsS "https://$FQDN/")" || echo "Ainda nao respondeu: veja Log stream do app no portal."

  cat <<EOF

=============== COPIE PARA O GITHUB (identificadores, nao sao senhas) ===============
Secrets (Settings > Secrets and variables > Actions > Secrets):
  AZURE_CLIENT_ID        = $CLIENT_ID
  AZURE_TENANT_ID        = $TENANT_ID
  AZURE_SUBSCRIPTION_ID  = $SUB_ID
Variable (aba Variables):
  APP_URL                = https://$FQDN
Environment "production" com Required reviewers, depois use RESOURCE_GROUP=$RG e APP_NAME=$APP
=====================================================================================
Quando terminar o lab, apague tudo:  bash azure_cleanup.sh
EOF
}

# permite "source" no teste sem executar o main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
