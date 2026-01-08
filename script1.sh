#!/usr/bin/env bash
set -euo pipefail
#################################
# VARIABLES DÉFINITIVES (avec auto-sélection région)
#################################
RESOURCE_GROUP="rg-mlops-bank-churn"
# Laissez LOCATION vide pour auto-sélection via politiques. Sinon, exportez LOCATION=<region>
: "${LOCATION:=}"
ACR_NAME="mlops$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"  # 100% minuscules
CONTAINER_APP_NAME="bank-churn"
CONTAINERAPPS_ENV="env-mlops-workshop"
IMAGE_NAME="bank-churn"
IMAGE_TAG="v1"
TARGET_PORT=8000

# Liste de préférences pour l'Europe principalement, puis alternatives globales
PREFERRED_REGIONS=${PREFERRED_REGIONS:-"westeurope francecentral germanywestcentral swedencentral uksouth northeurope eastus2 eastus westus3 canadacentral centralus"}

# Détecter régions autorisées (policy Allowed locations). Si rien, on utilisera la liste complète des régions physiques Azure
echo "Détection des régions autorisées par les politiques..."
ALLOWED_LOCATIONS=$(az policy assignment list --query "[?parameters.listOfAllowedLocations.value].parameters.listOfAllowedLocations.value[]" -o tsv 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]' | sort -u || true)
if [ -z "${ALLOWED_LOCATIONS}" ]; then
  # Pas de policy explicite retournée, récupérer toutes les régions physiques comme fallback
  ALLOWED_LOCATIONS=$(az account list-locations --query "[?metadata.regionType=='Physical'].name" -o tsv | tr -d '\r' | tr '[:upper:]' '[:lower:]' | sort -u)
fi

# Choisir LOCATION si non fournie
if [ -z "${LOCATION}" ]; then
  CHOSEN=""
  for r in ${PREFERRED_REGIONS}; do
    if echo "${ALLOWED_LOCATIONS}" | grep -q "^${r}$"; then CHOSEN="$r"; break; fi
  done
  if [ -z "$CHOSEN" ]; then
    CHOSEN=$(echo "${ALLOWED_LOCATIONS}" | head -n1)
  fi
  LOCATION="$CHOSEN"
fi

if ! echo "${ALLOWED_LOCATIONS}" | grep -q "^${LOCATION}$"; then
  echo "⚠️ La région demandée LOCATION='${LOCATION}' ne figure pas dans les régions autorisées."
  echo "   Régions autorisées détectées: ${ALLOWED_LOCATIONS//$'\n'/, }"
  echo "   Je bascule sur une région autorisée disponible."
  LOCATION=$(echo "${ALLOWED_LOCATIONS}" | head -n1)
fi

echo "Région sélectionnée: ${LOCATION}"
echo "Préférences: ${PREFERRED_REGIONS}"
echo "Autorisé (extrait): $(echo "${ALLOWED_LOCATIONS}" | tr '\n' ' ' | cut -c1-200) ..."

#################################
# 0) Contexte Azure + Vérification Extensions
#################################
echo "Vérification du contexte Azure..."
az account show --query "{name:name, cloudName:cloudName}" -o json >/dev/null

echo "Vérification/installation des extensions Azure CLI..."

# # Vérifier et installer containerapp si nécessaire
# if ! az extension show --name containerapp >/dev/null 2>&1; then
#     echo "📦 Installation de l'extension containerapp..."
#     az extension add --name containerapp --upgrade -y --only-show-errors
#     echo "✅ Extension containerapp installée"
# else
#     echo "✅ Extension containerapp déjà installée"
#     # Mise à jour silencieuse
#     az extension update --name containerapp -y --only-show-errors 2>/dev/null || true
# fi

# Liste des extensions installées pour vérification
echo "Extensions installées :"
az extension list --query "[].{Name:name, Version:version}" -o table

#################################
# 1) Providers nécessaires
#################################
echo "Register providers..."
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.Web --wait
az provider register --namespace Microsoft.OperationalInsights --wait

