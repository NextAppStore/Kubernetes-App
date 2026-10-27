# Kubernetes-App

Pro Kurs ein k3s-Cluster auf **einer** OpenStack-VM. Jeder Student bekommt darin einen eigenen
Ubuntu-24.04-Pod mit SSH-Zugang und `sudo`. Hat ein Student Probleme, weist der Dozent mit einem
Befehl einen frischen Pod zu. Das Home-Verzeichnis bleibt dabei erhalten, auf Wunsch wird es auch
zurückgesetzt.

```
Student   ssh -p 30001 anna@<IPv6 der VM>      →  Pod "student-anna"  (Home = PVC)
Dozent    kubectl --kubeconfig kurs.kubeconfig  →  https://[<IPv6>]:6443  (cluster-admin)
          labctl reassign anna                  →  neuer Pod, gleicher Port, Home bleibt
```

* **Ein Team = eine VM = ein Cluster.** Für einen ganzen Kurs alle Studenten in dasselbe Team legen.
* **IPv6 ist die Hauptadresse** (Netz `DHBWV6`, dual-stack). IPv4 funktioniert mit denselben Ports.
* Der Port eines Studenten ist fest. Terraform merkt sich die Reihenfolge, in der Studenten zum
  ersten Mal auftauchen (`terraform_data.port_registry`): neue Studenten bekommen den nächsten
  freien Port, entfernte hinterlassen eine Lücke, alle anderen behalten ihren Port. Auch bei
  `reassign`, `reset` und einem Redeploy der VM bleibt er gleich.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `terraform/` | VM, Port, Security Group (IPv4 + IPv6), CA und Admin-Token, Kubeconfig-Output |
| `terraform/user-data.yaml.tpl` | cloud-init: k3s-Konfiguration, Studentenliste |
| `packer/` | Image: k3s, Student-Image (als Tar importiert, keine Registry), `labctl` |
| `packer/files/labctl` | CLI für den Dozenten |
| `packer/files/student-image/` | Dockerfile und Entrypoint des Student-Pods |

## 1. Image bauen (Packer)

Voraussetzung: `~/.config/openstack/clouds.yaml` mit dem Profil `openstack`.

```bash
cd packer
packer init .
packer validate .
packer build -var image_name=kubernetes-app-v0.1.0 .
```

Der Build installiert Docker, baut das Student-Image, speichert es nach
`/var/lib/rancher/k3s/agent/images/` (k3s importiert es beim Start), entfernt Docker wieder und
installiert k3s (`k3s_version`, siehe `packer/variables.pkr.hcl`).

## 2. Deployen (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # E-Mail-Adressen, Flavor, Ressourcen, Netz anpassen
terraform init
terraform plan
terraform apply
```

### Einstellungen im Wizard

| Variable | Default | Wirkung |
|---|---|---|
| `flavor_name` | `gp1.large` | vCPU und RAM der **gesamten VM** |
| `root_disk_gb` | `40` | Platte der **gesamten VM** als Volume (0 = Platte des Flavors, bei `gp1.large` nur 10 GB), dort liegen alle Homes |
| `pod_cpu` | `0.5` | vCPU **je Pod** |
| `pod_memory_mb` | `1024` | RAM **je Pod** in MB |
| `pod_disk_gb` | `5` | Home-Verzeichnis **je Pod** in GB |
| `allow_pod_communication` | `false` | Pods erreichen sich gegenseitig (Pentest) |
| `allow_internet` | `true` | Pods erreichen das Internet (apt, pip, git) |

* **Ressourcen sind garantiert** (Request = Limit). Für k3s und das System bleiben 0,5 vCPU,
  1,5 GB RAM und 10 GB Platte reserviert. Passen nicht alle Studenten eines Teams auf den Flavor,
  bricht schon `terraform plan` mit einer Meldung ab, die nennt, wie viele Studenten passen.
  Mit allen Defaults (`gp1.large` = 4 vCPU / 8 GB, 40 GB Volume) passen 6 Studenten. Für größere Kurse
  einen größeren Flavor wählen und `root_disk_gb` um 5 GB je Student erhöhen.
* **Netz**: Campus-/OpenStack-Netz (`141.72.0.0/16`, `2001:7c0::/32`), die VM selbst, die Kubernetes-API
  und der Metadatendienst sind für Pods **immer** gesperrt. Die beiden Schalter setzen nur den Startwert,
  danach gilt `labctl network` (siehe unten).
* Die Netze, aus denen SSH und die API erreichbar sind, sind feste Konstanten in `terraform/main.tf`
  (`campus_cidr_v4/v6`), keine Wizard-Variablen mehr.

### Rückmeldung an die Plattform

Der Start dauert einige Minuten (IPv6 abwarten, k3s starten, Studenten-Pods anlegen). Am Ende schreibt die
VM genau eine Zeile auf die serielle Konsole: `APPSTORE-READY` oder `APPSTORE-FAILED: <Grund>` (z.B.
`not ready: student-anna: Pending, Unschedulable: … Insufficient memory`). Der Worker liest die Konsole über
die OpenStack-API (Output `readiness_checks`) und lässt den Deploy fehlschlagen, wenn `FAILED` kommt oder
nach 25 Minuten nichts. Studenten bekommen also keine Zugänge zu Pods, die nicht laufen.

Selbst nachsehen: `openstack console log show kubernetes-app-<team> | grep APPSTORE-`, ausführlich:
`ssh ubuntu@<ip> sudo tail -f /var/log/kubernetes-app-provision.log` (nur mit `key_pair_name`).
Lokal mit `terraform apply` gibt es diese Prüfung nicht, dort hilft `labctl wait-ready`.

## 3. Zugänge holen

```bash
# Kubeconfig des Dozenten (cluster-admin) – nicht weitergeben, nicht einchecken
terraform output -json kubeconfigs | jq -r '.kurs' > ../kurs.kubeconfig
chmod 600 ../kurs.kubeconfig

