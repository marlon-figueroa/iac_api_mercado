#!/usr/bin/env bash
# Carga vars.yaml como variables de entorno exportadas.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS_FILE="${ROOT}/vars.yaml"
PARSE="${ROOT}/scripts/parse-vars.py"

if [[ ! -f "$VARS_FILE" ]]; then
  echo "Missing $VARS_FILE" >&2
  exit 1
fi

eval "$(python3 "$PARSE" export "$VARS_FILE")"
