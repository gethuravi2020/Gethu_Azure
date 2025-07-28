#!/bin/bash

# This script sets up a comprehensive multi-cluster Istio service mesh on Azure Kubernetes Service (AKS).
# It creates two AKS clusters within the same Azure Virtual Network (shared network model)
# and deploys Istio manually using a shared root Certificate Authority (CA) for mTLS.
# Necessary Azure Network Security Group (NSG) rules are dynamically added to enable
# East-West gateway communication between clusters.
# A sample application is deployed and configured with traffic management to demonstrate
# cross-cluster routing.

# IMPORTANT:
# - This script assumes a brand new Azure subscription or an empty resource group.
# - Ensure you have Azure CLI, kubectl, Helm, and istioctl installed and configured.
# - This script is designed for a shared network setup where AKS clusters are in the same VNet.
# - The East-West gateways are configured as LoadBalancer services for robust cross-cluster communication.
# - A stable Kubernetes version (1.29.7) is used. Adjust if needed.
# - The Istio version is set to 1.21.0. Ensure your installed 'istioctl' matches this version.
# - This version introduces Azure Application Gateway with WAF for external access.

set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Fail if any command in a pipeline fails

# --- Configuration Variables ---
RESOURCE_GROUP="rg-aks-istio-multicluster-06"
LOCATION="westeurope" # Choose an Azure region close to you
VNET_NAME="aks-istio-vnet"
VNET_ADDRESS_PREFIX="10.1.0.0/16"
SUBNET1_NAME="aks-subnet-c1"
SUBNET1_ADDRESS_PREFIX="10.1.0.0/24"
SUBNET2_NAME="aks-subnet-c2"
SUBNET2_ADDRESS_PREFIX="10.1.1.0/24"
APP_GW_SUBNET_NAME="appgw-subnet"
APP_GW_SUBNET_ADDRESS_PREFIX="10.1.2.0/24" # Dedicated subnet for Application Gateway

CLUSTER1_NAME="aks-istio-c1"
CLUSTER2_NAME="aks-istio-c2"
K8S_VERSION="1.32.5" # Stable Kubernetes version for AKS
ISTIO_VERSION="1.21.0" # Recommended Istio version, ensure istioctl matches this
AKS_NODE_VM_SIZE="Standard_DS2_v2" # Increased VM size for Istio control plane stability

# Istio Mesh Configuration
MESH_ID="mesh1"
CLUSTER1_MESH_NAME="cluster1"
CLUSTER2_MESH_NAME="cluster2"
NETWORK_NAME="network1" # Logical network name for Istio

# Application Gateway Configuration
APP_GW_NAME="istio-app-gateway"
APP_GW_SKU="WAF_v2" # WAF_v2 for WAF capability
APP_GW_TIER="WAF" # Matches the SKU tier
APP_GW_CAPACITY_MIN=2 # Minimum instances for WAF_v2
APP_GW_CAPACITY_MAX=5 # Maximum instances for WAF_v2
APP_GW_FRONTEND_IP_NAME="appGwPublicIp"
APP_GW_LISTENER_NAME="appGwHttpsListener"
APP_GW_BACKEND_POOL_NAME="istioBackendPool"
APP_GW_HTTP_SETTING_NAME="istioHttpSetting"
APP_GW_RULE_NAME="appGwRoutingRule"

# Certificate for Application Gateway (YOU MUST PROVIDE THIS)
# This should be the path to your PFX certificate file.
# The certificate must include the private key and be password-protected.
mkdir -p app-gw # Added -p for idempotent creation
APP_GW_CERT_PATH="./app-gw/certificate.pfx" # <--- IMPORTANT: Update this path!
APP_GW_CERT_PASSWORD="Passw0rd1!" # <--- IMPORTANT: Update this password!
# For testing, you can generate a self-signed PFX:
# openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout key.pem -out cert.pem -subj "/CN=mydomain.com/O=myOrg"
# openssl pkcs12 -export -out "$APP_GW_CERT_PATH" -inkey key.pem -in cert.pem -name "MyCert" -passout pass:"$APP_GW_CERT_PASSWORD"

# Application Configuration
APP_NAMESPACE="demo-istio-app"
APP_NAME="hello-world"
SVC_NAME="hello-world-svc"
GATEWAY_NAME="hello-world-gateway"
VS_NAME="hello-world-vs"
DR_NAME="hello-world-dr"

# --- WAF Policy Configuration ---
WAF_POLICY_NAME="${APP_GW_NAME}-waf-policy" # Using a consistent naming convention based on AG name
WAF_POLICY_TYPE="OWASP"
WAF_POLICY_VERSION="3.2" # You can choose 3.1, 3.2, or DRS

