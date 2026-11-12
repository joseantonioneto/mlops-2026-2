#!/usr/bin/env bash
# Lab 4 (IMD3005 MLOps) - cria no Azure tudo que a Parte 2 do roteiro pede, de uma vez.
# Rode no Azure Cloud Shell (Bash), que ja esta logado. Tudo fica num resource group PROPRIO
# (mlops-2026-2-neto) para nao se misturar com nada que ja exista na assinatura.
# Pode ser rodado de novo: se o grupo ja foi criado por este script, continua de onde parou.
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

# Modelo ARM do Container App: 2 containers (a API e o MongoDB) no mesmo app, falando por localhost.
# (cpu vai com json() porque o ARM nao aceita decimais literais)
escrever_template() {
  cat > "$1" <<'JSON'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "appName": { "type": "string" },
    "location": { "type": "string" },
    "environmentId": { "type": "string" },
    "image": { "type": "string" },
    "appVersion": { "type": "string" },
    "wandbProject": { "type": "string" },
    "wandbModels": { "type": "string" },
    "wandbApiKey": { "type": "securestring" }
  },
  "resources": [
    {
      "type": "Microsoft.App/containerApps",
      "apiVersion": "2023-05-01",
      "name": "[parameters('appName')]",
      "location": "[parameters('location')]",
      "properties": {
        "managedEnvironmentId": "[parameters('environmentId')]",
        "workloadProfileName": "Consumption",
        "configuration": {
          "activeRevisionsMode": "Single",
          "ingress": { "external": true, "targetPort": 8000, "transport": "auto" },
          "secrets": [ { "name": "wandb-api-key", "value": "[parameters('wandbApiKey')]" } ]
        },
        "template": {
          "containers": [
            {
              "name": "api",
              "image": "[parameters('image')]",
              "resources": { "cpu": "[json('2.0')]", "memory": "4Gi" },
              "env": [
                { "name": "APP_VERSION", "value": "[parameters('appVersion')]" },
                { "name": "WANDB_PROJECT", "value": "[parameters('wandbProject')]" },
                { "name": "WANDB_MODELS", "value": "[parameters('wandbModels')]" },
                { "name": "WANDB_API_KEY", "secretRef": "wandb-api-key" },
                { "name": "MONGO_URL", "value": "mongodb://localhost:27017/" }
              ]
            },
            {
              "name": "mongo",
              "image": "mongo:7",
              "resources": { "cpu": "[json('0.5')]", "memory": "1Gi" }
            }
          ],
          "scale": { "minReplicas": 1, "maxReplicas": 1 }
        }
      }
    }
  ]
}
JSON
}

# Arquivo de parametros (a chave do W&B vai aqui, nunca na linha de comando).
# $1 = arquivo, $2 = id do environment, $3 = regiao, $4 = chave do W&B
gerar_parametros() {
  PARAM_FILE="$1" ENV_ID="$2" LOC="$3" W_KEY="$4" APP="$APP" IMAGE="$IMAGE" VERSION="$VERSION" \
  W_PROJECT="$W_PROJECT" W_MODELS="$W_MODELS" python3 - <<'PY'
import json, os
e = os.environ
valores = {
    "appName": e["APP"], "location": e["LOC"], "environmentId": e["ENV_ID"], "image": e["IMAGE"],
    "appVersion": e["VERSION"], "wandbProject": e["W_PROJECT"], "wandbModels": e["W_MODELS"],
    "wandbApiKey": e["W_KEY"],
}
doc = {
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {k: {"value": v} for k, v in valores.items()},
}
with open(e["PARAM_FILE"], "w") as f:
    json.dump(doc, f)
PY
}

