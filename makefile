# Local ergonomics only. CI does NOT use this file: pr.yml calls terraform
# directly, because there TF_VAR_aws_profile must stay unset for OIDC to work.
TF_ENV             ?= infra/envs/dev
TF_VAR_aws_profile ?= taskflow-dev
export TF_VAR_aws_profile

.DEFAULT_GOAL := help
.PHONY: help fmt lint plan apply destroy

help:  ## muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

fmt:  ## formatea todo el HCL del repo
	terraform fmt -recursive

lint:  ## lo mismo que corre CI, en local
	terraform fmt -check -recursive
	pre-commit run --all-files

plan:  ## terraform plan en dev
	terraform -chdir=$(TF_ENV) plan

apply:  ## terraform apply en dev
	terraform -chdir=$(TF_ENV) apply

destroy:  ## destruye todo lo billable de dev
	terraform -chdir=$(TF_ENV) destroy

.PHONY: local test

local:
	docker compose up -d

test:
	uv run pytest
