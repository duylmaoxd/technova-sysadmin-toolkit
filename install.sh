#!/usr/bin/env bash
# =============================================================================
#  install.sh — Cài đặt / gỡ bỏ LinuxAdmin Toolkit
#
#    sudo ./install.sh               cài vào /opt/sysadmin-toolkit + lệnh "sysadmin"
#    sudo ./install.sh --deps        cài thêm gói phụ thuộc (dialog, sysstat, at, cron, msmtp, curl...)
#    sudo ./install.sh --timers      bật systemd timer: kiểm tra & cảnh báo 5 phút/lần + sao lưu hằng ngày
#    sudo ./install.sh --server      TRIỂN KHAI LÊN MÁY CHỦ THẬT: cài gói + SSH, hỏi vài câu rồi tự cấu hình
#                                    (thư mục sao lưu, IP tin cậy, tự chặn IP, lịch tự động, chống ngủ...)
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
  sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^#  //; s/^#//'
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
  local -a list=(openssh-server iproute2 dialog sysstat tree at cron psmisc rsync curl rclone iptables)
  detect_distro
  if [[ $DISTRO_FAMILY == debian ]]; then list+=(msmtp whiptail); else list+=(s-nail newt); fi
  header "Cài gói phụ thuộc: ${list[*]}"
  if [[ $PKG_MGR == apt ]]; then run apt-get update -qq; fi
  pkg_install "${list[@]}" || return 1
  if [[ $DRY_RUN != 1 ]] && has systemctl; then
    systemctl enable --now atd >/dev/null 2>&1 || true
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
  fi
}

# ask <câu hỏi> <mặc định> — hỏi một giá trị (Enter = mặc định; --yes hoặc không có terminal → mặc định)
ask() {
  local ans
  if [[ $ASSUME_YES == 1 || ! -t 0 ]]; then printf '%s' "$2"; return 0; fi
  read -r -p "  $1 [$2]: " ans </dev/tty || true
  printf '%s' "${ans:-$2}"
}
# ask_yn <câu hỏi> <y|n> — 0 nếu trả lời có
ask_yn() { [[ $(ask "$1 (y/n)" "$2") == [yYcC]* ]]; }

