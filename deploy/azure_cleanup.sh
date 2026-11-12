#!/usr/bin/env bash
# Lab 4 - apaga SO o resource group criado pelo azure_setup.sh (e tudo que esta dentro dele).
#   curl -fsSL https://raw.githubusercontent.com/joseantonioneto/mlops-2026-2/main/deploy/azure_cleanup.sh -o azure_cleanup.sh
#   bash azure_cleanup.sh
set -euo pipefail
RG="mlops-2026-2-neto"

if [ "$(az group exists -n "$RG")" != "true" ]; then echo "O grupo '$RG' nao existe (ja foi apagado?)."; exit 0; fi

# trava de seguranca: so apaga se o grupo foi criado pelo nosso script (tag lab=mlops-2026-2)
TAG=$(az group show -n "$RG" --query "tags.lab" -o tsv 2>/dev/null || true)
if [ "$TAG" != "mlops-2026-2" ]; then
  echo "RECUSADO: o grupo '$RG' nao tem a tag lab=mlops-2026-2, entao nao foi criado pelo azure_setup.sh."
  exit 1
fi

az group show -n "$RG" --query "{nome:name, regiao:location}" -o table
az resource list -g "$RG" --query "[].{recurso:name, tipo:type}" -o table
read -r -p "APAGAR o grupo '$RG' e tudo dentro dele? [s/N] " resp
[[ "$resp" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 1; }
az group delete -n "$RG" --yes
echo "Apagado. Confira: az group exists -n $RG  (deve imprimir false)"
