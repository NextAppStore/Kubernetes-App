#!/usr/bin/env bash
# Tests labctl without a cluster: a fake kubectl records the manifests sent via
# `apply`; they are parsed as YAML and checked afterwards.
#   python3 agentic-harness/sandbox.py bash Kubernetes-App/tests/labctl.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"

cat >"${work}/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
# Fake kubectl: only the calls labctl add-student, network and wait-ready need.
args=" $* "
out="${FAKE_OUT:?}"
case "${args}" in
    *" get nodes "*) printf '141.72.1.2\n2001:7c0:1b20:c913:1::2e3\n' ;;
    *" get namespace "*peer-access*) printf '%s' "${FAKE_PEER_LABEL:-}" ;;
    *" get namespace "*internet*) printf '%s' "${FAKE_INTERNET_LABEL:-}" ;;
    *" create secret "*) printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: student-anna\nstringData:\n  password: x\n' ;;
    *" label --local "*) cat ;;
    *" apply -f - "*) n=$(find "${out}" -name 'apply-*' | wc -l); cat >"${out}/apply-$(printf '%02d' "${n}").yaml" ;;
    *" delete networkpolicy "*) echo "$*" >>"${out}/deletes.log" ;;
    *" get deployment -l role=student "*) printf '%s' "${FAKE_STUDENTS:-}" ;;
    *" get deployment student-"*readyReplicas*) [ "${FAKE_READY:-}" = "1" ] && printf '1' ;;
    *" get deployment "*) exit 1 ;;
    *" get pods "*) printf 'Pending, PodScheduled: 0/1 nodes are available: 1 Insufficient memory.' ;;
    *" get service "*) exit 0 ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "${work}/bin/kubectl"

export PATH="${work}/bin:${PATH}"
export KUBECONFIG=/dev/null

env_file() {
    printf 'POD_TO_POD=%s\nPOD_INTERNET=%s\nPOD_CPU=0.5\nPOD_MEMORY=1024Mi\nPOD_DISK=5Gi\nCAMPUS_CIDR_V4=141.72.0.0/16\nCAMPUS_CIDR_V6=2001:7c0::/32\n' "$1" "$2" >"${work}/$3.env"
    echo "${work}/$3.env"
}

# run <name> <lab.env> <peer label> <internet label> <labctl arguments...>
run() {
    local name="$1" env="$2" peer="$3" internet="$4"
    shift 4
    mkdir -p "${work}/${name}"
    echo "==> ${name}: labctl $*"
    FAKE_OUT="${work}/${name}" LAB_ENV_FILE="${env}" FAKE_PEER_LABEL="${peer}" FAKE_INTERNET_LABEL="${internet}" \
        bash "${root}/packer/files/labctl" "$@"
}

run defaults /nonexistent "" "" add-student anna secret123 30001
run peers-internet "$(env_file true true a)" "" "" add-student anna secret123 30001
run peers-offline "$(env_file true false b)" "" "" add-student anna secret123 30001
run isolated-offline "$(env_file false false c)" "" "" add-student anna secret123 30001
run label-wins "$(env_file false true d)" open blocked add-student anna secret123 30001
run peers-off "$(env_file true true e)" open allowed network peers off
run internet-off "$(env_file true true f)" open allowed network internet off

expect_fail() {
    local what="$1"
    shift
    if FAKE_OUT="${work}/defaults" LAB_ENV_FILE=/nonexistent bash "${root}/packer/files/labctl" "$@" >/dev/null 2>&1; then
        echo "ERROR: ${what} was accepted: labctl $*" >&2
        exit 1
    fi
}

echo "==> invalid names"
for bad in Anna "a_b" "-x" "x-" "1abc"; do
    expect_fail "name '${bad}'" add-student "${bad}"
done

echo "==> invalid network arguments"
expect_fail "network open" network open
expect_fail "network peers maybe" network peers maybe
expect_fail "network internet" network internet

echo "==> wait-ready"
FAKE_OUT="${work}/defaults" LAB_ENV_FILE=/nonexistent FAKE_STUDENTS="anna" FAKE_READY=1 \
    bash "${root}/packer/files/labctl" wait-ready --timeout 0 | grep -qx "ready: 1 students"
FAKE_OUT="${work}/defaults" LAB_ENV_FILE=/nonexistent FAKE_STUDENTS="" \
    bash "${root}/packer/files/labctl" wait-ready --timeout 0 | grep -qx "ready: no students"
if problems="$(FAKE_OUT="${work}/defaults" LAB_ENV_FILE=/nonexistent FAKE_STUDENTS="anna" \
    bash "${root}/packer/files/labctl" wait-ready --timeout 0 2>&1 >/dev/null)"; then
    echo "ERROR: wait-ready succeeded with a pending pod" >&2
    exit 1
fi
grep -q "not ready: student-anna: Pending, PodScheduled: 0/1 nodes are available: 1 Insufficient memory." <<<"${problems}" \
    || { echo "ERROR: unexpected wait-ready output: ${problems}" >&2; exit 1; }

echo "==> checking manifests"
python3 - "${work}" <<'PY'
import glob, os, sys, yaml

work = sys.argv[1]
CAMPUS_V4, CAMPUS_V6 = "141.72.0.0/16", "2001:7c0::/32"


def load(name):
    docs = []
    for path in sorted(glob.glob(f"{work}/{name}/apply-*.yaml")):
        docs += [d for d in yaml.safe_load_all(open(path)) if d]
    log = f"{work}/{name}/deletes.log"
    deletes = open(log).read() if os.path.exists(log) else ""
    return docs, deletes


