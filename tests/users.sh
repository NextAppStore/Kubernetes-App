#!/usr/bin/env bash
# Shows the user names derived from the e-mail addresses.
#   python3 agentic-harness/sandbox.py bash Kubernetes-App/tests/users.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../terraform"
terraform init -backend=false -input=false >/dev/null

users='{kurs=[{email="Anna.Mueller@dhbw.de"},{email="ben_k@dhbw.de"},{email="1234567@dhbw.de"},{email="very.long.name.that.exceeds.thirty.characters.abc@dhbw.de"},{email="zoe@dhbw.de"}],t2=[{email="x@dhbw.de"}]}'
echo "local.users_map" | terraform console -var "users=${users}" | grep -E 'username|"[a-z0-9-]+-[a-z0-9-]+" =' || true
# Ports depend on terraform_data.port_registry (known after apply) and are
# tested in terraform/tests/plan.tftest.hcl.
