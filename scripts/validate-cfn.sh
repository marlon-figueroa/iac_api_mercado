#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shopt -s nullglob
templates=(
  "$ROOT"/template.yaml
  "$ROOT"/vpc/template.yaml
  "$ROOT"/kms/template.yaml
  "$ROOT"/iam/template.yaml
  "$ROOT"/dynamodb/template.yaml
  "$ROOT"/eks/template.yaml
  "$ROOT"/ec2/template.yaml
  "$ROOT"/api_gateway/template.yaml
)

for t in "${templates[@]}"; do
  echo "Validating $t"
  aws cloudformation validate-template --template-body "file://${t}" >/dev/null
done

if command -v cfn-lint >/dev/null 2>&1; then
  cfn-lint "${templates[@]}"
else
  echo "cfn-lint not installed; skipped"
fi

echo "OK"
