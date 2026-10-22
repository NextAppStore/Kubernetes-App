#cloud-config

# ── bootcmd: läuft vor write_files ────────────────────────────────────────────
# Verzeichnisse anlegen, die write_files benötigt.
bootcmd:
  - mkdir -p /etc/kubernetes-app /etc/rancher/k3s /var/lib/rancher/k3s/server/tls
  - chmod 700 /var/lib/rancher/k3s/server/tls

# ── write_files: nur Konfiguration ────────────────────────────────────────────
# Die Logik (k3s, labctl) liegt im Packer-Image unter /usr/local/bin.
write_files:
  - path: /etc/kubernetes-app/lab.env
    permissions: '0644'
    content: |
      TEAM=${team}
      NODE_IPV4=${node_ipv4}
      NODE_IPV6=${node_ipv6}
      LAB_IMAGE=${lab_image}
      POD_CPU_LIMIT=${pod_cpu_limit}
      POD_MEMORY_LIMIT=${pod_memory_limit}
      POD_MEMORY_REQUEST=${pod_memory_request}
      POD_DISK=${pod_disk}

  # Startliste: Benutzer, Passwort, NodePort. Wird nur von `labctl sync` gelesen.
  - path: /etc/kubernetes-app/students.tsv
    permissions: '0600'
    content: |
%{ for student in students ~}
      ${student.username} ${student.password} ${student.port}
%{ endfor ~}

  - path: /etc/rancher/k3s/config.yaml
    permissions: '0600'
    content: |
      write-kubeconfig-mode: "0600"
%{ if node_ipv6 != "" ~}
      node-ip: "${node_ipv4},${node_ipv6}"
      cluster-cidr: "10.42.0.0/16,fd00:42::/56"
      service-cidr: "10.43.0.0/16,fd00:43::/112"
      flannel-ipv6-masq: true
      tls-san:
        - "${node_ipv4}"
        - "${node_ipv6}"
%{ else ~}
      node-ip: "${node_ipv4}"
      cluster-cidr: "10.42.0.0/16"
      service-cidr: "10.43.0.0/16"
      tls-san:
        - "${node_ipv4}"
%{ endif ~}
      disable:
        - traefik
        - servicelb
      kube-apiserver-arg:
        - "token-auth-file=/etc/rancher/k3s/tokens.csv"
      kubelet-arg:
        - "pod-max-pids=512"

  # Statischer Admin-Token: wer ihn kennt, ist cluster-admin (Gruppe system:masters).
  - path: /etc/rancher/k3s/tokens.csv
    permissions: '0600'
    content: |
      ${admin_token},lab-admin,lab-admin,"system:masters"

  # Eigene Server-CA, damit die Kubeconfig die CA schon beim Terraform-Apply kennt.
  - path: /var/lib/rancher/k3s/server/tls/server-ca.crt
    permissions: '0644'
    content: |
      ${indent(6, chomp(ca_cert_pem))}

  - path: /var/lib/rancher/k3s/server/tls/server-ca.key
    permissions: '0600'
    content: |
      ${indent(6, chomp(ca_key_pem))}

# ── runcmd: Erststart ─────────────────────────────────────────────────────────
# Nur eine Zeile — Doppelpunkte außerhalb von Strings brechen das YAML-Parsing.
runcmd:
  - bash /usr/local/bin/kubernetes-app-provision.sh > /var/log/kubernetes-app-provision.log 2>&1
