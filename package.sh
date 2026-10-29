#!/usr/bin/env bash
# =============================================================================
#  package.sh — đóng gói toolkit thành file .tar.gz để mang sang máy Linux khác
#    ./package.sh            → dist/sysadmin-toolkit-<phiên bản>.tar.gz (+ .sha256)
#  Trên máy đích:  tar xzf sysadmin-toolkit-*.tar.gz && cd sysadmin-toolkit && sudo ./install.sh --deps
# =============================================================================
set -euo pipefail
SRC=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
VERSION=$(awk -F'"' '/^TOOLKIT_VERSION=/ { print $2 }' "$SRC/lib/common.sh")
OUT="$SRC/dist/sysadmin-toolkit-$VERSION.tar.gz"
mkdir -p "$SRC/dist"
# Chỉ đóng gói mã nguồn & cấu hình mẫu (không gồm log, báo cáo, mật khẩu mail)
tar -czf "$OUT" -C "$(dirname "$SRC")" \
  --exclude='sysadmin-toolkit/dist' --exclude='sysadmin-toolkit/logs/*' --exclude='sysadmin-toolkit/reports/*' \
  --exclude='sysadmin-toolkit/config/msmtprc' --exclude='sysadmin-toolkit/.git' \
  "$(basename "$SRC")"
(cd "$SRC/dist" && sha256sum "$(basename "$OUT")" >"$(basename "$OUT").sha256")
echo "Đã tạo: $OUT ($(du -h "$OUT" | cut -f1))"
echo "SHA-256: $(cut -d' ' -f1 "$OUT.sha256")"
