# Student image: an Ubuntu 24.04 system with SSH access and sudo.
#
# Built during the Packer build and imported into k3s as a tar (no registry).
# The user is only created on start by entrypoint.sh, so that one image
# is enough for all students.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-server sudo ca-certificates locales tzdata \
        vim nano less tmux htop man-db \
        git curl wget unzip zip \
        python3 python3-pip python3-venv build-essential \
        iputils-ping dnsutils iproute2 net-tools \
    && locale-gen en_US.UTF-8 de_DE.UTF-8 \
    && mkdir -p /run/sshd \
    # pam_loginuid fails in containers and would abort every login
    && sed -i 's/^session\s\+required\s\+pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