def policy(docs, name):
    return next((d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == name), None)


def check_network(name, peers, internet):
    docs, deletes = load(name)
    labels = next(d for d in docs if d["kind"] == "Namespace")["metadata"]["labels"]
    assert labels["kubernetes-app/peer-access"] == peers, (name, labels)
    assert labels["kubernetes-app/internet"] == internet, (name, labels)

    headless = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == "students")
    assert headless["spec"]["clusterIP"] == "None" and headless["spec"]["selector"] == {"role": "student"}

    base = policy(docs, "student-isolation")
    ingress = base["spec"]["ingress"][0]
    assert ingress["ports"] == [{"protocol": "TCP", "port": 22}], ingress
    egress = base["spec"]["egress"]
    dns = egress[0]
    assert dns["to"][0]["podSelector"] == {"matchLabels": {"k8s-app": "kube-dns"}}, dns
    assert {p["port"] for p in dns["ports"]} == {53}, dns

    if internet == "allowed":
        assert len(egress) == 2, (name, egress)
        v4 = egress[1]["to"][0]["ipBlock"]
        v6 = egress[1]["to"][1]["ipBlock"]
        assert v4["cidr"] == "0.0.0.0/0" and v6["cidr"] == "::/0", (name, v4, v6)
        # Blocked whenever the internet is open: pod/service network, node,
        # metadata/link-local and always the campus network.
        for blocked in ("10.42.0.0/16", "10.43.0.0/16", "169.254.0.0/16", "141.72.1.2/32", CAMPUS_V4):
            assert blocked in v4["except"], (name, v4)
        for blocked in ("fd00:42::/56", "fd00:43::/112", "fe80::/10", "2001:7c0:1b20:c913:1::2e3/128", CAMPUS_V6):
            assert blocked in v6["except"], (name, v6)
    else:
        # Only DNS: no ipBlock egress at all.
        assert len(egress) == 1, (name, egress)

    peer = policy(docs, "student-peer-access")
    if peers == "open":
        only_students = [{"podSelector": {"matchLabels": {"role": "student"}}}]
        assert peer is not None, name
        assert peer["spec"]["podSelector"] == {"matchLabels": {"role": "student"}}
        assert peer["spec"]["ingress"] == [{"from": only_students}], peer
        assert peer["spec"]["egress"] == [{"to": only_students}], peer
        assert "student-peer-access" not in deletes, name
    else:
        assert peer is None, name
        assert "delete networkpolicy student-peer-access" in deletes, (name, deletes)
    print(f"{name}: peers {peers}, internet {internet} ok")
    return docs


docs = check_network("defaults", "isolated", "allowed")
check_network("peers-internet", "open", "allowed")
check_network("peers-offline", "open", "blocked")
check_network("isolated-offline", "isolated", "blocked")
check_network("label-wins", "open", "blocked")
for name, peers, internet in (("peers-off", "isolated", "allowed"), ("internet-off", "open", "blocked")):
    switch_docs = check_network(name, peers, internet)
    assert not any(d["kind"] in ("Deployment", "PersistentVolumeClaim") for d in switch_docs), "network must not touch pods"

kinds = [d["kind"] for d in docs]
print("objects:", kinds)
assert kinds == ["Namespace", "Service", "NetworkPolicy", "PersistentVolumeClaim", "Secret", "Deployment", "Service"], kinds

dep = next(d for d in docs if d["kind"] == "Deployment")
spec = dep["spec"]
assert spec["strategy"]["type"] == "Recreate" and spec["replicas"] == 1
assert spec["selector"]["matchLabels"].items() <= spec["template"]["metadata"]["labels"].items()
pod = spec["template"]["spec"]
assert pod["automountServiceAccountToken"] is False
assert pod["hostname"] == "anna" and pod["subdomain"] == "students", pod
ctr = pod["containers"][0]
assert ctr["securityContext"]["privileged"] is False
assert ctr["securityContext"]["capabilities"]["drop"] == ["NET_RAW", "MKNOD"]
assert ctr["env"][0] == {"name": "STUDENT_USER", "value": "anna"}
assert spec["template"]["metadata"]["annotations"]["lab-generation"] == "1"

# Request = limit (guaranteed QoS), values from lab.env.
res = ctr["resources"]
assert res["requests"] == {"cpu": "0.5", "memory": "1Gi"}, res
assert res["limits"]["cpu"] == "0.5" and res["limits"]["memory"] == "1Gi", res
dep_env = next(d for d in load("peers-internet")[0] if d["kind"] == "Deployment")
res_env = dep_env["spec"]["template"]["spec"]["containers"][0]["resources"]
assert res_env["requests"] == {"cpu": "0.5", "memory": "1024Mi"}, res_env
assert res_env["limits"]["memory"] == "1024Mi", res_env
pvc = next(d for d in load("peers-internet")[0] if d["kind"] == "PersistentVolumeClaim")
assert pvc["spec"]["resources"]["requests"]["storage"] == "5Gi", pvc

svc = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == "student-anna")
assert svc["spec"]["ports"][0]["nodePort"] == 30001
assert svc["spec"]["ipFamilyPolicy"] == "PreferDualStack"
assert svc["spec"]["externalTrafficPolicy"] == "Local"
print("Deployment/Service ok, nodePort", svc["spec"]["ports"][0]["nodePort"])
PY
echo "labctl test passed"