# --- Istio Ingress Gateway Cluster IP (Obtain this after Istio deployment) ---
# IMPORTANT: You MUST get the ClusterIP of your Istio Ingress Gateway Service.
# Example command: kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.spec.clusterIP}' --context=$CLUSTER1_CONTEXT_NAME
# For this script to run successfully, you need to assign the correct IP here.
# For demonstration purposes, using a placeholder. Replace it!
INGRESS_GW_CLUSTER_IP="10.0.137.31" # <--- IMPORTANT: REPLACE WITH YOUR ACTUAL ISTIO INGRESS GATEWAY CLUSTER IP

echo "--- Starting Application Gateway Deployment Script ---"
echo "Resource Group: $RESOURCE_GROUP"
echo "Application Gateway Name: $APP_GW_NAME"
echo "Location: $LOCATION"
echo "VNet Name: $VNET_NAME"
echo "Subnet Name: $APP_GW_SUBNET_NAME"
echo "SKU: $APP_GW_SKU"
echo "Capacity: $APP_GW_CAPACITY_MIN"
echo "Public IP Name: $APP_GW_FRONTEND_IP_NAME"
echo "WAF Policy Name: $WAF_POLICY_NAME"
echo "Istio Ingress Gateway IP (placeholder, ensure correct): $INGRESS_GW_CLUSTER_IP"
echo "Certificate Path: $APP_GW_CERT_PATH"

# --- Step 1: Create WAF Policy ---
echo "--- Creating WAF Policy ($WAF_POLICY_NAME) ---"
az network application-gateway waf-policy create \
    --name "$WAF_POLICY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --type "$WAF_POLICY_TYPE" \
    --version "$WAF_POLICY_VERSION"
if [ $? -ne 0 ]; then echo "Failed to create WAF policy. Exiting."; exit 1; fi

# --- Step 2: Create Public IP for Application Gateway ---
echo "--- Creating Public IP for Application Gateway ($APP_GW_FRONTEND_IP_NAME) ---"
az network public-ip create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_GW_FRONTEND_IP_NAME" \
    --location "$LOCATION" \
    --allocation-method Static \
    --sku Standard \
    --zones 1 2 3 # Use availability zones for resilience
if [ $? -ne 0 ]; then echo "Failed to create Public IP. Exiting."; exit 1; fi

# --- Step 3: Create Application Gateway with WAF_v2 SKU and initial configuration ---
# This command now includes --priority 1 for its default rule, resolving the previous error.
echo "--- Creating Application Gateway ($APP_GW_NAME) with WAF_v2 SKU ---"
az network application-gateway create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_GW_NAME" \
    --location "$LOCATION" \
    --vnet-name "$VNET_NAME" \
    --subnet "$APP_GW_SUBNET_NAME" \
    --sku "$APP_GW_SKU" \
    --capacity "$APP_GW_CAPACITY_MIN" \
    --public-ip-address "$APP_GW_FRONTEND_IP_NAME" \
    --waf-policy "$WAF_POLICY_NAME" \
    --zones 1 2 3 \
    --tags Purpose=IstioIngressWAF \
    --priority 1 \
    --no-wait # Continue script while App Gateway deploys (takes time)
if [ $? -ne 0 ]; then echo "Failed to initiate Application Gateway creation. Exiting."; exit 1; fi

echo "--- Waiting for Application Gateway to provision (this can take several minutes) ---"
az network application-gateway wait --name "$APP_GW_NAME" --resource-group "$RESOURCE_GROUP" --created
if [ $? -ne 0 ]; then echo "Application Gateway did not provision successfully. Exiting."; exit 1; fi
echo "--- Application Gateway ($APP_GW_NAME) provisioned. ---"

# --- Step 4: Upload Certificate to Application Gateway ---
echo "--- Uploading Certificate to Application Gateway ---"
# IMPORTANT: Ensure your certificate.pfx file exists at APP_GW_CERT_PATH
if [ ! -f "$APP_GW_CERT_PATH" ]; then
    echo "Error: Certificate file not found at $APP_GW_CERT_PATH. Please generate or place your PFX file there."
    echo "Refer to the script comments for generating a self-signed cert for testing."
    exit 1
fi

az network application-gateway ssl-cert create \
    --gateway-name "$APP_GW_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name "appGwCert" \
    --cert-file "$APP_GW_CERT_PATH" \
    --cert-password "$APP_GW_CERT_PASSWORD"
if [ $? -ne 0 ]; then echo "Failed to upload SSL certificate. Exiting."; exit 1; fi

