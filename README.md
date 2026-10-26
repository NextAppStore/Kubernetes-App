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
* Der Port eines Studenten ist fest (`30001` + Position in der alphabetischen Liste) und ändert sich
  bei einem Reassign nicht.

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
cp terraform.tfvars.example terraform.tfvars   # E-Mail-Adressen, Flavor, ggf. Netze anpassen
terraform init
terraform plan
terraform apply
```

Der Start dauert einige Minuten (k3s starten, Studenten-Pods anlegen). Fortschritt:
`ssh ubuntu@<ip> sudo tail -f /var/log/kubernetes-app-provision.log` (nur mit `key_pair_name`).

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
| `labctl network <open\|isolated\|status>` | Pentest-Modus ein-/ausschalten oder anzeigen (siehe unten) |

Neue Studenten werden **nicht** über Terraform nachgezogen (die VM würde sonst ersetzt und alle
Home-Verzeichnisse gingen verloren). Dafür gibt es `labctl add-student`.

### Pentest-Modus (Pod-zu-Pod-Kommunikation)

Mit `allow_pod_communication = true` (Schalter im Wizard) erreichen sich die Student-Pods eines Teams
gegenseitig auf allen Ports und Protokollen, z.B. um gegenseitig die eigenen Anwendungen anzugreifen.
Jeder Pod ist unter `<user>.students.lab.svc.cluster.local` erreichbar. Der Name bleibt bei `reassign`
gleich, obwohl sich die Pod-IP ändert.

* Die Variable setzt nur den Startwert. Danach schaltet `labctl network open|isolated` sofort um,
  ohne Pod-Neustart. Der Modus steht als Label `kubernetes-app/peer-access` am Namespace `lab`.
* Im Pentest-Modus erreichen die Pods das DHBW-/OpenStack-Netz (`allowed_cidr_v4`/`allowed_cidr_v6`)
  nicht mehr, also weder andere VMs noch die Pods anderer Teams. Das Internet (apt, pip, git) bleibt
  erreichbar. Knoten, Kubernetes-API und Metadatendienst bleiben in beiden Modi gesperrt.
* `NET_RAW` bleibt entfernt, damit niemand per ARP-Spoofing den Verkehr anderer Pods mitschneidet.
  Port-Scans deshalb als Connect-Scan: `nmap -sT` statt `-sS`.
* Pods, die vor dieser Version angelegt wurden, haben noch keinen DNS-Namen. Sie sind per Pod-IP
  erreichbar; nach `labctl reset` oder Neuanlage haben sie einen Namen.

## 5. Abnahme-Checkliste

1. `kubectl --kubeconfig kurs.kubeconfig get nodes,pods -n lab` – Node `Ready`, ein Pod je Student `Running`.
2. `ssh -6 -p 30001 anna@<ipv6>` mit dem Passwort; danach `sudo whoami` → `root`, `sudo apt-get update`, Datei im Home anlegen. Zum Vergleich über IPv4.
3. `labctl reassign anna` → neuer Pod-Name, Generation 2, Datei noch da, gleicher Port, keine Host-Key-Warnung.
4. `labctl reset anna` → Datei weg, SSH geht wieder (neuer Host-Key: `ssh-keygen -R`).
5. Isolation im Pod von `anna`: `curl -m3 http://169.254.169.254` schlägt fehl, `nc -zv <ip-der-VM> 6443` schlägt fehl, ein anderer Student-Pod ist nicht erreichbar, es gibt kein Token unter `/var/run/secrets`.
6. Last: `:(){ :|:& };:` im Pod → andere Pods und `kubectl get nodes` bleiben erreichbar (PID-Limit 512).
7. Pentest-Modus: `labctl network open`. Im Pod von `ben` `python3 -m http.server 8080`, aus dem Pod von
   `anna` `curl -m3 ben.students.lab.svc.cluster.local:8080` geht. Eine andere VM im Campusnetz und die
   NodePorts anderer Teams sind nicht erreichbar, `curl https://example.org` geht, SSH von außen geht weiter.
   `labctl network isolated` → der curl zwischen den Pods schlägt sofort fehl.
8. `labctl add-student carl`; zum Schluss `terraform destroy`.

## Sicherheitshinweise

* **Root im Pod**: Studenten haben `sudo` ohne Passwort. Die Container sind nicht privilegiert, `NET_RAW`/`MKNOD`
  sind entfernt, seccomp ist aktiv. Root im Container ist kein Root auf dem Host, aber ein Kernel-Exploit
  wäre ein Weg heraus. Alle Pods teilen sich den Kernel der VM.
* **Isolation**: NetworkPolicy sperrt Pod↔Pod, Zugriffe auf die Kubernetes-API, die VM selbst und den
  OpenStack-Metadatendienst `169.254.169.254` (dort liegen die `user_data` mit Passwörtern und Admin-Token).
  Im Pentest-Modus ist Pod↔Pod innerhalb des Teams offen, dafür ist das DHBW-/OpenStack-Netz gesperrt.
  Ohne Pentest-Modus erreichen Pods das Campusnetz, und damit auch andere VMs.
* **Kubeconfig** enthält einen statischen cluster-admin-Token. Der Token und die CA liegen im Terraform-State und
  in den `user_data` der VM.
* **Speicher**: `local-path` erzwingt die Größe des Home-Verzeichnisses nicht. Die Platte der VM ist die Grenze
  (`root_disk_gb`, `pod_disk`). Fällt die VM aus, sind alle Daten weg.
* `allowed_cidr_v4`/`allowed_cidr_v6` bestimmen, wer SSH und die API erreicht. Den IPv6-Default
  (`2001:7c0::/32`) bitte mit dem eigenen Netz abgleichen.

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
