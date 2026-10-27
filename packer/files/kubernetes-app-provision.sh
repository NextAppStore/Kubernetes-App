#!/usr/bin/env bash
# shellcheck disable=SC2153
# First boot of the VM: start k3s, wait for the node, create the students,
# wait for their pods and report the result to the platform.
#
# Called by cloud-init (runcmd). cloud-init writes the configuration to
# /etc/kubernetes-app/ and /etc/rancher/k3s/ beforehand.
#
# Result for the platform: exactly one line on the serial console, either
# "APPSTORE-READY" or "APPSTORE-FAILED: <reason>". The worker reads it via the
# OpenStack console log (output readiness_checks) and fails the deploy on
# FAILED or when no marker shows up in time.
set -euo pipefail

LAB_ENV_FILE=/etc/kubernetes-app/lab.env
# shellcheck disable=SC1090
. "${LAB_ENV_FILE}"

# Must stay below timeout_seconds of the readiness_checks output, so the VM
# reports a reason before the worker gives up.
PODS_TIMEOUT=420

log() { echo "[$(date -u +%FT%TZ)] $*"; }

STEP="starting"
REPORTED=""

# The serial console is what `openstack console log show` returns. Writes are
# best effort and time-limited, a missing device must not block the boot.
report() {
    local line="$1" dev
    REPORTED=1
    log "${line}"
    for dev in /dev/ttyS0 /dev/console; do
        [ -w "${dev}" ] || continue
        # shellcheck disable=SC2016 # expanded by the inner sh
        timeout 5 sh -c 'printf "%s\n" "$1" >"$2"' _ "${line}" "${dev}" || true
    done
}

on_exit() {
    local rc=$?
    if [ "${rc}" -ne 0 ] && [ -z "${REPORTED}" ]; then
        report "APPSTORE-FAILED: ${STEP} (exit ${rc}, see /var/log/kubernetes-app-provision.log)"
    fi
}
trap on_exit EXIT

# k3s may only start once the IPv6 address is on the interface. DHCPv6 takes
# a few seconds after boot.
if [ -n "${NODE_IPV6:-}" ]; then
    STEP="waiting for IPv6 address"
    log "Waiting for IPv6 address ${NODE_IPV6}"
    for _ in $(seq 1 120); do
        if ip -6 -o addr show scope global | grep -q "${NODE_IPV6}"; then
            break
        fi
        sleep 2
    done
    if ! ip -6 -o addr show scope global | grep -q "${NODE_IPV6}"; then
        log "IPv6 address ${NODE_IPV6} still missing after 240 s. Falling back to single-stack IPv4."
        sed -i -e "s|^node-ip:.*|node-ip: \"${NODE_IPV4}\"|" \
            -e 's|^cluster-cidr:.*|cluster-cidr: "10.42.0.0/16"|' \
            -e 's|^service-cidr:.*|service-cidr: "10.43.0.0/16"|' \
            -e '/^flannel-ipv6-masq/d' /etc/rancher/k3s/config.yaml
    fi
fi

STEP="starting k3s"
log "Starting k3s"
systemctl enable --now k3s

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
STEP="waiting for the Kubernetes node"
log "Waiting for node"
for _ in $(seq 1 90); do
    if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
        break
    fi
    sleep 4
done
kubectl wait --for=condition=Ready node --all --timeout=120s

STEP="creating students (labctl sync)"
log "Creating students"
labctl sync

STEP="waiting for student pods"
log "Waiting for student pods (up to ${PODS_TIMEOUT} s)"
if ! problems="$(labctl wait-ready --timeout "${PODS_TIMEOUT}" 2>&1 >/dev/null)"; then
    log "${problems}"
    # One line, short enough for the platform log.
    reason="$(tr '\n' ';' <<<"${problems}" | sed 's/;$//; s/;/; /g' | cut -c1-500)"
    report "APPSTORE-FAILED: ${reason:-student pods not ready}"
    exit 1
fi

report "APPSTORE-READY"
log "Done"
