#!/usr/bin/env bash
# Despliegue completo de SismoWatch en Azure. Ejecutar desde Ubuntu (WSL): bash deploy.sh
# Se puede repetir sin problema: lo que ya existe se reutiliza o se actualiza.
set -euo pipefail
cd "$(dirname "$0")"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
norm() { tr -d ' ' | tr 'A-Z' 'a-z'; }

command -v az >/dev/null || die "Falta Azure CLI en Ubuntu"
docker info >/dev/null 2>&1 || die "Docker no responde. Ejecuta: sudo service docker start"
az account show >/dev/null 2>&1 || die "Sin sesion. Ejecuta: az login --use-device-code"

SUF=$(az account show --query id -o tsv | md5sum | cut -c1-6)
RG=rg-sismowatch
ACR=sismowatch$SUF
ST=sismowatch$SUF
FUNC=func-sismowatch-$SUF
ENVN=cae-sismowatch
TAG=$(date +%Y%m%d%H%M%S)

log "1/9 Proveedores y extension containerapp"
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.ContainerRegistry Microsoft.Storage Microsoft.Web; do
  az provider register --namespace "$ns" --wait
done
az extension add --name containerapp --upgrade --only-show-errors

log "2/9 Region y grupo de recursos"
CA_LOCS=$(az provider show -n Microsoft.App \
  --query "resourceTypes[?resourceType=='managedEnvironments'].locations[]" -o tsv | norm)
FLEX_LOCS=$(az functionapp list-flexconsumption-locations --query "[].name" -o tsv 2>/dev/null | norm || true)
if az group show -n "$RG" >/dev/null 2>&1; then
  LOC=$(az group show -n "$RG" --query location -o tsv)
else
  PREF="mexicocentral brazilsouth eastus2 eastus centralus southcentralus westus3 westus2 canadacentral chilecentral spaincentral francecentral northeurope westeurope uksouth swedencentral italynorth polandcentral austriaeast"
  ALL="$PREF $(echo "$CA_LOCS" | tr '\n' ' ')"
  LOC=""
  for pass in both ca; do
    for l in $ALL; do
      echo "$CA_LOCS" | grep -qx "$l" || continue
      if [ "$pass" = both ]; then
        { [ -n "$FLEX_LOCS" ] && echo "$FLEX_LOCS" | grep -qx "$l"; } || continue
      fi
      echo "probando $l ..."
      if az group create -n "$RG" -l "$l" -o none 2>/dev/null; then LOC=$l; break 2; fi
    done
  done
  [ -n "$LOC" ] || die "Ninguna region permitida soporta Container Apps. Pasame la lista de regiones de tu suscripcion."
fi
SKIP_FUNCTION=1
if [ -n "$FLEX_LOCS" ] && echo "$FLEX_LOCS" | grep -qx "$(echo "$LOC" | norm)"; then SKIP_FUNCTION=0; fi
echo "Region: $LOC (Function: $([ $SKIP_FUNCTION = 0 ] && echo si || echo no disponible))"

log "3/9 Registro de contenedores"
az acr show -n "$ACR" -g "$RG" >/dev/null 2>&1 || az acr create -g "$RG" -n "$ACR" --sku Basic -l "$LOC" -o none
az acr update -n "$ACR" --admin-enabled true -o none
ACR_USER=$(az acr credential show -n "$ACR" --query username -o tsv)
ACR_PASS=$(az acr credential show -n "$ACR" --query "passwords[0].value" -o tsv)
echo "$ACR_PASS" | docker login "$ACR.azurecr.io" -u "$ACR_USER" --password-stdin

log "4/9 Storage (cache de sismos)"
az storage account create -g "$RG" -n "$ST" -l "$LOC" --sku Standard_LRS --kind StorageV2 \
  --allow-blob-public-access false -o none
CONN=$(az storage account show-connection-string -g "$RG" -n "$ST" --query connectionString -o tsv)
az storage container create -n quakes --connection-string "$CONN" -o none

log "5/9 Azure Function (ingesta serverless)"
deploy_function() {
  az functionapp show -n "$FUNC" -g "$RG" >/dev/null 2>&1 || \
    az functionapp create -g "$RG" -n "$FUNC" --storage-account "$ST" \
      --flexconsumption-location "$LOC" --runtime python --runtime-version 3.11 -o none || return 1
  az functionapp config appsettings set -g "$RG" -n "$FUNC" \
    --settings STORAGE_CONNECTION_STRING="$CONN" -o none || return 1
  if ! command -v func >/dev/null; then
    sudo apt-get install -y nodejs npm || return 1
    sudo npm install -g azure-functions-core-tools@4 --unsafe-perm true || return 1
  fi
  (cd function && func azure functionapp publish "$FUNC" --python) || return 1
}
if [ "$SKIP_FUNCTION" = 1 ]; then
  echo "AVISO: Functions Flex no disponible en $LOC. La API usara USGS directo como respaldo."
elif ! deploy_function; then
  echo "AVISO: fallo el despliegue de la Function. La API seguira funcionando con USGS directo."
fi

log "6/9 Entorno de Container Apps"
az containerapp env show -n "$ENVN" -g "$RG" >/dev/null 2>&1 || az containerapp env create -n "$ENVN" -g "$RG" -l "$LOC" -o none

deploy_app() {  # nombre imagen puerto [args extra]
  local name=$1 image=$2 port=$3; shift 3
  if az containerapp show -n "$name" -g "$RG" >/dev/null 2>&1; then
    az containerapp update -n "$name" -g "$RG" --image "$image" -o none
  else
    az containerapp create -n "$name" -g "$RG" --environment "$ENVN" --image "$image" \
      --registry-server "$ACR.azurecr.io" --registry-username "$ACR_USER" --registry-password "$ACR_PASS" \
      --target-port "$port" --ingress external --cpu 0.25 --memory 0.5Gi \
      --min-replicas 1 --max-replicas 3 \
      --scale-rule-name http-rule --scale-rule-type http --scale-rule-http-concurrency 50 \
      "$@" -o none
  fi
}

log "7/9 API (microservicio)"
API_IMG=$ACR.azurecr.io/sismowatch-api:$TAG
docker build -t "$API_IMG" ./api && docker push "$API_IMG"
deploy_app ca-api "$API_IMG" 8000 --secrets conn="$CONN" --env-vars STORAGE_CONNECTION_STRING=secretref:conn
API_FQDN=$(az containerapp show -n ca-api -g "$RG" --query properties.configuration.ingress.fqdn -o tsv)

log "8/9 Frontend (microservicio)"
WEB_IMG=$ACR.azurecr.io/sismowatch-frontend:$TAG
docker build --build-arg API_URL="https://$API_FQDN" -t "$WEB_IMG" ./frontend && docker push "$WEB_IMG"
deploy_app ca-frontend "$WEB_IMG" 80
WEB_FQDN=$(az containerapp show -n ca-frontend -g "$RG" --query properties.configuration.ingress.fqdn -o tsv)

log "9/9 Verificacion"
for i in $(seq 1 12); do
  curl -fsS "https://$API_FQDN/health" && break || { echo "esperando API ($i/12)..."; sleep 5; }
done
echo
curl -fsS "https://$API_FQDN/api/earthquakes?period=day&min_mag=4.5" | head -c 300; echo

cat <<MSG

LISTO
  Pagina publica : https://$WEB_FQDN
  API            : https://$API_FQDN/api/earthquakes?period=day&min_mag=2.5
  Grupo recursos : $RG   Region: $LOC
  Registro (ACR) : $ACR
MSG
