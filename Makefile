.PHONY: validate sync-vars infra kubeconfig platform app discover-nlb api smoke all docs docs-pdf

SHELL := /bin/bash
ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

validate:
	@chmod +x $(ROOT)scripts/*.sh
	@$(ROOT)scripts/validate-cfn.sh

sync-vars:
	@chmod +x $(ROOT)scripts/*.sh
	@$(ROOT)scripts/sync-vars-from-aws.sh

infra:
	@chmod +x $(ROOT)scripts/*.sh
	@$(ROOT)scripts/deploy.sh infra

kubeconfig:
	@$(ROOT)scripts/deploy.sh kubeconfig

platform:
	@$(ROOT)scripts/deploy.sh platform

app:
	@$(ROOT)scripts/deploy.sh app

discover-nlb:
	@$(ROOT)scripts/discover-nlb.sh

api:
	@$(ROOT)scripts/deploy.sh api

smoke:
	@$(ROOT)scripts/deploy.sh smoke

all:
	@$(ROOT)scripts/deploy.sh all

docs-pdf:
	@chmod +x $(ROOT)scripts/build-docs.sh
	@$(ROOT)scripts/build-docs.sh

docs: docs-pdf
