#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/load-vars.sh
source "${ROOT}/scripts/load-vars.sh"

export AWS_DEFAULT_REGION="${AwsRegion}"
export AWS_REGION="${AwsRegion}"
export PRODUCTOS_TABLE="${ProductosTableName}"
export CLIENTES_TABLE="${ClientesTableName}"
export CLUSTER_NAME="${ClusterName}"
if [[ -n "${AwsProfile:-}" ]]; then
  export AWS_PROFILE="${AwsProfile}"
fi
STACK_PREFIX="${ProjectName}-${Environment}"

deploy_stack() {
  local name="$1"
  local template="$2"
  shift 2
  echo "=== Deploying stack ${name} ==="
  aws cloudformation deploy \
    --stack-name "${name}" \
    --template-file "${template}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides "$@"
}

infra() {
  deploy_stack "${STACK_PREFIX}-vpc" "${ROOT}/vpc/template.yaml" \
    "Environment=${Environment}" \
    "ProjectName=${ProjectName}" \
    "VpcCidr=${VpcCidr}" \
    "ClusterName=${ClusterName}"

  deploy_stack "${STACK_PREFIX}-kms" "${ROOT}/kms/template.yaml" \
    "Environment=${Environment}" \
    "ProjectName=${ProjectName}"

  deploy_stack "${STACK_PREFIX}-dynamodb" "${ROOT}/dynamodb/template.yaml" \
    "Environment=${Environment}" \
    "ProjectName=${ProjectName}" \
    "ProductosTableName=${ProductosTableName}" \
    "ClientesTableName=${ClientesTableName}"

  local PRODUCTOS_ARN CLIENTES_ARN
  PRODUCTOS_ARN=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-dynamodb" ProductosTableArn)
  CLIENTES_ARN=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-dynamodb" ClientesTableArn)

  deploy_stack "${STACK_PREFIX}-iam" "${ROOT}/iam/template.yaml" \
    "Environment=${Environment}" \
    "ProjectName=${ProjectName}" \
    "ProductosTableArn=${PRODUCTOS_ARN}" \
    "ClientesTableArn=${CLIENTES_ARN}"

  local VPC_ID PRIVATE_SUBNETS PUBLIC_SUBNETS
  VPC_ID=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-vpc" VpcId)
  PRIVATE_SUBNETS=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-vpc" PrivateSubnetIds)
  PUBLIC_SUBNETS=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-vpc" PublicSubnetIds)
  local EKS_CLUSTER_ROLE EKS_NODE_ROLE KMS_ARN KARPENTER_POLICY FASTAPI_POLICY KARPENTER_QUEUE
  EKS_CLUSTER_ROLE=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-iam" EksClusterRoleArn)
  EKS_NODE_ROLE=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-iam" EksNodeRoleArn)
  KMS_ARN=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-kms" EksSecretsKeyArn)
  KARPENTER_POLICY=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-iam" KarpenterControllerPolicyArn)
  FASTAPI_POLICY=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-iam" FastApiDynamoDbPolicyArn)
  KARPENTER_QUEUE=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-iam" KarpenterInterruptionQueueArn)

  deploy_stack "${STACK_PREFIX}-eks" "${ROOT}/eks/template.yaml" \
    "Environment=${Environment}" \
    "ProjectName=${ProjectName}" \
    "ClusterName=${ClusterName}" \
    "KubernetesVersion=${KubernetesVersion}" \
    "VpcId=${VPC_ID}" \
    "PrivateSubnetIds=${PRIVATE_SUBNETS}" \
    "PublicSubnetIds=${PUBLIC_SUBNETS}" \
    "EksClusterRoleArn=${EKS_CLUSTER_ROLE}" \
    "EksNodeRoleArn=${EKS_NODE_ROLE}" \
    "EksSecretsKeyArn=${KMS_ARN}" \
    "KarpenterControllerPolicyArn=${KARPENTER_POLICY}" \
    "FastApiDynamoDbPolicyArn=${FASTAPI_POLICY}" \
    "KarpenterInterruptionQueueArn=${KARPENTER_QUEUE}" \
    "BootstrapInstanceType=${BootstrapInstanceTypes}" \
    "BootstrapDesiredCapacity=${BootstrapDesiredCapacity}" \
    "BootstrapMinSize=${BootstrapMinSize}" \
    "BootstrapMaxSize=${BootstrapMaxSize}" \
    "BootstrapCapacityType=${BootstrapCapacityType}"

  local NODE_SG
  NODE_SG=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-eks" NodeSecurityGroupId)

  deploy_stack "${STACK_PREFIX}-ec2" "${ROOT}/ec2/template.yaml" \
    "Environment=${Environment}" \
    "ProjectName=${ProjectName}" \
    "VpcId=${VPC_ID}" \
    "ClusterName=${ClusterName}" \
    "NodeSecurityGroupId=${NODE_SG}"
}

