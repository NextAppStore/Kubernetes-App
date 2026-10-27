#!/usr/bin/env bash
# Start of a student pod: create the user, set the password, start sshd.
#
# Expects:
#   STUDENT_USER        Linux username (environment variable)
#   /etc/student/password   password (mounted as a secret)
#   /home/$STUDENT_USER     home directory (mounted as a PVC)
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

# User with a fixed UID: files in the PVC keep belonging to the same user
# even after a pod change.
if ! id -u "${STUDENT_USER}" >/dev/null 2>&1; then
    useradd --uid "${STUDENT_UID}" --no-create-home --home-dir "${HOME_DIR}" \
        --shell /bin/bash --groups sudo --user-group "${STUDENT_USER}"
fi

# The password always comes from the secret. Changes made with `passwd` in the pod
# last until the next pod start.
printf '%s:%s\n' "${STUDENT_USER}" "$(cat "${PASSWORD_FILE}")" | chpasswd

printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${STUDENT_USER}" >/etc/sudoers.d/90-student
chmod 0440 /etc/sudoers.d/90-student

# Populate home with the default files on first start. Never touch it again
# afterwards, otherwise the students' changes would be overwritten.
mkdir -p "${HOME_DIR}"
if [ ! -e "${HOME_DIR}/.lab-initialized" ]; then
    cp -a /etc/skel/. "${HOME_DIR}/"
    chown -R "${STUDENT_UID}:${STUDENT_UID}" "${HOME_DIR}"
    touch "${HOME_DIR}/.lab-initialized"
    chown "${STUDENT_UID}:${STUDENT_UID}" "${HOME_DIR}/.lab-initialized"
fi

# SSH host keys live in the PVC: after a reassign the fingerprint stays the same,
# only a reset generates new keys.
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
