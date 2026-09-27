#!/usr/bin/env bash
# Obtiene outputs de CloudFormation y valores AWS; actualiza NlbArn/NlbDnsName en vars.yaml si existe NLB.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/load-vars.sh
source "${ROOT}/scripts/load-vars.sh"

export AWS_DEFAULT_REGION="${AwsRegion}"
if [[ -n "${AwsProfile:-}" ]]; then
  export AWS_PROFILE="${AwsProfile}"
fi

STACK_PREFIX="${ProjectName}-${Environment}"
OUT_FILE="${ROOT}/stack-outputs.yaml"
REGION="${AwsRegion}"

stack_outputs() {
  local stack="$1"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_PREFIX}-${stack}" \
    --region "$REGION" \
    --query 'Stacks[0].[StackStatus,Outputs]' \
    --output json 2>/dev/null || echo '["MISSING", null]'
}

echo "# Generado por scripts/fetch-outputs.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT_FILE"
echo "AwsRegion: ${AwsRegion}" >> "$OUT_FILE"
echo "StackPrefix: ${STACK_PREFIX}" >> "$OUT_FILE"
echo "" >> "$OUT_FILE"

for s in vpc kms dynamodb iam eks ec2 api; do
  echo "${s}:" >> "$OUT_FILE"
  stack_outputs "$s" | python3 -c "
import json, sys
status, outputs = json.load(sys.stdin)
print('  StackStatus:', status)
if outputs:
  for o in outputs:
    k, v = o['OutputKey'], o['OutputValue']
    print(f'  {k}: {v}')
" >> "$OUT_FILE" 2>/dev/null || {
    echo "  StackStatus: MISSING" >> "$OUT_FILE"
  }
  echo "" >> "$OUT_FILE"
done

# EKS cluster (aunque el stack CFN siga en progreso)
echo "eksLive:" >> "$OUT_FILE"
if aws eks describe-cluster --name "${ClusterName}" --region "$REGION" >/dev/null 2>&1; then
  aws eks describe-cluster --name "${ClusterName}" --region "$REGION" \
    --query 'cluster.{Status:status,Version:version,Endpoint:endpoint,Arn:arn}' \
    --output json | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'  {k}: {v}') for k,v in d.items()]" >> "$OUT_FILE"
else
  echo "  Status: NOT_FOUND" >> "$OUT_FILE"
fi
echo "" >> "$OUT_FILE"

# NLB interno (post-Istio)
NLB_ARN=""
NLB_DNS=""
if command -v kubectl >/dev/null 2>&1 && kubectl get svc istio-ingressgateway-internal -n istio-system >/dev/null 2>&1; then
  HOSTNAME=$(kubectl get svc istio-ingressgateway-internal -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "$HOSTNAME" ]]; then
    NLB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?DNSName=='${HOSTNAME}'].LoadBalancerArn | [0]" --output text)
    NLB_DNS="$HOSTNAME"
  fi
fi
if [[ -z "$NLB_ARN" || "$NLB_ARN" == "None" ]]; then
  NLB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?Scheme=='internal' && Type=='network'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
  if [[ -n "$NLB_ARN" && "$NLB_ARN" != "None" ]]; then
    NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$NLB_ARN" --region "$REGION" \
      --query 'LoadBalancers[0].DNSName' --output text)
  fi
fi

echo "nlb:" >> "$OUT_FILE"
if [[ -n "$NLB_ARN" && "$NLB_ARN" != "None" ]]; then
  echo "  NlbArn: ${NLB_ARN}" >> "$OUT_FILE"
  echo "  NlbDnsName: ${NLB_DNS}" >> "$OUT_FILE"
  python3 "${ROOT}/scripts/parse-vars.py" update-json "${ROOT}/vars.yaml" \
    "$(python3 -c "import json; print(json.dumps({'NlbArn': '${NLB_ARN}', 'NlbDnsName': '${NLB_DNS}'}))")"
  echo "Actualizado vars.yaml con NlbArn / NlbDnsName"
else
  echo "  NlbArn: \"\"" >> "$OUT_FILE"
  echo "  NlbDnsName: \"\"" >> "$OUT_FILE"
  echo "NLB aún no existe (normal hasta make platform + Istio)."
fi

echo ""
echo "Escrito: ${OUT_FILE}"
cat "$OUT_FILE"