kubeconfig() {
  aws eks update-kubeconfig --name "${ClusterName}" --region "${AwsRegion}"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Falta '$1' en PATH. En macOS: brew install $2" >&2
    exit 127
  fi
}

platform() {
  require_cmd kubectl kubectl
  require_cmd helm helm
  require_cmd istioctl istioctl
  kubeconfig
  local KARPENTER_ROLE QUEUE_NAME
  KARPENTER_ROLE=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-eks" KarpenterControllerRoleArn)
  QUEUE_NAME=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-iam" KarpenterInterruptionQueueName)

  # 1 replica: el bootstrap MNG suele ser 1 nodo; 2 replicas falla por anti-affinity
  if helm status karpenter -n kube-system >/dev/null 2>&1; then
    status=$(helm status karpenter -n kube-system -o json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('info',{}).get('status',''))" 2>/dev/null || true)
    if [[ "$status" == "pending-install" || "$status" == "pending-upgrade" || "$status" == "pending-rollback" ]]; then
      echo "Release karpenter en estado ${status}; reinstalando..."
      helm uninstall karpenter -n kube-system --wait --timeout 5m || true
    fi
  fi
  helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
    --version "${KarpenterChartVersion}" \
    --namespace kube-system \
    --set "replicas=1" \
    --set "settings.clusterName=${ClusterName}" \
    --set "settings.interruptionQueue=${QUEUE_NAME}" \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${KARPENTER_ROLE}" \
    --wait --timeout 15m

  if ! istioctl version >/dev/null 2>&1; then
    echo "istioctl no encontrado; instala Istio ${IstioVersion} manualmente" >&2
    exit 1
  fi
  istioctl install -y -f "${ROOT}/k8s/istio/values-minimal.yaml"
  kubectl apply -f "${ROOT}/k8s/istio/gateway-internal-nlb.yaml"
  "${ROOT}/scripts/render-k8s.sh"
  kubectl apply -f "${ROOT}/.rendered/k8s/karpenter/ec2nodeclass.yaml"
  kubectl apply -f "${ROOT}/k8s/karpenter/nodepool.yaml"
}

