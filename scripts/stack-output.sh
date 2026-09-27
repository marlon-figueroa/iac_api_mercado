#!/usr/bin/env bash
set -euo pipefail
STACK="$1"
KEY="$2"
REGION="${AWS_REGION:-us-east-1}"
aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='${KEY}'].OutputValue" \
  --output text
