#!/usr/bin/env bash
# Detecta el NLB interno del ingress Istio y actualiza vars.yaml
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/load-vars.sh
source "${ROOT}/scripts/load-vars.sh"

export AWS_REGION="${AwsRegion}"
if [[ -n "${AwsProfile:-}" ]]; then
  export AWS_PROFILE="${AwsProfile}"
fi

SVC="istio-ingressgateway-internal"
NLB_ARN=""
NLB_DNS=""

if command -v kubectl >/dev/null 2>&1 && kubectl get svc "$SVC" -n istio-system >/dev/null 2>&1; then
  HOSTNAME=$(kubectl get svc "$SVC" -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  if [[ -n "$HOSTNAME" ]]; then
    NLB_ARN=$(aws elbv2 describe-load-balancers \
      --query "LoadBalancers[?DNSName=='${HOSTNAME}'].LoadBalancerArn | [0]" \
      --output text)
    NLB_DNS="$HOSTNAME"
  fi
fi

if [[ -z "$NLB_ARN" || "$NLB_ARN" == "None" ]]; then
  NLB_ARN=$(aws elbv2 describe-load-balancers --region "${AwsRegion}" \
    --query "LoadBalancers[?Scheme=='internal' && Type=='network'].LoadBalancerArn | [0]" \
    --output text)
  if [[ -n "$NLB_ARN" && "$NLB_ARN" != "None" ]]; then
    NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$NLB_ARN" --region "${AwsRegion}" \
      --query "LoadBalancers[0].DNSName" --output text)
  fi
fi

if [[ -z "$NLB_ARN" || "$NLB_ARN" == "None" ]]; then
  echo "No se encontro NLB interno. Despliega Istio/gateway primero." >&2
  exit 1
fi

export NLB_ARN NLB_DNS
JSON=$(python3 -c 'import json, os; print(json.dumps({"NlbArn": os.environ["NLB_ARN"], "NlbDnsName": os.environ["NLB_DNS"]}))')
python3 "${ROOT}/scripts/parse-vars.py" update-json "${ROOT}/vars.yaml" "$JSON"

echo "NlbArn=${NLB_ARN}"
echo "NlbDnsName=${NLB_DNS}"
