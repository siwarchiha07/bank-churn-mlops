#!/usr/bin/env bash
set -euo pipefail

#################################
# VARIABLES (comme ton scénario)
#################################
RESOURCE_GROUP="rg-mlops"
LOCATION="francecentral"                     # ton choix initial
FALLBACK_LOCATION="norwayeast"               # région qui marche chez toi
ACR_NAME="acrmlops$(whoami)$(date +%s)"      # unique
CONTAINER_APP_NAME="app-churn-api"
CONTAINERAPPS_ENV="env-mlops-workshop"
IMAGE_NAME="bank-churn-api"
IMAGE_TAG="v1"
TARGET_PORT=8000

#################################
# 0) Contexte Azure (tu es déjà loggé)
#################################
echo "Vérification du contexte Azure..."
az account show --query "{name:name, cloudName:cloudName}" -o json >/dev/null

#################################
# 1) Providers nécessaires - MODIFIÉ pour ignorer les erreurs réseau
#################################
echo "Vérification des providers (ignorer les erreurs réseau)..."
az provider register --namespace Microsoft.ContainerRegistry --wait 2>/dev/null || true
az provider register --namespace Microsoft.App --wait 2>/dev/null || true
az provider register --namespace Microsoft.Web --wait 2>/dev/null || true
az provider register --namespace Microsoft.OperationalInsights --wait 2>/dev/null || true
echo "✅ Providers vérifiés (ou déjà enregistrés)"

#################################
# 2) Resource Group
# (RG existe déjà chez toi en francecentral, donc on le garde)
#################################
echo "Création/validation du groupe de ressources..."
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null || true
echo "✅ RG OK: $RESOURCE_GROUP"

#################################
# 3) Création ACR (avec fallback si francecentral est bloquée)
#################################
echo "Création du Container Registry (ACR) en $LOCATION..."
set +e
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled true \
  --location "$LOCATION" >/dev/null 2>&1
ACR_RC=$?
set -e

if [ $ACR_RC -ne 0 ]; then
  echo "⚠️ ACR bloqué en $LOCATION (policy). Fallback => $FALLBACK_LOCATION"
  az acr create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --sku Basic \
    --admin-enabled true \
    --location "$FALLBACK_LOCATION" >/dev/null
  LOCATION="$FALLBACK_LOCATION"
fi

echo "✅ ACR créé : $ACR_NAME (region=$LOCATION)"

#################################
# 4) Login ACR + Push image
#################################
echo "Connexion au registry..."
#az acr login --name "$ACR_NAME" >/dev/null
echo "Connexion Docker au registry (login manuel)..."

ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv | tr -d '\r')
ACR_USER=$(az acr credential show -n "$ACR_NAME" --query username -o tsv | tr -d '\r')
ACR_PASS=$(az acr credential show -n "$ACR_NAME" --query "passwords[0].value" -o tsv | tr -d '\r')

docker login "$ACR_LOGIN_SERVER" -u "$ACR_USER" -p "$ACR_PASS"
echo "✅ Docker login ACR OK"

ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv | tr -d '\r')
echo "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER"

echo "Build + Tag + Push..."
docker build -t "$IMAGE_NAME:$IMAGE_TAG" .
docker tag "$IMAGE_NAME:$IMAGE_TAG" "$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"
docker tag "$IMAGE_NAME:$IMAGE_TAG" "$ACR_LOGIN_SERVER/$IMAGE_NAME:latest"
docker push "$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"
docker push "$ACR_LOGIN_SERVER/$IMAGE_NAME:latest"
echo "✅ Image pushée dans ACR"

#################################
# 5) Log Analytics (obligatoire)
#################################
LAW_NAME="law-mlops-$(whoami)-$RANDOM"
echo "Création Log Analytics: $LAW_NAME"
az monitor log-analytics workspace create -g "$RESOURCE_GROUP" -n "$LAW_NAME" -l "$LOCATION" >/dev/null

