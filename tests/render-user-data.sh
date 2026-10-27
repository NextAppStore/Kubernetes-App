#!/usr/bin/env bash
# Renders terraform/user-data.yaml.tpl with sample values and checks that it
# yields valid cloud-config YAML (with and without IPv6).
#   python3 agentic-harness/sandbox.py bash Kubernetes-App/tests/render-user-data.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../terraform"
terraform init -backend=false -input=false >/dev/null

render() {
    local ipv6="$1"
    # `terraform console` reads one line per expression, so the newlines of
    # the heredoc are replaced by spaces. The output is a console string
    # literal that contains the jsonencode string.
    tr '\n' ' ' <<EOF | terraform console | python3 -c 'import json,sys; print(json.loads(json.loads(sys.stdin.read())))'
jsonencode(templatefile("user-data.yaml.tpl", {
  team = "kurs",
  node_ipv4 = "141.72.1.2",
  node_ipv6 = "${ipv6}",
  admin_token = "tokentoken",
  ca_cert_pem = "-----BEGIN CERTIFICATE-----\nAAAA\nBBBB\n-----END CERTIFICATE-----\n",
  ca_key_pem = "-----BEGIN EC PRIVATE KEY-----\nCCCC\nDDDD\n-----END EC PRIVATE KEY-----\n",
  lab_image = "kubernetes-app/student:1",
  pod_cpu = 0.5,
  pod_memory_mb = 1024,
  pod_disk_gb = 5,
  pod_to_pod = true,
  pod_internet = false,
  reserved_cpu_m = 250,
  reserved_mem_mi = 768,
  campus_cidr_v4 = "141.72.0.0/16",
  campus_cidr_v6 = "2001:7c0::/32",
  students = [
    { username = "anna", password = "Passw0rdAnna12345", port = 30001 },
    { username = "ben", password = "Passw0rdBen1234567", port = 30002 },
  ]
}))
EOF
}

check() {
    python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin.read())
files = {f["path"]: f["content"] for f in doc["write_files"]}
assert "anna Passw0rdAnna12345 30001" in files["/etc/kubernetes-app/students.tsv"], "students.tsv"
env = files["/etc/kubernetes-app/lab.env"].splitlines()
for line in ("POD_TO_POD=true", "POD_INTERNET=false", "POD_CPU=0.5", "POD_MEMORY=1024Mi", "POD_DISK=5Gi",
             "CAMPUS_CIDR_V4=141.72.0.0/16", "CAMPUS_CIDR_V6=2001:7c0::/32"):
    assert line in env, (line, env)
cfg = yaml.safe_load(files["/etc/rancher/k3s/config.yaml"])
assert cfg["disable"] == ["traefik", "servicelb"], cfg
assert cfg["kube-apiserver-arg"] == ["token-auth-file=/etc/rancher/k3s/tokens.csv"], cfg
assert cfg["kubelet-arg"] == ["pod-max-pids=512", "kube-reserved=cpu=250m,memory=768Mi",
                              "system-reserved=cpu=250m,memory=768Mi"], cfg
print("node-ip:", cfg["node-ip"], "| tls-san:", cfg["tls-san"], "| cluster-cidr:", cfg["cluster-cidr"])
assert files["/etc/rancher/k3s/tokens.csv"].strip() == "tokentoken,lab-admin,lab-admin,\"system:masters\""
assert files["/var/lib/rancher/k3s/server/tls/server-ca.crt"].startswith("-----BEGIN CERTIFICATE-----\nAAAA")
assert files["/var/lib/rancher/k3s/server/tls/server-ca.key"].rstrip().endswith("-----END EC PRIVATE KEY-----")
print("runcmd:", doc["runcmd"])
'
}

echo "==> with IPv6"
render "2001:7c0:1b20:c913:1::2e3" | check
echo "==> without IPv6"
render "" | check
echo "Render test passed"