#################################
# 2) Resource Group
#################################
echo "Création/validation du groupe de ressources..."
set +e
RG_OUT=$(az group create -n "$RESOURCE_GROUP" -l "$LOCATION" 2>&1)
RG_RC=$?
set -e
if [ $RG_RC -ne 0 ]; then
  if echo "$RG_OUT" | grep -qi "RequestDisallowedByAzure"; then
    echo "⚠️ RG bloqué en $LOCATION par policy. Recherche d'une région autorisée..."
    # Essayer autres régions autorisées
    for r in ${ALLOWED_LOCATIONS}; do
      [ "$r" = "$LOCATION" ] && continue
      set +e
      az group create -n "$RESOURCE_GROUP" -l "$r" >/dev/null 2>&1
      TRY_RC=$?
      set -e
      if [ $TRY_RC -eq 0 ]; then
        LOCATION="$r"
        echo "✅ RG créé en $LOCATION"
        break
      fi
    done
  else
    echo "$RG_OUT" >&2
    exit 1
  fi
fi
echo "✅ RG OK: $RESOURCE_GROUP (region=$LOCATION)"

#################################
# 3) Création ACR (avec vérification)
#################################
echo "Création du Container Registry (ACR) en $LOCATION..."

# Vérification préalable
if [[ ! "$ACR_NAME" =~ ^[a-z0-9]{5,50}$ ]]; then
    echo "❌ ERREUR: Nom ACR invalide: $ACR_NAME"
    echo "   Doit contenir 5-50 caractères alphanumériques en minuscules"
    exit 1
fi

echo "Nom ACR validé: $ACR_NAME (${#ACR_NAME} caractères)"

ACR_REGION="$LOCATION"
set +e
ACR_OUT=$(az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled true \
  --location "$ACR_REGION" 2>&1)
ACR_RC=$?
set -e
if [ $ACR_RC -ne 0 ]; then
  if echo "$ACR_OUT" | grep -qi "RequestDisallowedByAzure"; then
    echo "⚠️ ACR bloqué en $ACR_REGION. Recherche d'une région autorisée..."
    CREATED=0
    for r in ${ALLOWED_LOCATIONS}; do
      [ "$r" = "$ACR_REGION" ] && continue
      set +e
      az acr create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --sku Basic \
        --admin-enabled true \
        --location "$r" >/dev/null 2>&1
      TRY_RC=$?
      set -e
      if [ $TRY_RC -eq 0 ]; then
        ACR_REGION="$r"
        CREATED=1
        break
      fi
    done
    if [ $CREATED -ne 1 ]; then
      echo "❌ Impossible de créer l'ACR dans les régions autorisées. Vérifiez vos politiques."
      echo "   Régions autorisées: ${ALLOWED_LOCATIONS//$'\n'/, }"
      exit 1
    fi
  else
    echo "$ACR_OUT" >&2
    exit 1
  fi
fi

# Attendre la création complète
sleep 5
echo "✅ ACR créé : $ACR_NAME (region=$ACR_REGION)"

#################################
# 4) Login ACR + Push image
#################################
echo "Connexion au registry..."
az acr login --name "$ACR_NAME" >/dev/null

ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv | tr -d '\r')
echo "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER"

# Récupération des credentials AU BON ENDROIT
ACR_USER=$(az acr credential show -n "$ACR_NAME" --query username -o tsv | tr -d '\r')
ACR_PASS=$(az acr credential show -n "$ACR_NAME" --query "passwords[0].value" -o tsv | tr -d '\r')
IMAGE="$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"

echo "Build + Tag + Push..."
docker build -t "$IMAGE_NAME:$IMAGE_TAG" .
docker tag "$IMAGE_NAME:$IMAGE_TAG" "$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"
docker tag "$IMAGE_NAME:$IMAGE_TAG" "$ACR_LOGIN_SERVER/$IMAGE_NAME:latest"
docker push "$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"
docker push "$ACR_LOGIN_SERVER/$IMAGE_NAME:latest"
echo "✅ Image pushée dans ACR"

#################################
# 5) Log Analytics (avec retry par région)
#################################
LAW_NAME="law-mlops-$(whoami)-$RANDOM"
LAW_REGION="$LOCATION"
echo "Création Log Analytics: $LAW_NAME"
set +e
LAW_OUT=$(az monitor log-analytics workspace create -g "$RESOURCE_GROUP" -n "$LAW_NAME" -l "$LAW_REGION" 2>&1)
LAW_RC=$?
set -e
if [ $LAW_RC -ne 0 ]; then
  if echo "$LAW_OUT" | grep -qi "RequestDisallowedByAzure"; then
    echo "⚠️ LAW bloqué en $LAW_REGION. Recherche d'une région autorisée..."
    CREATED=0
    for r in ${ALLOWED_LOCATIONS}; do
      [ "$r" = "$LAW_REGION" ] && continue
      set +e
      az monitor log-analytics workspace create -g "$RESOURCE_GROUP" -n "$LAW_NAME" -l "$r" >/dev/null 2>&1
      TRY_RC=$?
      set -e
      if [ $TRY_RC -eq 0 ]; then
        LAW_REGION="$r"
        CREATED=1
        break
      fi
    done
    if [ $CREATED -ne 1 ]; then
      echo "❌ Impossible de créer LAW dans les régions autorisées."
      exit 1
    fi
  else
    echo "$LAW_OUT" >&2
    exit 1
  fi
