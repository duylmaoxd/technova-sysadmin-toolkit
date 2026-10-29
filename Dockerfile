# =============================================================================
#  Dockerfile — đóng gói LinuxAdmin Toolkit thành máy chủ mô phỏng "technova-core-srv"
#  (Ubuntu Server 24.04 + toolkit đã cài sẵn + cron/at + SSH server)
#
#  Build : docker build -t technova/sysadmin-toolkit:1.0 .
#  Chạy  : docker compose up -d        (xem README, mục "Chạy bằng Docker")
# =============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TERM=xterm-256color \
    TZ=Asia/Ho_Chi_Minh

# Gói phụ thuộc của 5 chức năng + SSH server để quản trị từ xa
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash sudo passwd procps psmisc tree sysstat iproute2 iputils-ping \
      dialog whiptail cron at msmtp ca-certificates curl rsync \
      openssh-server bsdextrautils less nano tzdata \
 && rm -rf /var/lib/apt/lists/*

# Cài toolkit vào /opt/sysadmin-toolkit + lệnh "sysadmin" (giống cài trên máy thật)
COPY . /tmp/sysadmin-toolkit
RUN cd /tmp/sysadmin-toolkit \
 && ./install.sh --yes \
 && install -m 755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh \
 && cp -a /opt/sysadmin-toolkit/config /opt/sysadmin-toolkit/config.default \
 && rm -rf /tmp/sysadmin-toolkit /opt/sysadmin-toolkit/logs/* /opt/sysadmin-toolkit/reports/*

# Dữ liệu cần giữ lại khi xoá/tạo lại container
VOLUME ["/var/backups/sysadmin-toolkit", "/opt/sysadmin-toolkit/config", \
        "/opt/sysadmin-toolkit/reports", "/opt/sysadmin-toolkit/logs"]

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Không truyền lệnh → chạy như máy chủ (sshd); truyền lệnh → chạy lệnh đó (vd: sysadmin --tui)
CMD []