# SSH-Befehle und Passwörter der Studenten
terraform output -json user_accounts | jq -r 'to_entries[] | "\(.value.ssh_command)   Passwort: \(.value.auth)"'
```

## 4. Dozenten-CLI `labctl`

Lokal (braucht `kubectl`):

```bash
export KUBECONFIG=$PWD/kurs.kubeconfig
export PATH=$PWD/packer/files:$PATH
labctl list
```

Oder auf der VM: `sudo labctl list` (bei gesetztem `key_pair_name`).

| Befehl | Wirkung |
|---|---|
| `labctl list` | Student, Port, Generation, Pod, Status |
| `labctl reassign <user>` | neuer Pod, Home-Verzeichnis und SSH-Fingerprint bleiben |
| `labctl reset <user> [--new-password]` | neuer Pod und **leeres** Home (Daten gelöscht) |
| `labctl passwd <user> [passwort]` | Passwort ändern (Pod wird neu gestartet) |
| `labctl add-student <user> [passwort] [port]` | Student nachträglich anlegen |
| `labctl remove-student <user> [--yes]` | Student samt Daten entfernen |
| `labctl shell <user>` / `labctl logs <user>` | Support |
| `labctl wait-ready [--timeout <s>]` | wartet, bis alle Pods laufen, sonst Grund je Pod |
| `labctl network peers <on\|off>` | Pods erreichen sich gegenseitig (Pentest) |
| `labctl network internet <on\|off>` | Pods erreichen das Internet |
| `labctl network status` | beide Netzmodi anzeigen |

Neue Studenten werden **nicht** über Terraform nachgezogen (die VM würde sonst ersetzt und alle
Home-Verzeichnisse gingen verloren). Dafür gibt es `labctl add-student`. Damit Plattform und VM
übereinstimmen, Passwort und Port aus `user_accounts` übernehmen:
`labctl add-student <user> <auth> <port>`. Ein Redeploy der VM legt alle aktuellen Studenten mit
ihren festen Ports neu an (Homes sind dann leer).

### Netzwerk der Pods

Beide Modi stehen als Label am Namespace `lab` (`kubernetes-app/peer-access=open|isolated`,
`kubernetes-app/internet=allowed|blocked`). `labctl network` schaltet sofort um, ohne Pod-Neustart.
Die Wizard-Variablen setzen nur den Startwert.

| | Internet an | Internet aus |
|---|---|---|
| **Peers aus** | Normalbetrieb: apt/pip/git gehen, andere Pods nicht | nur DNS, komplett abgeschottet |
| **Peers an** | Pentest mit Internet | Pentest ohne Internet (Klausur/CTF) |

Immer gesperrt: Campus-/OpenStack-Netz (andere VMs, NodePorts anderer Teams), die VM selbst,
Kubernetes-API und der Metadatendienst `169.254.169.254`. SSH von außen auf den eigenen Pod geht immer.
Ohne Internet bleibt DNS erreichbar (Namen der anderen Pods, aber auch DNS-Abfragen nach außen).

### Pentest-Modus (Pod-zu-Pod-Kommunikation)

Mit `allow_pod_communication = true` bzw. `labctl network peers on` erreichen sich die Student-Pods eines
Teams gegenseitig auf allen Ports und Protokollen, z.B. um gegenseitig die eigenen Anwendungen anzugreifen.
Jeder Pod ist unter `<user>.students.lab.svc.cluster.local` erreichbar. Der Name bleibt bei `reassign`
gleich, obwohl sich die Pod-IP ändert.

* `NET_RAW` bleibt entfernt, damit niemand per ARP-Spoofing den Verkehr anderer Pods mitschneidet.
  Port-Scans deshalb als Connect-Scan: `nmap -sT` statt `-sS`.
* Pods, die vor dieser Version angelegt wurden, haben noch keinen DNS-Namen. Sie sind per Pod-IP
  erreichbar; nach `labctl reset` oder Neuanlage haben sie einen Namen.

## 5. Abnahme-Checkliste

0. Deploy über die Plattform: Log zeigt `kurs: ready`. Gegenprobe: `pod_memory_mb` so groß wählen, dass
   `terraform plan` mit der Kapazitätsmeldung abbricht.
1. `kubectl --kubeconfig kurs.kubeconfig get nodes,pods -n lab` – Node `Ready`, ein Pod je Student `Running`,
   `kubectl describe pod` zeigt QoS-Klasse `Guaranteed`.
2. `ssh -6 -p 30001 anna@<ipv6>` mit dem Passwort; danach `sudo whoami` → `root`, `sudo apt-get update`, Datei im Home anlegen. Zum Vergleich über IPv4.
3. `labctl reassign anna` → neuer Pod-Name, Generation 2, Datei noch da, gleicher Port, keine Host-Key-Warnung.
4. `labctl reset anna` → Datei weg, SSH geht wieder (neuer Host-Key: `ssh-keygen -R`).
5. Isolation im Pod von `anna`: `curl -m3 http://169.254.169.254` schlägt fehl, `nc -zv <ip-der-VM> 6443` schlägt fehl,
   ein anderer Student-Pod und eine andere VM im Campusnetz sind nicht erreichbar, es gibt kein Token unter
   `/var/run/secrets`.