app() {
  kubeconfig
  "${ROOT}/scripts/render-k8s.sh"
  kubectl apply -f "${ROOT}/.rendered/k8s/app/namespace.yaml"
  kubectl apply -f "${ROOT}/.rendered/k8s/app/serviceaccount.yaml"

  # Imagen local de Docker no existe en nodos EKS; usar ECR (FASTAPI_IMAGE=xxx.ecr...) o ConfigMap+python
  use_ecr_image=false
  if [[ -n "${FASTAPI_IMAGE:-}" && "${FASTAPI_IMAGE}" != "api-mercado-fastapi:latest" ]]; then
    use_ecr_image=true
  fi

  if [[ "${FASTAPI_DEPLOY:-auto}" == "docker" ]]; then
    use_ecr_image=true
    if ! docker info >/dev/null 2>&1; then
      echo "Docker no esta en ejecucion. Abre Docker Desktop o usa: FASTAPI_DEPLOY=configmap make app" >&2
      exit 1
    fi
    docker build -t "${FASTAPI_IMAGE:-api-mercado-fastapi:latest}" "${ROOT}/k8s/fastapi"
    export FASTAPI_IMAGE="${FASTAPI_IMAGE:-api-mercado-fastapi:latest}"
    echo "AVISO: sube la imagen a ECR y define FASTAPI_IMAGE con la URI del registro." >&2
    "${ROOT}/scripts/render-k8s.sh"
    kubectl apply -f "${ROOT}/.rendered/k8s/app/deployment-fastapi.yaml"
  elif [[ "${FASTAPI_DEPLOY:-auto}" == "configmap" ]] || [[ "$use_ecr_image" == "false" ]]; then
    echo "Desplegando FastAPI desde ConfigMap (python:3.12-slim, sin Docker local)..."
    kubectl create configmap fastapi-source -n api-mercado \
      --from-file=main.py="${ROOT}/k8s/fastapi/main.py" \
      --from-file=requirements.txt="${ROOT}/k8s/fastapi/requirements.txt" \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${ROOT}/.rendered/k8s/app/deployment-fastapi-configmap.yaml"
    kubectl rollout restart deploy/fastapi -n api-mercado
  else
    kubectl apply -f "${ROOT}/.rendered/k8s/app/deployment-fastapi.yaml"
  fi

  kubectl apply -f "${ROOT}/.rendered/k8s/app/service.yaml"
  kubectl apply -f "${ROOT}/.rendered/k8s/app/virtualservice.yaml"
  kubectl apply -f "${ROOT}/k8s/istio/gateway-internal-nlb.yaml"
  kubectl rollout status deploy/fastapi -n api-mercado --timeout=180s
}

api_gateway() {
  # shellcheck source=scripts/load-vars.sh
  source "${ROOT}/scripts/load-vars.sh"
  if [[ -z "${NlbArn}" || -z "${NlbDnsName}" ]]; then
    "${ROOT}/scripts/discover-nlb.sh"
    source "${ROOT}/scripts/load-vars.sh"
  fi
  deploy_stack "${STACK_PREFIX}-api" "${ROOT}/api_gateway/template.yaml" \
    "Environment=${Environment}" \
    "ProjectName=${ProjectName}" \
    "ApiStageName=${ApiStageName}" \
    "NlbArn=${NlbArn}" \
    "NlbDnsName=${NlbDnsName}"
}

smoke() {
  local URL code attempt
  URL=$("${ROOT}/scripts/stack-output.sh" "${STACK_PREFIX}-api" InvokeUrl)
  echo "GET ${URL}/productos"
  code=000
  for attempt in 1 2 3 4 5; do
    code=$(curl -sS -o /tmp/smoke-productos.json -w "%{http_code}" "${URL}/productos")
    [[ "$code" == "200" ]] && break
    echo "intento ${attempt}/5: HTTP ${code} (esperando backend...)"
    sleep 15
  done
  head -c 200 /tmp/smoke-productos.json; echo
  echo "HTTP ${code}"
  if [[ "$code" != "200" ]]; then
    echo "smoke fallo en /productos (revisa pods: kubectl get pods -n api-mercado)" >&2
    return 1
  fi
  echo "GET ${URL}/clientes"
  code=$(curl -sS -o /tmp/smoke-clientes.json -w "%{http_code}" "${URL}/clientes")
  head -c 200 /tmp/smoke-clientes.json; echo
  echo "HTTP ${code}"
  [[ "$code" == "200" ]]
}

case "${1:-}" in
  infra) infra ;;
  kubeconfig) kubeconfig ;;
  platform) platform ;;
  app) app ;;
  api) api_gateway ;;
  smoke) smoke ;;
  all)
    infra
    kubeconfig
    platform
    app
    "${ROOT}/scripts/discover-nlb.sh"
    api_gateway
    smoke
    ;;
  *)
    echo "Usage: $0 {infra|kubeconfig|platform|app|api|smoke|all}" >&2
    exit 1
    ;;
esac
