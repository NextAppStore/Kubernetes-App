#!/usr/bin/env bash
# Start eines Student-Pods: Benutzer anlegen, Passwort setzen, sshd starten.
#
# Erwartet:
#   STUDENT_USER        Linux-Benutzername (Umgebungsvariable)
#   /etc/student/password   Passwort (als Secret gemountet)
#   /home/$STUDENT_USER     Home-Verzeichnis (als PVC gemountet)
set -euo pipefail

: "${STUDENT_USER:?STUDENT_USER muss gesetzt sein}"

STUDENT_UID=2000
PASSWORD_FILE=/etc/student/password
HOME_DIR="/home/${STUDENT_USER}"
HOSTKEY_DIR="${HOME_DIR}/.ssh-host"

if [ ! -s "${PASSWORD_FILE}" ]; then
    echo "Passwort-Datei ${PASSWORD_FILE} fehlt oder ist leer" >&2
    exit 1
fi

# Benutzer mit fester UID: Dateien im PVC gehoeren auch nach einem
# Pod-Wechsel demselben Benutzer.
if ! id -u "${STUDENT_USER}" >/dev/null 2>&1; then
    useradd --uid "${STUDENT_UID}" --no-create-home --home-dir "${HOME_DIR}" \
        --shell /bin/bash --groups sudo --user-group "${STUDENT_USER}"
fi

# Das Passwort kommt immer aus dem Secret. Aenderungen mit `passwd` im Pod
# gelten bis zum naechsten Pod-Start.
printf '%s:%s\n' "${STUDENT_USER}" "$(cat "${PASSWORD_FILE}")" | chpasswd

printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${STUDENT_USER}" >/etc/sudoers.d/90-student
chmod 0440 /etc/sudoers.d/90-student

# Home beim ersten Start mit den Standarddateien befuellen. Danach nie wieder
# anfassen, sonst wuerden Aenderungen der Studenten ueberschrieben.
mkdir -p "${HOME_DIR}"
if [ ! -e "${HOME_DIR}/.lab-initialized" ]; then
    cp -a /etc/skel/. "${HOME_DIR}/"
    chown -R "${STUDENT_UID}:${STUDENT_UID}" "${HOME_DIR}"
    touch "${HOME_DIR}/.lab-initialized"
    chown "${STUDENT_UID}:${STUDENT_UID}" "${HOME_DIR}/.lab-initialized"
fi

# SSH-Hostkeys liegen im PVC: nach einem Reassign bleibt der Fingerprint gleich,
# erst ein Reset erzeugt neue Keys.
mkdir -p "${HOSTKEY_DIR}"
chmod 0700 "${HOSTKEY_DIR}"
for type in ed25519 rsa; do
    if [ ! -s "${HOSTKEY_DIR}/ssh_host_${type}_key" ]; then
        ssh-keygen -q -t "${type}" -N '' -f "${HOSTKEY_DIR}/ssh_host_${type}_key"
    fi
done

cat >/etc/ssh/sshd_config.d/10-lab.conf <<EOF
HostKey ${HOSTKEY_DIR}/ssh_host_ed25519_key
HostKey ${HOSTKEY_DIR}/ssh_host_rsa_key
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers ${STUDENT_USER}
ClientAliveInterval 60
ClientAliveCountMax 5
EOF

mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e