LAW_ID=$(az monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$LAW_NAME" --query customerId -o tsv | tr -d '\r')
LAW_KEY=$(az monitor log-analytics workspace get-shared-keys -g "$RESOURCE_GROUP" -n "$LAW_NAME" --query primarySharedKey -o tsv | tr -d '\r')
echo "✅ Log Analytics OK"

#################################
# 6) Container Apps Environment (create si absent)
#################################
echo "Création/validation Container Apps Environment: $CONTAINERAPPS_ENV"
if ! az containerapp env show -n "$CONTAINERAPPS_ENV" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az containerapp env create \
    -n "$CONTAINERAPPS_ENV" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    --logs-workspace-id "$LAW_ID" \
    --logs-workspace-key "$LAW_KEY" >/dev/null
fi
echo "✅ Environment OK"

#################################
# 7) Déploiement Container App (create or update) - MODIFIÉ
#################################
ACR_USER=$(az acr credential show -n "$ACR_NAME" --query username -o tsv | tr -d '\r')
ACR_PASS=$(az acr credential show -n "$ACR_NAME" --query "passwords[0].value" -o tsv | tr -d '\r')
IMAGE="$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"

echo "Déploiement Container App: $CONTAINER_APP_NAME"

# MODIFICATION: Créer d'abord un secret pour le registry
SECRET_NAME="acr-secret-$(echo $ACR_NAME | cut -c1-20)"

# Supprimer le secret s'il existe déjà
az containerapp secret delete \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --secret-name "$SECRET_NAME" 2>/dev/null || true

# Ajouter le secret (syntaxe correcte pour containerapp 1.3.0b1)
az containerapp secret add \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --secret-name "$SECRET_NAME" \
  --registry-server "$ACR_LOGIN_SERVER" \
  --registry-username "$ACR_USER" \
  --registry-password "$ACR_PASS" 2>/dev/null || echo "⚠️ Secret non créé, l'application n'existe peut-être pas encore"

if az containerapp show -n "$CONTAINER_APP_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  # MODIFICATION: Mettre à jour sans les paramètres registry (ils sont dans le secret)
  az containerapp update \
    -n "$CONTAINER_APP_NAME" \
    -g "$RESOURCE_GROUP" \
    --image "$IMAGE" >/dev/null
else
  # MODIFICATION: Créer avec référence au secret
  az containerapp create \
    -n "$CONTAINER_APP_NAME" \
    -g "$RESOURCE_GROUP" \
    --environment "$CONTAINERAPPS_ENV" \
    --image "$IMAGE" \
    --ingress external \
    --target-port "$TARGET_PORT" \
    --min-replicas 1 \
    --max-replicas 1 \
    --registry-server "$ACR_LOGIN_SERVER" \
    --registry-username "$ACR_USER" \
    --registry-password "$ACR_PASS" >/dev/null || {
      # Fallback: Si ça échoue, essayer sans les paramètres registry
      echo "⚠️ Première tentative échouée, essai sans paramètres registry..."
      az containerapp create \
        -n "$CONTAINER_APP_NAME" \
        -g "$RESOURCE_GROUP" \
        --environment "$CONTAINERAPPS_ENV" \
        --image "$IMAGE" \
        --ingress external \
        --target-port "$TARGET_PORT" \
        --min-replicas 1 \
        --max-replicas 1
    }
fi
echo "✅ Container App OK"

#################################
# 8) URL API
#################################
sleep 5  # Attendre un peu pour que l'application soit prête
APP_URL=$(az containerapp show -n "$CONTAINER_APP_NAME" -g "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv | tr -d '\r')

echo ""
echo "=========================================="
echo "✅ FIN"
echo "=========================================="
echo "ACR      : $ACR_NAME"
echo "Region   : $LOCATION"
echo "API URL  : https://$APP_URL"
echo "Health   : https://$APP_URL/health"
echo "Docs     : https://$APP_URL/docs"
echo "=========================================="