# Triển khai lên máy chủ thật: hỏi vài câu rồi cấu hình toolkit cho phù hợp với máy
server_setup() {
  local laptop=0 dedicated admin_ip ts="" sources wl sched f
  header "Cấu hình cho máy chủ thật: $(hostname)"
  compgen -G '/sys/class/power_supply/BAT*' >/dev/null && laptop=1
  # IP của người đang SSH vào để cài (sudo xoá biến SSH_CLIENT nên đọc từ "who am i")
  admin_ip=$(who -m 2>/dev/null | sed -nE 's/.*\(([0-9a-fA-F:.]+)\).*/\1/p' | head -n 1)
  ip link show tailscale0 >/dev/null 2>&1 && ts="100.64.0.0/10"
  kv "Địa chỉ IP máy này" "$(hostname -I 2>/dev/null | xargs || echo '?')"
  kv "Bạn đang SSH vào từ" "${admin_ip:-không (đang ngồi trực tiếp tại máy)}"
  kv "Tailscale" "$([[ -n $ts ]] && echo "có — tin cậy cả mạng $ts" || echo 'chưa cài')"
  ((laptop)) && kv "Loại máy" "laptop (có pin)"
  echo

  if ask_yn "Máy này CHUYÊN làm máy chủ? (n = máy cá nhân dùng hằng ngày)" y; then dedicated=1; else dedicated=0; fi
  if ((dedicated)); then sources="/etc /home /srv/technova"; else sources="/etc /srv/technova"; fi
  ((dedicated)) || status INFO "Máy cá nhân: không sao lưu cả /home (tránh vượt 15 GB Google Drive miễn phí)."
  sources=$(ask "Thư mục cần sao lưu" "$sources")
  wl=$(ask "IP / dải mạng tin cậy, không bao giờ bị chặn" "$(xargs <<<"127.0.0.1 ::1 $admin_ip $ts")")
  # Đọc cấu hình đã cài (dry-run trên máy chưa cài: đọc bản mẫu trong mã nguồn)
  TOOLKIT_CONF="$PREFIX/config/toolkit.conf"
  [[ -r $TOOLKIT_CONF ]] || TOOLKIT_CONF="$SRC/config/toolkit.conf"
  load_config
  config_set BACKUP_SOURCES "$sources"
  config_set IDS_WHITELIST "$wl"
  if ask_yn "Tự động CHẶN IP dò mật khẩu SSH bằng tường lửa (AUTO_BAN)?" y; then config_set AUTO_BAN yes; else config_set AUTO_BAN no; fi

  # SSH: không cho root đăng nhập trực tiếp, giới hạn số lần thử mỗi kết nối
  f=/etc/ssh/sshd_config.d/10-technova.conf
  if [[ -d /etc/ssh/sshd_config.d ]] && ask_yn "Siết SSH: cấm root đăng nhập trực tiếp, tối đa 4 lần thử/kết nối?" y; then
    printf '# Tạo bởi LinuxAdmin Toolkit (install.sh --server)\nPermitRootLogin no\nMaxAuthTries 4\n' | write_file "$f" 644
    if [[ $DRY_RUN == 1 ]] || sshd -t 2>/dev/null; then
      run systemctl reload ssh 2>/dev/null || run systemctl reload sshd 2>/dev/null || true
      status OK "SSH: PermitRootLogin no, MaxAuthTries 4 ($f)"
    else
      run rm -f "$f"; log_warn "Cấu hình SSH không hợp lệ — đã hoàn tác."
    fi
  fi

  # Laptop làm máy chủ: gập máy không được ngủ
  if ((laptop)) && ask_yn "Laptop: gập máy vẫn chạy (không ngủ)?" y; then
    run mkdir -p /etc/systemd/logind.conf.d
    printf '# Tạo bởi LinuxAdmin Toolkit — laptop làm máy chủ\n[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' |
      write_file /etc/systemd/logind.conf.d/technova-server.conf 644
    status OK "Gập máy không ngủ — có hiệu lực sau lần khởi động lại kế tiếp"
  fi

  # Lịch tự động: systemd timer (máy có systemd) hoặc cron
  local -a opt=(--yes)
  [[ $DRY_RUN == 1 ]] && opt+=(--dry-run)
  if [[ -d /run/systemd/system ]]; then sched=$(ask "Lập lịch bằng 'timer' (systemd) hay 'cron'" timer); else sched=cron; fi
  if [[ $sched == timer ]]; then
    run "$PREFIX/sysadmin.sh" "${opt[@]}" scheduler remove >/dev/null 2>&1 || true
    run "$PREFIX/sysadmin.sh" "${opt[@]}" scheduler timers-install
  else
    if has systemctl; then run "$PREFIX/sysadmin.sh" "${opt[@]}" scheduler timers-remove >/dev/null 2>&1 || true; fi
    run "$PREFIX/sysadmin.sh" "${opt[@]}" scheduler install
  fi
  # Trạng thái chuẩn cho IDS — chụp SAU khi đã sửa cấu hình SSH ở trên
  run "$PREFIX/sysadmin.sh" "${opt[@]}" alert baseline
  syslog_event "SERVER SETUP: backup=[$sources] whitelist=[$wl] sched=$sched"
  cat <<EOF

${C_GREEN}${C_BOLD}Máy chủ đã sẵn sàng.${C_RESET} Việc còn lại (mỗi việc làm một lần):
  1. sudo sysadmin alert setup-telegram     nhận cảnh báo trên điện thoại
     sudo sysadmin alert test               thử gửi một tin
  2. rclone authorize "drive"               (chạy trên laptop có trình duyệt) rồi:
     sudo sysadmin backup cloud-setup       nối Google Drive cho backup & log
  3. sudo sysadmin users create             tạo nhân viên từ config/users.csv
     sudo sysadmin users setup-dirs         tạo /srv/technova cho các phòng ban
  Từ máy khác: ssh <user>@$(hostname -I 2>/dev/null | awk '{ print $1 }')
EOF
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
  local deps=0 timers=0 uninstall=0 server=0
  while (($#)); do
    case $1 in
      --deps) deps=1 ;;
      --timers) timers=1 ;;
      --uninstall) uninstall=1 ;;
      --server) server=1 deps=1 ;;
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
  if ((server)); then server_setup; return; fi
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
  printf '  Triển khai đầy đủ lên máy chủ thật: sudo ./install.sh --server\n'
}

main "$@"