6. Last: `:(){ :|:& };:` im Pod → andere Pods und `kubectl get nodes` bleiben erreichbar (PID-Limit 512).
7. Pentest-Modus: `labctl network peers on`. Im Pod von `ben` `python3 -m http.server 8080`, aus dem Pod von
   `anna` `curl -m3 ben.students.lab.svc.cluster.local:8080` geht. Eine andere VM im Campusnetz und die
   NodePorts anderer Teams sind nicht erreichbar, `curl https://example.org` geht, SSH von außen geht weiter.
   `labctl network peers off` → der curl zwischen den Pods schlägt sofort fehl.
8. Internet: `labctl network internet off` → `curl -m3 https://example.org` schlägt fehl,
   `getent hosts ben.students.lab.svc.cluster.local` geht, SSH von außen geht weiter. `internet on` → geht wieder.
9. `labctl add-student carl`; zum Schluss `terraform destroy`.

## Sicherheitshinweise

* **Root im Pod**: Studenten haben `sudo` ohne Passwort. Die Container sind nicht privilegiert, `NET_RAW`/`MKNOD`
  sind entfernt, seccomp ist aktiv. Root im Container ist kein Root auf dem Host, aber ein Kernel-Exploit
  wäre ein Weg heraus. Alle Pods teilen sich den Kernel der VM.
* **Isolation**: NetworkPolicy sperrt Pod↔Pod (außer im Pentest-Modus), Zugriffe auf die Kubernetes-API,
  die VM selbst, das DHBW-/OpenStack-Netz und den OpenStack-Metadatendienst `169.254.169.254` (dort liegen
  die `user_data` mit Passwörtern und Admin-Token).
* **Kubeconfig** enthält einen statischen cluster-admin-Token. Der Token und die CA liegen im Terraform-State und
  in den `user_data` der VM.
* **Speicher**: `local-path` erzwingt die Größe des Home-Verzeichnisses nicht. Die Platte der VM ist die Grenze
  (`root_disk_gb`, `pod_disk_gb`, beim Plan geprüft). Wird die VM gelöscht oder ersetzt, sind alle Daten weg.
* `campus_cidr_v4`/`campus_cidr_v6` in `terraform/main.tf` bestimmen, wer SSH und die API erreicht. Den
  IPv6-Wert (`2001:7c0::/32`) bitte mit dem eigenen Netz abgleichen.

## Bekannte Unsicherheiten (beim ersten Deploy prüfen)

Folgendes ist statisch geprüft, aber **noch nicht gegen ein echtes OpenStack/k3s getestet**:

1. **Eigene Server-CA und Token-Auth in k3s**: Akzeptiert k3s `server-ca.crt/key` ohne weitere CA-Dateien, und
   funktioniert `token-auth-file`? Fehlerbild: `kubectl` meldet Zertifikats- oder `Unauthorized`-Fehler.
   Ausweichen: Admin-Zugang über `ssh ubuntu@<ip> sudo cat /etc/rancher/k3s/k3s.yaml`.
2. **Dual-Stack im Cluster**: NodePort über IPv6, Pod-Egress über `flannel-ipv6-masq`, NetworkPolicy für IPv6.
   Fehlerbild: SSH über IPv4 geht, über IPv6 nicht. Fällt die IPv6-Adresse der VM nach 240 s nicht an, startet das
   Provisioning automatisch als Single-Stack IPv4.
3. **DHCPv6 in der VM**: Laut Entwicklerguide reicht für Linux das Netz `DHBWV6`. Bei Problemen die Adresse per
   netplan setzen.
4. **Packer-Build**: Docker-Installation und `docker save` im Build, Import des Tars durch k3s.
5. **Serielle Konsole**: Landet `APPSTORE-READY` im `openstack console log show`? Fehlerbild: Deploy läuft
   nach 25 Minuten in den Timeout, obwohl die Pods laufen. Dann prüfen, ob `/dev/ttyS0` im Image existiert.