fi
sleep 10  # Attente nécessaire

# Récupération des identifiants LAW
LAW_ID=$(az monitor log-analytics workspace show \
    --resource-group "$RESOURCE_GROUP" \
    --workspace-name "$LAW_NAME" \
    --query customerId -o tsv | tr -d '\r')

LAW_KEY=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group "$RESOURCE_GROUP" \
    --workspace-name "$LAW_NAME" \
    --query primarySharedKey -o tsv | tr -d '\r')
echo "✅ Log Analytics OK (region=$LAW_REGION)"

#################################
# 6) Container Apps Environment
#################################
echo "Création/validation Container Apps Environment: $CONTAINERAPPS_ENV"
if ! az containerapp env show -n "$CONTAINERAPPS_ENV" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  set +e
  ENV_OUT=$(az containerapp env create \
    -n "$CONTAINERAPPS_ENV" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    --logs-workspace-id "$LAW_ID" \
    --logs-workspace-key "$LAW_KEY" 2>&1)
  ENV_RC=$?
  set -e
  if [ $ENV_RC -ne 0 ]; then
    if echo "$ENV_OUT" | grep -qi "RequestDisallowedByAzure"; then
      echo "⚠️ Env Container Apps bloqué en $LOCATION. Recherche d'une région autorisée..."
      CREATED=0
      for r in ${ALLOWED_LOCATIONS}; do
        [ "$r" = "$LOCATION" ] && continue
        set +e
        az containerapp env create \
          -n "$CONTAINERAPPS_ENV" \
          -g "$RESOURCE_GROUP" \
          -l "$r" \
          --logs-workspace-id "$LAW_ID" \
          --logs-workspace-key "$LAW_KEY" >/dev/null 2>&1
        TRY_RC=$?
        set -e
        if [ $TRY_RC -eq 0 ]; then
          LOCATION="$r"
          CREATED=1
          break
        fi
      done
      if [ $CREATED -ne 1 ]; then
        echo "❌ Impossible de créer l'environnement Container Apps dans les régions autorisées."
        exit 1
      fi
    else
      echo "$ENV_OUT" >&2
      exit 1
    fi
  fi
fi
echo "✅ Environment OK (region=$LOCATION)"

#################################
# 7) Déploiement Container App
#################################
echo "Déploiement Container App: $CONTAINER_APP_NAME"
if az containerapp show -n "$CONTAINER_APP_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az containerapp update \
    -n "$CONTAINER_APP_NAME" \
    -g "$RESOURCE_GROUP" \
    --image "$IMAGE" \
    --registry-server "$ACR_LOGIN_SERVER" \
    --registry-username "$ACR_USER" \
    --registry-password "$ACR_PASS" >/dev/null
else
  az containerapp create \
    -n "$CONTAINER_APP_NAME" \
    -g "$RESOURCE_GROUP" \
    --environment "$CONTAINERAPPS_ENV" \
    --image "$IMAGE" \
    --ingress external \
    --target-port "$TARGET_PORT" \
    --registry-server "$ACR_LOGIN_SERVER" \
    --registry-username "$ACR_USER" \
    --registry-password "$ACR_PASS" \
    --min-replicas 1 \
    --max-replicas 1 >/dev/null
fi
echo "✅ Container App OK"

#################################
# 8) URL API
#################################
APP_URL=$(az containerapp show -n "$CONTAINER_APP_NAME" -g "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv | tr -d '\r')

echo ""
echo "=========================================="
echo "✅ DÉPLOIEMENT RÉUSSI"
echo "=========================================="
echo "ACR      : $ACR_NAME"
echo "Region   : $LOCATION"
echo "Resource Group: $RESOURCE_GROUP"
echo ""
echo "URLs de l'application :"
echo "  API      : https://$APP_URL"
echo "  Health   : https://$APP_URL/health"
echo "  Docs     : https://$APP_URL/docs"
echo ""
echo "Pour supprimer toutes les ressources :"
echo "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo "=========================================="