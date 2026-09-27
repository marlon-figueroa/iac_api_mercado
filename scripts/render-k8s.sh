#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/load-vars.sh
source "${ROOT}/scripts/load-vars.sh"

OUT_DIR="${ROOT}/.rendered/k8s"
mkdir -p "$OUT_DIR/karpenter" "$OUT_DIR/app"

export AWS_REGION="${AwsRegion}"
export CLUSTER_NAME="${ClusterName}"
export FASTAPI_POD_ROLE_ARN
export KARPENTER_NODE_ROLE_NAME="${ProjectName}-${Environment}-karpenter-node"
export NODE_SECURITY_GROUP_ID
export PRODUCTOS_TABLE="${ProductosTableName}"
export CLIENTES_TABLE="${ClientesTableName}"
export FASTAPI_IMAGE="${FASTAPI_IMAGE:-}"

STACK_EKS="${ProjectName}-${Environment}-eks"
FASTAPI_POD_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_EKS" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='FastApiPodRoleArn'].OutputValue" --output text 2>/dev/null || true)
NODE_SECURITY_GROUP_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_EKS" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='NodeSecurityGroupId'].OutputValue" --output text 2>/dev/null || true)

if [[ -z "$FASTAPI_POD_ROLE_ARN" || "$FASTAPI_POD_ROLE_ARN" == "None" ]]; then
  echo "Deploy EKS stack first (FastApiPodRoleArn missing)." >&2
  exit 1
fi

for f in ec2nodeclass.yaml; do
  envsubst < "${ROOT}/k8s/karpenter/${f}" > "${OUT_DIR}/karpenter/${f}"
done
cp "${ROOT}/k8s/karpenter/nodepool.yaml" "${OUT_DIR}/karpenter/"

for f in namespace.yaml serviceaccount.yaml deployment-fastapi.yaml deployment-fastapi-configmap.yaml service.yaml virtualservice.yaml; do
  envsubst < "${ROOT}/k8s/app/${f}" > "${OUT_DIR}/app/${f}"
done

echo "Rendered manifests in ${OUT_DIR}"
