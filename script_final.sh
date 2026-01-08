#!/usr/bin/env bash
set -euo pipefail

#################################
# UTILITAIRES
#################################
clean() {
  tr -d '\r'
}

#################################
# VARIABLES
#################################
RESOURCE_GROUP="rg-mlops-bank-churn"
LOCATION="${LOCATION:-}"

USER_LOWER="$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"

ACR_NAME="mlops${USER_LOWER}"
CONTAINER_APP_NAME="bank-churn"
CONTAINERAPPS_ENV="env-mlops-workshop"

IMAGE_NAME="bank-churn-api"
IMAGE_TAG="v1"
TARGET_PORT=8000

PREFERRED_REGIONS="${PREFERRED_REGIONS:-"westeurope francecentral germanywestcentral swedencentral uksouth northeurope eastus2 eastus westus3 canadacentral centralus"}"

#################################
# 0) Détection région autorisée
#################################
echo "🔍 Détection des régions autorisées..."

ALLOWED_LOCATIONS="$(
  az policy assignment list \
    --query "[].parameters.listOfAllowedLocations.value[]" \
    -o tsv 2>/dev/null | clean | tr '[:upper:]' '[:lower:]' | sort -u || true
)"

if [[ -z "$ALLOWED_LOCATIONS" ]]; then
  ALLOWED_LOCATIONS="$(
    az account list-locations \
      --query "[?metadata.regionType=='Physical'].name" \
      -o tsv | clean | tr '[:upper:]' '[:lower:]' | sort -u
  )"
fi

if [[ -z "$LOCATION" ]]; then
  for r in $PREFERRED_REGIONS; do
    if echo "$ALLOWED_LOCATIONS" | grep -qx "$r"; then
      LOCATION="$r"
      break
    fi
  done
  LOCATION="${LOCATION:-$(echo "$ALLOWED_LOCATIONS" | head -n1)}"
fi

echo "✅ Région sélectionnée : $LOCATION"

#################################
# 1) Vérifications Azure CLI
#################################
az account show >/dev/null

if ! az extension show --name containerapp >/dev/null 2>&1; then
  az extension add --name containerapp --upgrade
else
  az extension update --name containerapp 2>/dev/null || true
fi

#################################
# 2) Fournisseurs Azure
#################################
az provider register -n Microsoft.ContainerRegistry --wait
az provider register -n Microsoft.App --wait
az provider register -n Microsoft.Web --wait
az provider register -n Microsoft.OperationalInsights --wait

#################################
# 3) Groupe de ressources
#################################
# Vérifier si le groupe de ressources existe déjà
if az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  EXISTING_LOCATION="$(az group show -n "$RESOURCE_GROUP" --query location -o tsv | clean)"
  echo "ℹ️ Groupe de ressources existant trouvé dans : $EXISTING_LOCATION"
  LOCATION="$EXISTING_LOCATION"
else
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null
fi
echo "✅ Groupe de ressources prêt : $RESOURCE_GROUP ($LOCATION)"

#################################
# 4) Azure Container Registry
#################################
az acr create \
  -n "$ACR_NAME" \
  -g "$RESOURCE_GROUP" \
  --sku Basic \
  --admin-enabled true \
  -l "$LOCATION" >/dev/null || true

echo "⏳ Attente ACR..."
for i in {1..20}; do
  if az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "✅ ACR prêt"
    break
  fi
  [[ "$i" -eq 20 ]] && { echo "❌ ACR non prêt"; exit 1; }
  sleep 6
done

az acr login -n "$ACR_NAME" >/dev/null

ACR_LOGIN_SERVER="$(az acr show -n "$ACR_NAME" --query loginServer -o tsv | clean)"
ACR_USER="$(az acr credential show -n "$ACR_NAME" --query username -o tsv | clean)"
ACR_PASS="$(az acr credential show -n "$ACR_NAME" --query "passwords[0].value" -o tsv | clean)"

#################################
# 5) Build & push image
#################################
IMAGE="$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"

docker build -t "$IMAGE_NAME:$IMAGE_TAG" .
docker tag "$IMAGE_NAME:$IMAGE_TAG" "$IMAGE"
docker tag "$IMAGE_NAME:$IMAGE_TAG" "$ACR_LOGIN_SERVER/$IMAGE_NAME:latest"

docker push "$IMAGE"
docker push "$ACR_LOGIN_SERVER/$IMAGE_NAME:latest"

#################################
# 6) Log Analytics
#################################
LAW_NAME="law-mlops-${USER_LOWER}-${RANDOM}"

az monitor log-analytics workspace create \
  -g "$RESOURCE_GROUP" \
  -n "$LAW_NAME" \
  -l "$LOCATION" >/dev/null

sleep 10

LAW_ID="$(az monitor log-analytics workspace show \
  -g "$RESOURCE_GROUP" \
  -n "$LAW_NAME" \
  --query customerId -o tsv | clean)"

LAW_KEY="$(az monitor log-analytics workspace get-shared-keys \
  -g "$RESOURCE_GROUP" \
  -n "$LAW_NAME" \
  --query primarySharedKey -o tsv | clean)"

#################################
# 7) Container Apps Environment
#################################
az containerapp env create \
  -n "$CONTAINERAPPS_ENV" \
  -g "$RESOURCE_GROUP" \
  -l "$LOCATION" \
  --logs-workspace-id "$LAW_ID" \
  --logs-workspace-key "$LAW_KEY" >/dev/null || true

echo "⏳ Attente environnement Container Apps..."
for i in {1..12}; do
  STATE="$(az containerapp env show \
    -n "$CONTAINERAPPS_ENV" \
    -g "$RESOURCE_GROUP" \
    --query properties.provisioningState -o tsv | clean)"
  [[ "$STATE" == "Succeeded" ]] && break
  [[ "$i" -eq 12 ]] && { echo "❌ Env non prêt"; exit 1; }
  sleep 10
done

#################################
# 8) Déploiement application
#################################
echo "📦 Déploiement de l'application..."

if az containerapp show -n "$CONTAINER_APP_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Mise à jour de l'application existante..."
  az containerapp update \
    -n "$CONTAINER_APP_NAME" \
    -g "$RESOURCE_GROUP" \
    --image "$IMAGE"
else
  echo "Création de la nouvelle application..."
  az containerapp create \
    -n "$CONTAINER_APP_NAME" \
    -g "$RESOURCE_GROUP" \
    --environment "$CONTAINERAPPS_ENV" \
    --image "$IMAGE" \
    --target-port "$TARGET_PORT" \
    --ingress external \
    --registry-server "$ACR_LOGIN_SERVER" \
    --registry-username "$ACR_USER" \
    --registry-password "$ACR_PASS" \
    --cpu 0.5 \
    --memory 1Gi \
    --min-replicas 1 \
    --max-replicas 3
fi

#################################
# 9) URL
#################################
APP_URL="$(az containerapp show \
  -n "$CONTAINER_APP_NAME" \
  -g "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv | clean)"

echo ""
echo "=========================================="
echo "🚀 DÉPLOIEMENT RÉUSSI"
echo "=========================================="
echo "ACR : $ACR_NAME"
echo "Région : $LOCATION"
echo "URL API : https://$APP_URL"
echo "Santé : https://$APP_URL/health"
echo "Docs : https://$APP_URL/docs"
echo ""
echo "🧹 Nettoyage : az group delete -n $RESOURCE_GROUP --yes --no-wait"
echo "=========================================="