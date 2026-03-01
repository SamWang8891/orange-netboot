FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-flask python3-paramiko python3-pip \
    tftpd-hpa \
    u-boot-tools \
    rsync \
    dosfstools \
    fdisk \
    parted \
    kpartx \
    xz-utils \
    openssh-client \
    && pip3 install --break-system-packages flask-sock \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /srv/tftp /srv/nfs /uploads /db

COPY webui /app/
COPY scripts /scripts/
COPY sdcard/make-netboot-sd.sh /scripts/make-netboot-sd.sh

WORKDIR /app

EXPOSE 69/udp 8080

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /scripts/*.sh

ENTRYPOINT ["/entrypoint.sh"]
