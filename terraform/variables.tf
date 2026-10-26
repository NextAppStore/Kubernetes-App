############################
# Plattform-injizierte Variablen (nicht im Wizard sichtbar)
############################

variable "users" {
  description = "Per-team roster — vom Worker injiziert. @platform:internal"
  type = map(list(object({
    email = string
  })))
  default = {}
}

variable "image_name" {
  description = "Glance-Image-Name — vom Worker zur Apply-Zeit gesetzt. @platform:internal"
  type        = string
  default     = "kubernetes-app-vX"
}

############################
# Wizard-Variablen (vom Deployer im AppStore konfiguriert)
############################

variable "network_uuid" {
  description = "UUID des internen Netzwerks @openstack:network:id"
  type        = string
  # DHBWV6: dual-stack (v4+v6 auf demselben Subnetz-Paar) — jede VM
  # bekommt automatisch beide Fixed-IPs von Neutron.
  default = "9b579624-d844-4df3-b38d-89978b31d37d"
}

variable "shared_secgroup_id" {
  description = "ID der gemeinsamen Security Group @openstack:security_group:id"
  type        = string
  default     = "5c0e96fb-bd1f-41b3-b400-deccf7712a80"
}

variable "flavor_name" {
  description = "Groesse der VM. Alle Student-Pods laufen darauf: ca. 1 GiB RAM pro Student plus 2 GiB. @openstack:flavor:name"
  type        = string
  default     = "gp1.large"
}

variable "key_pair_name" {
  description = "Optionales Keypair fuer SSH-Admin-Zugang zur VM (Benutzer ubuntu). Leer = kein Admin-Zugang. @openstack:keypair:name"
  type        = string
  default     = ""
}

variable "root_disk_gb" {
  description = "Groesse der Root-Platte in GB (Boot from Volume). 0 = Platte des Flavors. Dort liegen auch die Home-Verzeichnisse aller Studenten."
  type        = number
  default     = 0
}

variable "allowed_cidr_v4" {
  description = "IPv4-Netz, das SSH (Pods, VM) und die Kubernetes-API erreichen darf. Default: DHBW-Campus und VPN."
  type        = string
  default     = "141.72.0.0/16"

  validation {
    condition     = can(cidrhost(var.allowed_cidr_v4, 0)) && var.allowed_cidr_v4 != "0.0.0.0/0"
    error_message = "allowed_cidr_v4 muss ein gueltiges IPv4-Netz sein und darf nicht 0.0.0.0/0 sein."
  }
}

variable "allowed_cidr_v6" {
  description = "IPv6-Netz, das SSH (Pods, VM) und die Kubernetes-API erreichen darf. Praefix des DHBW-Netzes, bitte pruefen."
  type        = string
  default     = "2001:7c0::/32"

  validation {
    condition     = can(cidrhost(var.allowed_cidr_v6, 0)) && !contains(["::/0", "0::/0"], var.allowed_cidr_v6)
    error_message = "allowed_cidr_v6 muss ein gueltiges IPv6-Netz sein und darf nicht ::/0 sein."
  }
}

variable "allow_pod_communication" {
  description = "Pentest-Modus: Die Student-Pods eines Teams erreichen sich gegenseitig auf allen Ports. Die Pods erreichen dann das DHBW-/OpenStack-Netz (allowed_cidr_v4/v6) nicht mehr. Spaeter umschaltbar mit `labctl network open|isolated`."
  type        = bool
  default     = false
}

############################
# Pod-Ressourcen je Student
############################

variable "pod_cpu_limit" {
  description = "CPU-Limit je Student-Pod (Kerne)."
  type        = string
  default     = "1"
}

variable "pod_memory_limit" {
  description = "RAM-Limit je Student-Pod."
  type        = string
  default     = "1Gi"
}

variable "pod_memory_request" {
  description = "Reservierter RAM je Student-Pod (fuer die Platzierung). Niedriger als das Limit erlaubt mehr Studenten pro VM."
  type        = string
  default     = "256Mi"
}

variable "pod_disk" {
  description = "Groesse des Home-Verzeichnisses je Student. local-path erzwingt die Groesse nicht."
  type        = string
  default     = "5Gi"
}