# --- Step 5: Adding HTTPS Listener to Application Gateway ---
echo "--- Adding HTTPS Listener to Application Gateway ($APP_GW_LISTENER_NAME) ---"
az network application-gateway http-listener create \
    --gateway-name "$APP_GW_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_GW_LISTENER_NAME" \
    --frontend-ip "$APP_GW_FRONTEND_IP_NAME" \
    --frontend-port 443 \
    --ssl-cert "appGwCert" \
    --host-names "*" # Use your actual domain name if you have one, e.g., "yourdomain.com"
    # If using a specific domain, replace "*" with your domain.
    # If using multiple domains, use --host-names "domain1.com" "domain2.com"
if [ $? -ne 0 ]; then echo "Failed to create HTTPS listener. Exiting."; exit 1; fi

# --- Step 6: Creating Backend Pool for Istio Ingress Gateway ---
echo "--- Creating Backend Pool for Istio Ingress Gateway ($APP_GW_BACKEND_POOL_NAME) ---"
az network application-gateway address-pool create \
    --gateway-name "$APP_GW_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_GW_BACKEND_POOL_NAME" \
    --servers "$INGRESS_GW_CLUSTER_IP" # Point to the internal ClusterIP of Istio Ingress Gateway
if [ $? -ne 0 ]; then echo "Failed to create backend pool. Exiting."; exit 1; fi

# --- Step 7: Creating HTTP Setting for Backend Pool (HTTP to Istio Ingress Gateway) ---
echo "--- Creating HTTP Setting for Backend Pool ($APP_GW_HTTP_SETTING_NAME) ---"
az network application-gateway http-settings create \
    --gateway-name "$APP_GW_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_GW_HTTP_SETTING_NAME" \
    --port 80 \
    --protocol Http \
    --cookie-based-affinity Disabled \
    --timeout 30
if [ $? -ne 0 ]; then echo "Failed to create HTTP settings. Exiting."; exit 1; fi

# --- Step 8: Creating Request Routing Rule for HTTPS Listener ---
# This rule will handle traffic coming to the HTTPS listener and route it to Istio.
# We give it a priority (e.g., 10) to ensure it's processed.
echo "--- Creating Request Routing Rule ($APP_GW_RULE_NAME) ---"
az network application-gateway rule create \
    --gateway-name "$APP_GW_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_GW_RULE_NAME" \
    --http-listener "$APP_GW_LISTENER_NAME" \
    --backend-address-pool "$APP_GW_BACKEND_POOL_NAME" \
    --http-settings "$APP_GW_HTTP_SETTING_NAME" \
    --rule-type Basic \
    --priority 10 # Assign a priority to this rule. Lower numbers are higher priority.
if [ $? -ne 0 ]; then echo "Failed to create request routing rule. Exiting."; exit 1; fi

echo "--- Application Gateway setup complete! ---"
echo "You can now check the status and public IP of your Application Gateway in the Azure portal."
echo "Public IP for Application Gateway: $(az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$APP_GW_FRONTEND_IP_NAME" --query ipAddress -o tsv)"

#!/bin/bash

# This script sets up a comprehensive multi-cluster Istio service mesh on Azure Kubernetes Service (AKS).
# It creates two AKS clusters within the same Azure Virtual Network (shared network model)
# and deploys Istio manually using a shared root Certificate Authority (CA) for mTLS.
# Necessary Azure Network Security Group (NSG) rules are dynamically added to enable
# East-West gateway communication between clusters.
# A sample application is deployed and configured with traffic management to demonstrate
# cross-cluster routing.

# IMPORTANT:
# - This script assumes a brand new Azure subscription or an empty resource group.
# - Ensure you have Azure CLI, kubectl, Helm, and istioctl installed and configured.
# - This script is designed for a shared network setup where AKS clusters are in the same VNet.
# - The East-West gateways are configured as LoadBalancer services for robust cross-cluster communication.
# - A stable Kubernetes version (1.29.7) is used. Adjust if needed.
# - The Istio version is set to 1.21.0. Ensure your installed 'istioctl' matches this version.
# - This version introduces Azure Application Gateway with WAF for external access.

set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Fail if any command in a pipeline fails