main() {
  echo "== Assinatura em uso =="
  az account show --query "{nome:name, id:id}" -o table
  read -r -p "Criar os recursos NESSA assinatura, no grupo '$RG'? [s/N] " resp
  [[ "$resp" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 1; }

  RESUME=0
  if [ "$(az group exists -n "$RG")" = "true" ]; then
    TAG=$(az group show -n "$RG" --query "tags.lab" -o tsv 2>/dev/null || true)
    if [ "$TAG" != "mlops-2026-2" ]; then
      echo "ERRO: o grupo '$RG' ja existe e NAO foi criado por este script (sem a tag lab=mlops-2026-2). Nao vou mexer nele."
      echo "Troque o nome em RG, no topo do script (ou apague o grupo se ele estiver vazio e for seu)."
      exit 1
    fi
    RESUME=1
    echo "O grupo '$RG' ja foi criado por este script: vou continuar de onde parou."
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
  if [ "$RESUME" = 1 ]; then
    LOC=$(az group show -n "$RG" --query location -o tsv)
    echo "Regiao do grupo: $LOC"
    # Se o app ainda nao existe, o environment de uma tentativa anterior pode ter ficado do tipo
    # "express" (que NAO aceita 2 containers no mesmo app). Recria com o modo certo.
    if ! az containerapp show -n "$APP" -g "$RG" >/dev/null 2>&1; then
      if az containerapp env show -n "$ENV_NAME" -g "$RG" >/dev/null 2>&1; then
        echo "Recriando o environment '$ENV_NAME' no modo WorkloadProfiles (aceita sidecar) ..."
        az containerapp env delete -n "$ENV_NAME" -g "$RG" --yes --only-show-errors -o none
      fi
      echo "Criando o environment '$ENV_NAME' ..."
      az containerapp env create -n "$ENV_NAME" -g "$RG" -l "$LOC" \
        --environment-mode WorkloadProfiles --only-show-errors -o none
    fi
  else
    for reg in "${REGIOES[@]}"; do
      echo "Tentando a regiao $reg ..."
      if az group create -n "$RG" -l "$reg" --tags lab=mlops-2026-2 --only-show-errors >/dev/null 2>&1; then
        if az containerapp env create -n "$ENV_NAME" -g "$RG" -l "$reg" \
             --environment-mode WorkloadProfiles --only-show-errors >/dev/null 2>&1; then
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
  fi

  echo "Identidade e credencial do GitHub (login sem senha) ..."
  if ! az identity show -n "$IDENT" -g "$RG" >/dev/null 2>&1; then
    az identity create -n "$IDENT" -g "$RG" -l "$LOC" --only-show-errors -o none
    sleep 20   # a identidade leva alguns segundos para aparecer no diretorio
  fi
  CLIENT_ID=$(az identity show -n "$IDENT" -g "$RG" --query clientId -o tsv)
  PRINCIPAL_ID=$(az identity show -n "$IDENT" -g "$RG" --query principalId -o tsv)
  TENANT_ID=$(az account show --query tenantId -o tsv)
  SUB_ID=$(az account show --query id -o tsv)
  RG_ID=$(az group show -n "$RG" --query id -o tsv)

  N=$(az role assignment list --assignee "$PRINCIPAL_ID" --scope "$RG_ID" --query "[?roleDefinitionName=='Contributor'] | length(@)" -o tsv 2>/dev/null || echo 0)
  if [ "${N:-0}" = "0" ]; then
    az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
      --role Contributor --scope "$RG_ID" --only-show-errors -o none
  fi
  if ! az identity federated-credential show --name github-production --identity-name "$IDENT" -g "$RG" >/dev/null 2>&1; then
    az identity federated-credential create --name github-production --identity-name "$IDENT" -g "$RG" \
      --issuer "https://token.actions.githubusercontent.com" \
      --subject "repo:${GH_REPO}:environment:production" \
      --audiences "api://AzureADTokenExchange" --only-show-errors -o none
  fi

  echo "Criando o Container App '$APP' (API + MongoDB) ..."
  ENV_ID=$(az containerapp env show -n "$ENV_NAME" -g "$RG" --query id -o tsv)
  TPL=$(mktemp --suffix=.json); PRM=$(mktemp --suffix=.json); chmod 600 "$TPL" "$PRM"
  trap 'rm -f "$TPL" "$PRM"' EXIT
  escrever_template "$TPL"
  gerar_parametros "$PRM" "$ENV_ID" "$LOC" "$W_KEY"
  az deployment group validate -g "$RG" --template-file "$TPL" --parameters "@$PRM" --only-show-errors -o none
  az deployment group create -g "$RG" -n "app-$(date +%s)" --template-file "$TPL" --parameters "@$PRM" --only-show-errors -o none
  rm -f "$TPL" "$PRM"
  FQDN=$(az containerapp show -n "$APP" -g "$RG" --query properties.configuration.ingress.fqdn -o tsv)

  echo "Esperando a API subir (ela baixa o modelo do W&B; pode levar alguns minutos) ..."
  ok=0
  for _ in $(seq 60); do
    if curl -fsS "https://$FQDN/" 2>/dev/null | grep -q "\"$VERSION\""; then ok=1; break; fi
    sleep 10
  done
  if [ "$ok" = 1 ]; then echo "NO AR: $(curl -fsS "https://$FQDN/")"; else echo "Ainda nao respondeu: veja Log stream do app no portal."; fi

  cat <<EOF

=============== COPIE PARA O GITHUB (identificadores, nao sao senhas) ===============
Secrets (Settings > Secrets and variables > Actions > Secrets):
  AZURE_CLIENT_ID        = $CLIENT_ID
  AZURE_TENANT_ID        = $TENANT_ID
  AZURE_SUBSCRIPTION_ID  = $SUB_ID
Variable (aba Variables):
  APP_URL                = https://$FQDN
Environment "production" com Required reviewers. (RESOURCE_GROUP=$RG, APP_NAME=$APP)
=====================================================================================
Quando terminar o lab, apague tudo:  bash azure_cleanup.sh
EOF
}

# permite "source" no teste sem executar o main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
