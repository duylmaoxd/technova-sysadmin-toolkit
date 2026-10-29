#!/usr/bin/env bash
# =============================================================================
#  install.sh — Cài đặt / gỡ bỏ LinuxAdmin Toolkit
#
#    sudo ./install.sh               cài vào /opt/sysadmin-toolkit + lệnh "sysadmin"
#    sudo ./install.sh --deps        cài thêm gói phụ thuộc (dialog, sysstat, at, cron, msmtp, curl...)
#    sudo ./install.sh --timers      bật systemd timer: kiểm tra & cảnh báo 5 phút/lần + sao lưu hằng ngày
#    sudo ./install.sh --uninstall   gỡ cài đặt (giữ nguyên các bản sao lưu)
#
#  Không cài cũng dùng được: chạy trực tiếp ./sysadmin.sh trong thư mục này.
# =============================================================================
set -Eeuo pipefail

SRC=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
PREFIX=/opt/sysadmin-toolkit
BIN=/usr/local/bin/sysadmin
COMPLETION=/etc/bash_completion.d/sysadmin
TOOLKIT_DIR=$SRC
PROG=install.sh
# shellcheck source=lib/common.sh
source "$SRC/lib/common.sh"

usage() {
  sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^#  //; s/^#//'
}

install_completion() {
  write_file "$COMPLETION" 644 <<'EOF'
# bash-completion cho LinuxAdmin Toolkit — cài bởi install.sh
_sysadmin_complete() {
  local cur=${COMP_WORDS[COMP_CWORD]} w
  local -a args=()
  for w in "${COMP_WORDS[@]:1:COMP_CWORD-1}"; do [[ $w == -* ]] || args+=("$w"); done
  case ${#args[@]} in
    0) mapfile -t COMPREPLY < <(compgen -W "$(sysadmin __complete modules 2>/dev/null) --tui --cli --dry-run --yes --help" -- "$cur") ;;
    1) mapfile -t COMPREPLY < <(compgen -W "$(sysadmin __complete actions "${args[0]}" 2>/dev/null)" -- "$cur") ;;
  esac
}
complete -F _sysadmin_complete sysadmin
EOF
}

do_install() {
  local f
  header "Cài $TOOLKIT_NAME v$TOOLKIT_VERSION vào $PREFIX"
  if [[ $SRC != "$PREFIX" ]]; then
    run mkdir -p "$PREFIX/config" "$PREFIX/logs" "$PREFIX/reports"
    # Mã nguồn: luôn cập nhật bản mới
    run cp -a "$SRC/sysadmin.sh" "$SRC/install.sh" "$SRC/lib" "$SRC/modules" "$SRC/systemd" "$PREFIX/"
    [[ -f $SRC/README.md ]] && run cp -a "$SRC/README.md" "$PREFIX/"
    # Cấu hình: chỉ chép file chưa có → cài lại không ghi đè cấu hình đang dùng
    for f in "$SRC"/config/*; do
      if [[ -e $PREFIX/config/$(basename "$f") ]]; then status INFO "Giữ nguyên cấu hình cũ: config/$(basename "$f")"
      else run cp -a "$f" "$PREFIX/config/"; fi
    done
  fi
  # Quyền: chỉ root được sửa mã nguồn (vì cron/systemd sẽ chạy nó bằng root)
  run chown -R root:root "$PREFIX"
  run find "$PREFIX" -type d -exec chmod 755 {} +
  run find "$PREFIX" -type f -exec chmod 644 {} +
  run chmod 755 "$PREFIX/sysadmin.sh" "$PREFIX/install.sh"
  [[ -e $PREFIX/config/msmtprc ]] && run chmod 600 "$PREFIX/config/msmtprc"
  status OK "Đã chép mã nguồn và cấu hình"
  run ln -sfn "$PREFIX/sysadmin.sh" "$BIN"
  status OK "Tạo lệnh: $BIN → $PREFIX/sysadmin.sh"
  if [[ -d $(dirname "$COMPLETION") ]]; then
    install_completion
    status OK "Tự hoàn thành lệnh bằng phím Tab: $COMPLETION"
  fi
  syslog_event "INSTALL: $TOOLKIT_NAME $TOOLKIT_VERSION -> $PREFIX"
}

# Gói phụ thuộc cho 5 chức năng (tên gói tự đổi theo apt / dnf)
install_deps() {
  local -a list=(dialog sysstat tree at cron psmisc rsync curl)
  detect_distro
  if [[ $DISTRO_FAMILY == debian ]]; then list+=(msmtp whiptail); else list+=(s-nail newt); fi
  header "Cài gói phụ thuộc: ${list[*]}"
  if [[ $PKG_MGR == apt ]]; then run apt-get update -qq; fi
  pkg_install "${list[@]}" || return 1
  if [[ $DRY_RUN != 1 ]] && has systemctl; then
    systemctl enable --now atd >/dev/null 2>&1 || true
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
  fi
}

do_uninstall() {
  header "Gỡ $TOOLKIT_NAME"
  confirm "Gỡ toolkit khỏi $PREFIX (các bản sao lưu được giữ lại)?" || { log_warn "Đã huỷ."; exit 0; }
  if [[ -x $PREFIX/sysadmin.sh ]]; then
    if [[ -e /etc/systemd/system/toolkit-monitor.timer ]]; then run "$PREFIX/sysadmin.sh" --yes scheduler timers-remove || true; fi
    run "$PREFIX/sysadmin.sh" --yes scheduler remove || true
  fi
  run rm -f "$BIN" "$COMPLETION"
  run rm -rf "$PREFIX"
  log_ok "Đã gỡ. Bản sao lưu (mặc định /var/backups/sysadmin-toolkit) và lab (/var/lib/sysadmin-toolkit) vẫn còn."
}

main() {
  local deps=0 timers=0 uninstall=0
  while (($#)); do
    case $1 in
      --deps) deps=1 ;;
      --timers) timers=1 ;;
      --uninstall) uninstall=1 ;;
      --prefix) PREFIX=${2:?Thiếu thư mục}; shift ;;
      -n | --dry-run) DRY_RUN=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "Tuỳ chọn không hợp lệ: $1 (xem: ./install.sh --help)" ;;
    esac
    shift
  done
  ((EUID == 0)) || [[ $DRY_RUN == 1 ]] || die "Cần quyền root: sudo ./install.sh $*"
  if ((uninstall)); then do_uninstall; return; fi
  do_install
  local -a opt=(--yes)
  [[ $DRY_RUN == 1 ]] && opt+=(--dry-run)
  if ((deps)); then install_deps || log_warn "Một số gói chưa cài được."; fi
  if ((timers)); then run "$PREFIX/sysadmin.sh" "${opt[@]}" scheduler timers-install; fi
  cat <<EOF

${C_GREEN}${C_BOLD}Cài đặt xong!${C_RESET}
  sysadmin                 mở toolkit (hỏi chọn Giao diện hoặc CLI)
  sudo sysadmin --tui      mở giao diện menu với quyền root
  sysadmin help            xem toàn bộ lệnh
  Cấu hình: $PREFIX/config/toolkit.conf
EOF
  ((deps)) || printf '  Cài gói phụ thuộc: sudo ./install.sh --deps\n'
  ((timers)) || printf '  Bật giám sát + sao lưu tự động: sudo ./install.sh --timers  (hoặc: sudo sysadmin scheduler install)\n'
}

main "$@"
