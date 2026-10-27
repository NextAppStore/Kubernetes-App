#!/usr/bin/env bash
# Static checks and tests without OpenStack or cluster access: Terraform
# format/syntax and tests (mocked provider), shellcheck, cloud-init rendering,
# user name derivation and the manifests labctl generates (with a fake kubectl).
#
# Run from the project root:
#   python3 agentic-harness/sandbox.py bash Kubernetes-App/check.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> terraform fmt"
terraform -chdir=terraform fmt -recursive

echo "==> terraform validate"
terraform -chdir=terraform init -backend=false -input=false >/dev/null
terraform -chdir=terraform validate

echo "==> terraform test (mocked OpenStack: ports, capacity, readiness output)"
terraform -chdir=terraform test
terraform -chdir=terraform/modules/capacity init -backend=false -input=false >/dev/null
terraform -chdir=terraform/modules/capacity test

echo "==> tflint"
tflint --chdir=terraform

echo "==> tfsec"
tfsec terraform

echo "==> packer fmt / validate (syntax only, no OpenStack access)"
packer fmt -check packer
packer init packer
packer validate -syntax-only packer

echo "==> shellcheck"
shellcheck \
    packer/files/labctl \
    packer/files/kubernetes-app-provision.sh \
    packer/files/student-image/entrypoint.sh \
    packer/scripts/provision.sh \
    check.sh \
    tests/*.sh

echo "==> tests"
bash tests/render-user-data.sh
bash tests/users.sh
bash tests/labctl.sh

echo "All checks passed"
