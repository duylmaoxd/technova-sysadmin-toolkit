#!/usr/bin/env bash
# =============================================================================
#  docker/entrypoint.sh — khởi động "máy chủ" technova-core-srv trong container
#   - bật cron & atd (cho chức năng scheduler/alert/backup tự động)
#   - tạo tài khoản quản trị (Tech Lead) để SSH vào: ADMIN_USER / ADMIN_PASSWORD
#   - không có lệnh → chạy sshd (chế độ máy chủ); có lệnh → chạy lệnh đó
# =============================================================================
set -euo pipefail

ADMIN_USER=${ADMIN_USER:-hung}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-}

# Dịch vụ nền: rsyslog (ghi /var/log/auth.log, syslog), cron, atd
rsyslogd 2>/dev/null || true
cron
atd 2>/dev/null || true

# Volume cấu hình rỗng (bind mount) → chép lại cấu hình mặc định
if [[ ! -e /opt/sysadmin-toolkit/config/toolkit.conf && -d /opt/sysadmin-toolkit/config.default ]]; then
  cp -a /opt/sysadmin-toolkit/config.default/. /opt/sysadmin-toolkit/config/
fi

# Tài khoản quản trị để SSH vào (chỉ tạo khi có mật khẩu)
if [[ -n $ADMIN_PASSWORD ]] && ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo -c "Tech Lead (admin)" "$ADMIN_USER"
  printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
  echo "[entrypoint] Đã tạo tài khoản quản trị: $ADMIN_USER (thuộc nhóm sudo)"
fi

if (($# == 0)); then
  mkdir -p /run/sshd
  ssh-keygen -A >/dev/null
  echo "[entrypoint] technova-core-srv sẵn sàng — SSH vào cổng 22 của container."
  [[ -n $ADMIN_PASSWORD ]] || echo "[entrypoint] Chưa đặt ADMIN_PASSWORD → dùng: docker exec -it <container> sysadmin"
  # không dùng -e: để sshd ghi log vào syslog → /var/log/auth.log (cần cho phát hiện tấn công)
  exec /usr/sbin/sshd -D
fi
exec "$@"
