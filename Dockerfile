FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    tftpd-hpa \
    u-boot-tools \
    rsync \
    dosfstools \
    fdisk \
    parted \
    kpartx \
    xz-utils \
    openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /srv/tftp /srv/nfs /uploads /db

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

COPY webui/requirements.txt /tmp/requirements.txt
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN uv venv $VIRTUAL_ENV && uv pip install --no-cache -r /tmp/requirements.txt

COPY webui /app/
COPY scripts /scripts/
COPY sdcard/make-netboot-sd.sh /scripts/make-netboot-sd.sh

WORKDIR /app

EXPOSE 69/udp 8080

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /scripts/*.sh

ENTRYPOINT ["/entrypoint.sh"]
