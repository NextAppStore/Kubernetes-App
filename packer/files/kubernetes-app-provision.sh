#!/usr/bin/env bash
# shellcheck disable=SC2153
# First boot of the VM: start k3s, wait for the node, create the students.
#
# Called by cloud-init (runcmd). cloud-init writes the configuration
# beforehand to /etc/kubernetes-app/ and /etc/rancher/k3s/.
set -euo pipefail

LAB_ENV_FILE=/etc/kubernetes-app/lab.env
# shellcheck disable=SC1090
. "${LAB_ENV_FILE}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# k3s may only start once the IPv6 address is on the interface.
# DHCPv6 needs a few seconds after boot.
if [ -n "${NODE_IPV6:-}" ]; then
    log "Warte auf IPv6-Adresse ${NODE_IPV6}"
    for _ in $(seq 1 120); do
        if ip -6 -o addr show scope global | grep -q "${NODE_IPV6}"; then
            break
        fi
        sleep 2
    done
    if ! ip -6 -o addr show scope global | grep -q "${NODE_IPV6}"; then
        log "IPv6-Adresse ${NODE_IPV6} fehlt nach 240 s. Wechsle auf Single-Stack IPv4."
        sed -i -e "s|^node-ip:.*|node-ip: \"${NODE_IPV4}\"|" \
            -e 's|^cluster-cidr:.*|cluster-cidr: "10.42.0.0/16"|' \
            -e 's|^service-cidr:.*|service-cidr: "10.43.0.0/16"|' \
            -e '/^flannel-ipv6-masq/d' /etc/rancher/k3s/config.yaml
    fi
fi

log "Starte k3s"
systemctl enable --now k3s

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
log "Warte auf Knoten"
for _ in $(seq 1 90); do
    if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
        break
    fi
    sleep 4
done
kubectl wait --for=condition=Ready node --all --timeout=120s

log "Lege Studenten an"
labctl sync

log "Fertig"