# --- Configuration Variables ---
RESOURCE_GROUP="rg-aks-istio-multicluster-06"
LOCATION="westeurope" # Choose an Azure region close to you
VNET_NAME="aks-istio-vnet"
VNET_ADDRESS_PREFIX="10.1.0.0/16"
SUBNET1_NAME="aks-subnet-c1"
SUBNET1_ADDRESS_PREFIX="10.1.0.0/24"
SUBNET2_NAME="aks-subnet-c2"
SUBNET2_ADDRESS_PREFIX="10.1.1.0/24"
APP_GW_SUBNET_NAME="appgw-subnet"
APP_GW_SUBNET_ADDRESS_PREFIX="10.1.2.0/24" # Dedicated subnet for Application Gateway

CLUSTER1_NAME="aks-istio-c1"
CLUSTER2_NAME="aks-istio-c2"
K8S_VERSION="1.32.5" # Stable Kubernetes version for AKS
ISTIO_VERSION="1.21.0" # Recommended Istio version, ensure istioctl matches this
AKS_NODE_VM_SIZE="Standard_DS2_v2" # Increased VM size for Istio control plane stability

# Istio Mesh Configuration
MESH_ID="mesh1"
CLUSTER1_MESH_NAME="cluster1"
CLUSTER2_MESH_NAME="cluster2"
NETWORK_NAME="network1" # Logical network name for Istio

# Application Gateway Configuration
APP_GW_NAME="istio-app-gateway"
APP_GW_SKU="WAF_v2" # WAF_v2 for WAF capability
APP_GW_TIER="WAF"
APP_GW_CAPACITY_MIN=2 # Minimum instances for WAF_v2
APP_GW_CAPACITY_MAX=5 # Maximum instances for WAF_v2
APP_GW_FRONTEND_IP_NAME="appGwPublicIp"
APP_GW_LISTENER_NAME="appGwHttpsListener"
APP_GW_BACKEND_POOL_NAME="istioBackendPool"
APP_GW_HTTP_SETTING_NAME="istioHttpSetting"
APP_GW_RULE_NAME="appGwRoutingRule"

# Certificate for Application Gateway (YOU MUST PROVIDE THIS)
# This should be the path to your PFX certificate file.
# The certificate must include the private key and be password-protected.
mkdir app-gw
APP_GW_CERT_PATH="./app-gw/certificate.pfx" # <--- IMPORTANT: Update this path!
APP_GW_CERT_PASSWORD="Passw0rd1!" # <--- IMPORTANT: Update this password!
# For testing, you can generate a self-signed PFX:
# openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout key.pem -out cert.pem -subj "/CN=mydomain.com/O=myOrg"
# openssl pkcs12 -export -out "$APP_GW_CERT_PATH" -inkey key.pem -in cert.pem -name "MyCert" -passout pass:"$APP_GW_CERT_PASSWORD"

# Application Configuration
APP_NAMESPACE="demo-istio-app"
APP_NAME="hello-world"
SVC_NAME="hello-world-svc"
GATEWAY_NAME="hello-world-gateway"
VS_NAME="hello-world-vs"
DR_NAME="hello-world-dr"

# --- Prerequisites Check ---
echo "--- Checking prerequisites (Azure CLI, kubectl, Helm, istioctl) ---"
command -v az >/dev/null 2>&1 || { echo >&2 "Azure CLI is not installed. Aborting."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo >&2 "kubectl is not installed. Aborting."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo >&2 "Helm is not installed. Aborting."; exit 1; }
command -v istioctl >/dev/null 2>&1 || { echo >&2 "istioctl is not installed. Aborting."; exit 1; }

# Check istioctl version
CURRENT_ISTIOCTL_VERSION=$(istioctl version --remote=false | grep "Istio Control Plane" | awk '{print $NF}')
if [[ "$CURRENT_ISTIOCTL_VERSION" != *"$ISTIO_VERSION"* ]]; then
    echo "WARNING: istioctl version ($CURRENT_ISTIOCTL_VERSION) does not match desired ISTIO_VERSION ($ISTIO_VERSION)."
    echo "It is highly recommended to use a matching istioctl version."
    echo "You can download it with: curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -"
    echo "Then add to PATH: export PATH=\"\$PATH:\$(pwd)/istio-${ISTIO_VERSION}/bin\""
    read -p "Do you want to continue anyway? (y/N): " choice
    [[ "$choice" != [yY] ]] && exit 1
fi

# Check if PFX certificate path is updated
if [ "$APP_GW_CERT_PATH" = "./path/to/your/certificate.pfx" ]; then
    echo "ERROR: Please update APP_GW_CERT_PATH and APP_GW_CERT_PASSWORD in the script with your actual PFX certificate details."
    echo "You can generate a self-signed certificate for testing purposes using the openssl commands commented in the script."
    exit 1
fi
if [ ! -f "$APP_GW_CERT_PATH" ]; then
    echo "ERROR: Certificate file not found at $APP_GW_CERT_PATH. Please ensure the path is correct."
    exit 1
