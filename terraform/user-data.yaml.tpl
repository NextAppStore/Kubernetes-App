#cloud-config

# ── bootcmd: runs before write_files ──────────────────────────────────────────
# Create the directories write_files needs.
bootcmd:
  - mkdir -p /etc/kubernetes-app /etc/rancher/k3s /var/lib/rancher/k3s/server/tls
  - chmod 700 /var/lib/rancher/k3s/server/tls

# ── write_files: configuration only ───────────────────────────────────────────
# The logic (k3s, labctl) lives in the Packer image under /usr/local/bin.
write_files:
  - path: /etc/kubernetes-app/lab.env
    permissions: '0644'
    content: |
      TEAM=${team}
      NODE_IPV4=${node_ipv4}
      NODE_IPV6=${node_ipv6}
      LAB_IMAGE=${lab_image}
      POD_CPU=${pod_cpu}
      POD_MEMORY=${pod_memory_mb}Mi
      POD_DISK=${pod_disk_gb}Gi
      POD_TO_POD=${pod_to_pod}
      POD_INTERNET=${pod_internet}
      CAMPUS_CIDR_V4=${campus_cidr_v4}
      CAMPUS_CIDR_V6=${campus_cidr_v6}

  # Initial roster: user, password, NodePort. Only read by `labctl sync`.
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
      # The reserved share keeps k3s itself alive when the student pods use
      # all of their (guaranteed) resources. Must match local.reserved.
      kubelet-arg:
        - "pod-max-pids=512"
        - "kube-reserved=cpu=${reserved_cpu_m}m,memory=${reserved_mem_mi}Mi"
        - "system-reserved=cpu=${reserved_cpu_m}m,memory=${reserved_mem_mi}Mi"

  # Static admin token: whoever knows it is cluster-admin (group system:masters).
  - path: /etc/rancher/k3s/tokens.csv
    permissions: '0600'
    content: |
      ${admin_token},lab-admin,lab-admin,"system:masters"

  # Own server CA, so the kubeconfig knows the CA at terraform apply time.
  - path: /var/lib/rancher/k3s/server/tls/server-ca.crt
    permissions: '0644'
    content: |
      ${indent(6, chomp(ca_cert_pem))}

  - path: /var/lib/rancher/k3s/server/tls/server-ca.key
    permissions: '0600'
    content: |
      ${indent(6, chomp(ca_key_pem))}

# ── runcmd: first boot ────────────────────────────────────────────────────────
# A single line only: colons outside of strings break the YAML parsing.
runcmd:
  - bash /usr/local/bin/kubernetes-app-provision.sh > /var/log/kubernetes-app-provision.log 2>&1
