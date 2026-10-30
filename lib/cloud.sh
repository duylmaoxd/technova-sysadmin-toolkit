#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # biến toàn cục dùng chung giữa các file
# =============================================================================
#  lib/cloud.sh — Đưa bản sao lưu & log lên Google Drive bằng rclone
#    GDRIVE_REMOTE="gdrive:TechNova-Server"  (tên remote rclone : thư mục gốc trên Drive)
#    Cấu trúc trên Drive:  <thư mục gốc>/<hostname>/backups/   bản sao lưu + .sha256
#                          <thư mục gốc>/<hostname>/logs/      gói log hằng ngày
#  Cấu hình lần đầu: sysadmin backup cloud-setup (xem HUONG-DAN-SU-DUNG.md)
# =============================================================================

# Đường dẫn đích trên Drive cho một loại dữ liệu (backups | logs)
cloud_path() { printf '%s/%s/%s' "${GDRIVE_REMOTE%/}" "$(hostname -s 2>/dev/null || hostname)" "$1"; }

# cloud_ready — đã cài rclone, đã đặt GDRIVE_REMOTE và remote tồn tại trong cấu hình rclone
cloud_ready() {
  [[ -n ${GDRIVE_REMOTE:-} ]] || return 1
  has rclone || return 1
  rclone listremotes 2>/dev/null | grep -qx "${GDRIVE_REMOTE%%:*}:"
}

# cloud_explain — lý do chưa dùng được Google Drive (in ra cho người dùng)
cloud_explain() {
  if [[ -z ${GDRIVE_REMOTE:-} ]]; then echo "chưa đặt GDRIVE_REMOTE (chạy: $PROG backup cloud-setup)"
  elif ! has rclone; then echo "chưa cài rclone ($(pkg_hint rclone))"
  else echo "rclone chưa có remote '${GDRIVE_REMOTE%%:*}' (chạy: $PROG backup cloud-setup)"; fi
}

# cloud_upload <file...> <loại: backups|logs> — tải file lên Drive, trả về 0 nếu thành công
cloud_upload() {
  local kind=${*: -1} dest f
  local -a files=("${@:1:$#-1}")
  dest=$(cloud_path "$kind")
  if [[ $DRY_RUN == 1 ]]; then
    for f in "${files[@]}"; do run rclone copy "$f" "$dest/"; done
    return 0
  fi
  cloud_ready || { log_warn "Bỏ qua Google Drive: $(cloud_explain)"; return 1; }
  for f in "${files[@]}"; do
    # --retries: mạng chập chờn vẫn tải được; --log-level ERROR: chỉ in lỗi
    if ! rclone copy "$f" "$dest/" --retries 3 --low-level-retries 5 --log-level ERROR 2>>"$LOG_DIR/rclone.log"; then
      log_error "Tải lên Google Drive thất bại: $(basename "$f") (xem $LOG_DIR/rclone.log)"
      return 1
    fi
  done
  _log_write CMD "rclone copy ${files[*]} $dest/"
  return 0
}

# cloud_prune <loại> <số ngày> — xoá file cũ hơn N ngày trên Drive (0 = giữ hết)
cloud_prune() {
  local kind=$1 days=${2:-0}
  ((days > 0)) || return 0
  cloud_ready || return 0
  run rclone delete "$(cloud_path "$kind")" --min-age "${days}d" --log-level ERROR 2>>"$LOG_DIR/rclone.log" || true
}

# cloud_list <loại> — liệt kê file trên Drive (kích thước, thời gian, tên)
cloud_list() {
  cloud_ready || { log_warn "Google Drive: $(cloud_explain)"; return 1; }
  rclone lsl "$(cloud_path "$1")" 2>/dev/null | sort -k2,3 -r | awk '{ printf "  %10.1f KB  %s %s  %s\n", $1 / 1024, $2, substr($3, 1, 8), $4 }'
}