fi


# --- 1. Azure Resource Group & Networking Setup ---
echo "--- 1. Creating Azure Resource Group: $RESOURCE_GROUP in $LOCATION ---"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

echo "--- Creating Virtual Network: $VNET_NAME with address prefix $VNET_ADDRESS_PREFIX ---"
az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefix "$VNET_ADDRESS_PREFIX"

echo "--- Creating Subnet 1: $SUBNET1_NAME with address prefix $SUBNET1_ADDRESS_PREFIX ---"
SUBNET1_ID=$(az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET1_NAME" \
    --address-prefix "$SUBNET1_ADDRESS_PREFIX" \
    --query id -o tsv)
echo "Subnet 1 ID: $SUBNET1_ID"

echo "--- Creating Subnet 2: $SUBNET2_NAME with address prefix $SUBNET2_ADDRESS_PREFIX ---"
SUBNET2_ID=$(az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET2_NAME" \
    --address-prefix "$SUBNET2_ADDRESS_PREFIX" \
    --query id -o tsv)
echo "Subnet 2 ID: $SUBNET2_ID"

echo "--- Creating Application Gateway Subnet: $APP_GW_SUBNET_NAME with address prefix $APP_GW_SUBNET_ADDRESS_PREFIX ---"
APP_GW_SUBNET_ID=$(az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$APP_GW_SUBNET_NAME" \
    --address-prefix "$APP_GW_SUBNET_ADDRESS_PREFIX" \
    --query id -o tsv)
echo "Application Gateway Subnet ID: $APP_GW_SUBNET_ID"


# --- 2. AKS Cluster Creation ---
echo "--- 2. Creating AKS Cluster 1: $CLUSTER1_NAME in subnet $SUBNET1_ID ---"
az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER1_NAME" \
    --location "$LOCATION" \
    --kubernetes-version "$K8S_VERSION" \
    --node-count 1 \
    --node-vm-size "$AKS_NODE_VM_SIZE" \
    --generate-ssh-keys \
    --network-plugin azure \
    --vnet-subnet-id "$SUBNET1_ID" \
    --enable-managed-identity \
    --yes # Auto-approve confirmation

echo "--- 2. Creating AKS Cluster 2: $CLUSTER2_NAME in subnet $SUBNET2_ID ---"
az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER2_NAME" \
    --location "$LOCATION" \
    --kubernetes-version "$K8S_VERSION" \
    --node-count 1 \
    --node-vm-size "$AKS_NODE_VM_SIZE" \
    --generate-ssh-keys \
    --network-plugin azure \
    --vnet-subnet-id "$SUBNET2_ID" \
    --enable-managed-identity \
    --yes # Auto-approve confirmation

# --- 3. Get Kubecredentials and Set Contexts ---
echo "--- 3. Getting Kubecredentials for clusters ---"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER1_NAME" --context "$CLUSTER1_MESH_NAME" --overwrite-existing
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER2_NAME" --context "$CLUSTER2_MESH_NAME" --overwrite-existing

# Set kubectl contexts for easier use
CTX1="$CLUSTER1_MESH_NAME"
CTX2="$CLUSTER2_MESH_NAME"

# --- 4. Configure NSG Rules for Cross-Cluster Communication ---
echo "--- 4. Identifying AKS Node Resource Groups and NSG names ---"
NODE_RG_C1=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER1_NAME" --query nodeResourceGroup -o tsv)
NODE_RG_C2=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER2_NAME" --query nodeResourceGroup -o tsv)

# Dynamically get the common NSG name part (e.g., aks-agentpool-XXXXXXX-nsg)
# This assumes there's only one NSG per node resource group and its name contains 'agentpool'
NSG_NAME_COMMON=$(az network nsg list --resource-group "$NODE_RG_C1" --query "[0].name" -o tsv)
echo "Node Resource Group for Cluster 1: $NODE_RG_C1"
echo "Node Resource Group for Cluster 2: $NODE_RG_C2"
echo "Common NSG Name: $NSG_NAME_COMMON"

echo "--- Adding Inbound NSG Rule for Cluster 2's East-West Gateway (port 15443) ---"
az network nsg rule create \
    --resource-group "$NODE_RG_C2" \
    --nsg-name "$NSG_NAME_COMMON" \
    --name "AllowIstioEastWestInbound" \
    --priority 100 \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --destination-port-ranges 15443 \
    --source-address-prefixes "$SUBNET1_ADDRESS_PREFIX" \
    --destination-addres