#!/usr/bin/env bash
# Rellena vars.yaml con valores de stacks CloudFormation y NLB (AWS CLI).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/load-vars.sh
source "${ROOT}/scripts/load-vars.sh"

export AWS_DEFAULT_REGION="${AwsRegion}"
if [[ -n "${AwsProfile:-}" ]]; then
  export AWS_PROFILE="${AwsProfile}"
fi

STACK_PREFIX="${ProjectName}-${Environment}"
PARSE="${ROOT}/scripts/parse-vars.py"
VARS="${ROOT}/vars.yaml"

stack_output() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_PREFIX}-$1" \
    --region "${AwsRegion}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" \
    --output text 2>/dev/null || echo ""
}

stack_param() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_PREFIX}-$1" \
    --region "${AwsRegion}" \
    --query "Stacks[0].Parameters[?ParameterKey=='$2'].ParameterValue | [0]" \
    --output text 2>/dev/null || echo ""
}

stack_exists() {
  aws cloudformation describe-stacks --stack-name "${STACK_PREFIX}-$1" --region "${AwsRegion}" >/dev/null 2>&1
}

PT="" CT="" KV="" CN="" NLB_ARN="" NLB_DNS="" API_URL=""

if stack_exists dynamodb; then
  PT=$(stack_output dynamodb ProductosTableName)
  CT=$(stack_output dynamodb ClientesTableName)
fi

if stack_exists eks; then
  KV=$(stack_param eks KubernetesVersion)
  CN=$(stack_param eks ClusterName)
  if command -v kubectl >/dev/null 2>&1; then
    aws eks update-kubeconfig --name "${ClusterName}" --region "${AwsRegion}" >/dev/null 2>&1 || true
    if kubectl get svc istio-ingressgateway-internal -n istio-system >/dev/null 2>&1; then
      NLB_DNS=$(kubectl get svc istio-ingressgateway-internal -n istio-system \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    fi
  fi
fi

if [[ -n "$NLB_DNS" ]]; then
  NLB_ARN=$(aws elbv2 describe-load-balancers --region "${AwsRegion}" \
    --query "LoadBalancers[?DNSName=='${NLB_DNS}'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
fi

if [[ -z "$NLB_ARN" || "$NLB_ARN" == "None" ]]; then
  NLB_ARN=$(aws elbv2 describe-load-balancers --region "${AwsRegion}" \
    --query "LoadBalancers[?Scheme=='internal' && Type=='network'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
  if [[ -n "$NLB_ARN" && "$NLB_ARN" != "None" ]]; then
    NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$NLB_ARN" --region "${AwsRegion}" \
      --query 'LoadBalancers[0].DNSName' --output text)
  fi
fi

if stack_exists api; then
  API_URL=$(stack_output api InvokeUrl)
fi

export PT CT KV CN NLB_ARN NLB_DNS API_URL VARS PARSE
python3 <<'PY'
import json, os, subprocess

vars_path = os.environ["VARS"]
parse = os.environ["PARSE"]

def load_current():
    out = subprocess.check_output(["python3", parse, "export", vars_path], text=True)
    data = {}
    for line in out.splitlines():
        if not line.startswith("export "):
            continue
        body = line[len("export ") :]
        key, val = body.split("=", 1)
        data[key] = val.strip('"')
    return data

cur = load_current()
upd = {}

mapping = {
    "ProductosTableName": os.environ.get("PT", ""),
    "ClientesTableName": os.environ.get("CT", ""),
    "KubernetesVersion": os.environ.get("KV", ""),
    "ClusterName": os.environ.get("CN", ""),
    "NlbArn": os.environ.get("NLB_ARN", ""),
    "NlbDnsName": os.environ.get("NLB_DNS", ""),
}

for key, val in mapping.items():
    if not val or val == "None":
        continue
    if key in ("NlbArn", "NlbDnsName"):
        upd[key] = val
    elif key in ("ProductosTableName", "ClientesTableName", "KubernetesVersion", "ClusterName"):
        upd[key] = val

if not upd:
    print("Sin cambios: NLB aun no existe (normal antes de make platform).")
    print("Valores CFN actuales en cuenta:")
    for key in ("ProductosTableName", "ClientesTableName", "KubernetesVersion", "ClusterName"):
        v = mapping.get(key) or cur.get(key, "")
        if v:
            print(f"  {key}: {v}")
    raise SystemExit(0)

subprocess.check_call(
    ["python3", parse, "update-json", vars_path, json.dumps(upd)]
)
print("vars.yaml actualizado:")
for k, v in upd.items():
    print(f"  {k}: {v}")

api_url = os.environ.get("API_URL", "")
if api_url and api_url != "None":
    print(f"  (info) InvokeUrl: {api_url}")
PY
