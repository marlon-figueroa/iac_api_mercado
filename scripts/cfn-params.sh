#!/usr/bin/env bash
# Convierte KEY=VALUE en argumentos --parameter-overrides para aws cloudformation deploy
set -euo pipefail
params=()
for arg in "$@"; do
  params+=("$arg")
done
if ((${#params[@]} == 0)); then
  echo "Usage: cfn-params.sh Key1=Value1 Key2=Value2 ..." >&2
  exit 1
fi
echo "${params[*]}"
