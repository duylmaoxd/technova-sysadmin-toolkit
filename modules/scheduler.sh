#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # biến toàn cục dùng chung giữa các file
# =============================================================================
#  modules/scheduler.sh — CHỨC NĂNG 5: TỰ ĐỘNG HOÁ BẢO DƯỠNG & LẬP LỊCH
#  Nhu cầu của Tech Lead: máy chủ tự chăm sóc mình kể cả khi anh không online.
#  Lịch mặc định cài vào crontab (trong một "khối" riêng giữa 2 dòng đánh dấu,
#  cài lại / gỡ bỏ không ảnh hưởng job khác):
#    02:00 hằng ngày   sao lưu dữ liệu (backup run)
#    03:30 hằng ngày   bảo dưỡng: dọn file tạm, log cũ, cache gói, xoay vòng backup
#    mỗi 5 phút        kiểm tra sự cố & gửi cảnh báo (alert check)
#    07:00 thứ Hai     báo cáo hệ thống tuần (monitor report)
#  Tương đương bằng systemd timer: scheduler timers-install. Hẹn 1 lần: at.
# =============================================================================

register_module scheduler 5 "Tự động hoá bảo dưỡng & lập lịch (cron, at, timer)"
register_action list      ""  "Xem mọi lịch: crontab, /etc/cron.d, systemd timer, hàng đợi at"
register_action install   "r" "Cài lịch tự động: sao lưu, bảo dưỡng hằng ngày, cảnh báo 5 phút, báo cáo tuần" "Lịch sao lưu=$CRON_BACKUP" "Lịch kiểm tra & cảnh báo=$CRON_CHECK" "Lịch báo cáo=$CRON_REPORT" "Lịch bảo dưỡng=$CRON_MAINT" "Lịch kiểm tra & upload log=$CRON_LOGS"
register_action maintenance "rd" "Bảo dưỡng ngay: dọn /tmp, log journald cũ, cache gói, core dump, xoay vòng backup" "Xoá file tạm cũ hơn (ngày)=$MAINT_TMP_DAYS"
register_action remove    "r" "Gỡ toàn bộ lịch cron do toolkit tạo"
register_action add       ""  "Thêm một cron job tuỳ chỉnh" "Lịch (5 trường)=*/10 * * * *" "Lệnh=date >> /tmp/cron-test.log"
register_action explain   ""  "Giải thích một biểu thức cron bằng tiếng Việt" "Biểu thức cron=*/15 8-17 * * 1-5"
register_action at        ""  "Hẹn chạy MỘT LẦN bằng at" "Thời điểm=now + 2 minutes" "Lệnh=$(shell_quote "$SELF") --no-color monitor report"
register_action at-list   ""  "Các công việc at đang chờ"
register_action at-remove ""  "Huỷ một công việc at" "Mã công việc=@_pick_atjob"
register_action log       ""  "Log thực thi của các job (cron.log của toolkit + log dịch vụ cron)" "Số dòng=30"
register_action timers-install "rd" "Dùng systemd timer thay cron (4 timer: cảnh báo 5 phút, sao lưu + log 02:00, bảo dưỡng 03:30, báo cáo thứ Hai)"
register_action timers-remove  "rd" "Gỡ các systemd timer của toolkit"

CRON_BEGIN="# >>> sysadmin-toolkit >>>"
CRON_END="# <<< sysadmin-toolkit <<<"

_cron_current() { crontab -l 2>/dev/null || true; }

# Các dòng NẰM TRONG khối của toolkit
_cron_block() {
  _cron_current | awk -v b="$CRON_BEGIN" -v e="$CRON_END" '$0 == b { f = 1; next } $0 == e { f = 0; next } f'
}

# Các dòng NGOÀI khối (job riêng của người dùng — giữ nguyên)
_cron_outside() {
  _cron_current | awk -v b="$CRON_BEGIN" -v e="$CRON_END" '$0 == b { f = 1; next } $0 == e { f = 0; next } !f'
}

# _cron_write <nội dung khối> — ghi lại crontab = phần ngoài khối + khối mới
_cron_write() {
  local block=$1 new
  new=$(_cron_outside)
  if [[ -n $block ]]; then
    new+="${new:+$'\n'}$CRON_BEGIN"$'\n'"$block"$'\n'"$CRON_END"
  fi
  if [[ -z $(trim "$new") ]]; then
    if [[ $DRY_RUN == 1 ]]; then run crontab -r; else crontab -r 2>/dev/null || true; fi
  else
    if [[ $DRY_RUN == 1 ]]; then
      printf '%s[DRY-RUN]%s crontab mới sẽ là:\n' "$C_MAGENTA" "$C_RESET"
      sed 's/^/    │ /' <<<"$new"
    fi
    run_input "$new" crontab -
  fi
}

# _cron_valid <biểu thức> — kiểm tra cú pháp 5 trường (hoặc @daily, @reboot...)
_cron_valid() {
  local e=$1 x
  local -a f
  [[ $e =~ ^@(reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)$ ]] && return 0
  read -r -a f <<<"$e"
  ((${#f[@]} == 5)) || return 1
  for x in "${f[@]}"; do
    [[ $x =~ ^(\*|[0-9]+(-[0-9]+)?|[A-Za-z]{3})(/[0-9]+)?(,([0-9]+(-[0-9]+)?|[A-Za-z]{3})(/[0-9]+)?)*$ ]] || return 1
  done
}

_cron_daemon_check() {
  local s
  has systemctl && [[ -d /run/systemd/system ]] || return 0
  for s in cron crond cronie; do
    if systemctl is-active "$s" >/dev/null 2>&1; then status OK "Dịch vụ $s đang chạy"; return 0; fi
  done
  status WARN "Không thấy dịch vụ cron đang chạy — bật: sudo systemctl enable --now cron (Debian) / crond (RHEL)"
}

_pick_atjob() {
  has atq || return 0
  atq 2>/dev/null | awk '{ id = $1; $1 = ""; sub(/^ /, ""); printf "%s\t%s\n", id, $0 }'
}

scheduler_list() {
  header "Crontab của $(id -un) (crontab -l)"
  if has crontab; then
    _cron_current | grep -v '^[[:space:]]*$' | sed 's/^/  /' || printf '  (trống)\n'
  else
    log_warn "Chưa cài cron ($(pkg_hint cron))"
  fi
  header "Lịch hệ thống (/etc/crontab, /etc/cron.d/)"
  grep -hEv '^[[:space:]]*(#|$)' /etc/crontab /etc/cron.d/* 2>/dev/null | grep -v '^[A-Z_]*=' | take 20 | sed 's/^/  /' || true
  kv "/etc/cron.daily" "$(ls_names /etc/cron.daily)"
  kv "/etc/cron.weekly" "$(ls_names /etc/cron.weekly)"
  if has systemctl && [[ -d /run/systemd/system ]]; then
    header "systemd timer (cách lập lịch hiện đại)"
    systemctl list-timers --no-pager 2>/dev/null | take 15 || true
  fi
  header "Hàng đợi at (atq)"
  if has atq; then
    local out
    out=$(atq 2>/dev/null || true)
    if [[ -n $out ]]; then sed 's/^/  /' <<<"$out"; else printf '  (không có công việc nào)\n'; fi
  else
    printf '  Chưa cài at (%s)\n' "$(pkg_hint at)"
  fi
  cat <<'EOF'

  Cú pháp một dòng crontab:
  ┌───────────── phút (0-59)
  │ ┌─────────── giờ (0-23)
  │ │ ┌───────── ngày trong tháng (1-31)
  │ │ │ ┌─────── tháng (1-12)
  │ │ │ │ ┌───── thứ trong tuần (0-7; 0 và 7 = Chủ nhật)
  │ │ │ │ │
  * * * * *  lệnh cần chạy
EOF
}

scheduler_install() {
  local b=${1:-$CRON_BACKUP} c=${2:-$CRON_CHECK} r=${3:-$CRON_REPORT} mt=${4:-$CRON_MAINT} lg=${5:-$CRON_LOGS} x self log block custom
  need_cmd crontab cron || return 1
  for x in "$b" "$c" "$r" "$mt" "$lg"; do _cron_valid "$x" || die "Biểu thức cron không hợp lệ: '$x'"; done
  if ((EUID != 0)); then
    log_warn "Đang cài vào crontab của $(id -un). Sao lưu /etc cần root → nên chạy: sudo $PROG scheduler install"
  elif [[ $(stat -c %u "$TOOLKIT_DIR") != 0 ]]; then
    log_warn "Cron của root sẽ chạy script trong thư mục của user thường ($TOOLKIT_DIR) — nên cài vào /opt bằng install.sh."
  fi
  if has systemctl && systemctl is-enabled toolkit-backup.timer >/dev/null 2>&1; then
    log_warn "Timer systemd toolkit-backup đang bật → sao lưu sẽ chạy 2 lần. Gỡ: $PROG scheduler timers-remove"
  fi
  self=$(shell_quote "$SELF")
  log=$(shell_quote "$LOG_DIR/cron.log")
  custom=$(_cron_block | grep '# tk-custom$' || true)
  block="# Sao lưu hằng ngày
$b $self --no-color --yes backup run >> $log 2>&1
# Kiểm tra log & đưa gói log lên Google Drive
$lg $self --no-color --yes monitor log-upload >> $log 2>&1
# Bảo dưỡng hằng ngày: dọn file tạm, log cũ, cache gói
$mt $self --no-color --yes scheduler maintenance >> $log 2>&1
# Kiểm tra tài nguyên + phát hiện tấn công & gửi cảnh báo
$c $self --no-color alert check >> $log 2>&1
# Báo cáo hệ thống hằng tuần (HTML trong thư mục reports/)
$r $self --no-color monitor report >> $log 2>&1"
  [[ -n $custom ]] && block+=$'\n'"$custom"
  header "Khối lịch cài vào crontab của $(id -un)"
  sed 's/^/  /' <<<"$block"
  _cron_write "$block"
  [[ $DRY_RUN == 1 ]] && return 0
  log_ok "Đã cài lịch. Kiểm tra: crontab -l · log chạy job: $LOG_DIR/cron.log"
  syslog_event "SCHEDULER INSTALL: backup '$b', maintenance '$mt', check '$c', report '$r'"
  _cron_daemon_check
}

scheduler_remove() {
  need_cmd crontab cron || return 1
  if [[ -z $(_cron_block) ]]; then log_info "Crontab của $(id -un) không có lịch nào của toolkit."; return 0; fi
  _cron_write ""
  [[ $DRY_RUN == 1 ]] || log_ok "Đã gỡ khối lịch của toolkit khỏi crontab của $(id -un)."
}

scheduler_add() {
  local sched=${1:-} cmd=${2:-} block pc='\%'
  need_cmd crontab cron || return 1
  _cron_valid "$sched" || die "Biểu thức cron không hợp lệ: '$sched' (cần 5 trường, ví dụ: */10 * * * *)"
  [[ -n $(trim "$cmd") ]] || die "Chưa nhập lệnh."
  cmd=${cmd//\%/"$pc"} # trong crontab, dấu % mang nghĩa xuống dòng → phải viết \%
  block=$(_cron_block)
  block+="${block:+$'\n'}$sched $cmd # tk-custom"
  _cron_write "$block"
  [[ $DRY_RUN == 1 ]] || log_ok "Đã thêm job: $sched $cmd"
  scheduler_explain "$sched"
}

# Mô tả một trường của biểu thức cron
_cron_field() {
  local v=$1 unit=$2
  case $v in
    '*') printf 'mọi %s' "$unit" ;;
    '*/'*) printf 'cứ mỗi %s %s' "${v#*/}" "$unit" ;;
    *,*) printf '%s %s' "$unit" "${v//,/, }" ;;
    */*) printf '%s từ %s, bước nhảy %s' "$unit" "${v%/*}" "${v#*/}" ;;
    *-*) printf '%s từ %s đến %s' "$unit" "${v%-*}" "${v#*-}" ;;
    *) printf '%s %s' "$unit" "$v" ;;
  esac
}

# Đổi số thứ trong tuần thành tên (0/7 = Chủ nhật)
_dow_text() {
  local s=$1 out=""
  local -a names=("Chủ nhật" "Thứ Hai" "Thứ Ba" "Thứ Tư" "Thứ Năm" "Thứ Sáu" "Thứ Bảy" "Chủ nhật")
  [[ $s == */* || $s == '*' ]] && { _cron_field "$s" "thứ"; return 0; }
  while [[ $s =~ ^([^0-7]*)([0-7])(.*)$ ]]; do
    out+="${BASH_REMATCH[1]}${names[BASH_REMATCH[2]]}"
    s=${BASH_REMATCH[3]}
  done
  out+=$s
  out=${out//-/ đến }
  printf '%s' "${out//,/, }"
}

scheduler_explain() {
  local e=${1:-*/15 8-17 * * 1-5}
  local -a f
  _cron_valid "$e" || die "Biểu thức cron không hợp lệ: '$e'"
  header "Giải thích: $e"
  case $e in
    @reboot) kv "Ý nghĩa" "chạy một lần mỗi khi máy khởi động"; return 0 ;;
    @hourly) kv "Ý nghĩa" "đầu mỗi giờ (= 0 * * * *)"; return 0 ;;
    @daily | @midnight) kv "Ý nghĩa" "00:00 mỗi ngày (= 0 0 * * *)"; return 0 ;;
    @weekly) kv "Ý nghĩa" "00:00 Chủ nhật hằng tuần (= 0 0 * * 0)"; return 0 ;;
    @monthly) kv "Ý nghĩa" "00:00 ngày 1 hằng tháng (= 0 0 1 * *)"; return 0 ;;
    @yearly | @annually) kv "Ý nghĩa" "00:00 ngày 1/1 hằng năm (= 0 0 1 1 *)"; return 0 ;;
  esac
  read -r -a f <<<"$e"
  kv "Phút" "$(_cron_field "${f[0]}" phút)"
  kv "Giờ" "$(_cron_field "${f[1]}" giờ)"
  kv "Ngày trong tháng" "$(_cron_field "${f[2]}" ngày)"
  kv "Tháng" "$(_cron_field "${f[3]}" tháng)"
  kv "Thứ trong tuần" "$(_dow_text "${f[4]}")"
  # Một số mẫu hay gặp → câu tóm tắt
  local sum=""
  if [[ ${f[0]} =~ ^[0-9]+$ && ${f[1]} =~ ^[0-9]+$ ]]; then
    printf -v sum 'lúc %02d:%02d' "$((10#${f[1]}))" "$((10#${f[0]}))"
    if [[ ${f[2]} == '*' && ${f[3]} == '*' && ${f[4]} == '*' ]]; then sum+=" mỗi ngày"
    elif [[ ${f[2]} == '*' && ${f[3]} == '*' ]]; then sum+=" vào $(_dow_text "${f[4]}")"
    elif [[ ${f[3]} == '*' && ${f[4]} == '*' ]]; then sum+=" ngày ${f[2]} hằng tháng"; fi
  elif [[ ${f[0]} == '*/'* && ${f[1]} == '*' && ${f[2]} == '*' && ${f[3]} == '*' && ${f[4]} == '*' ]]; then
    sum="cứ ${f[0]#*/} phút chạy một lần, suốt ngày đêm"
  fi
  [[ -n $sum ]] && kv "Tóm tắt" "$sum"
  return 0
}

scheduler_at() {
  local when=${1:-now + 2 minutes} cmd=${2:-}
  need_cmd at at || return 1
  [[ -n $(trim "$cmd") ]] || die "Chưa nhập lệnh."
  if has systemctl && [[ -d /run/systemd/system ]] && ! systemctl is-active atd >/dev/null 2>&1; then
    log_warn "Dịch vụ atd chưa chạy — bật: sudo systemctl enable --now atd"
  fi
  header "Hẹn chạy một lần: \"$when\""
  printf '  Lệnh: %s\n' "$cmd"
  run_input "$cmd" at "$when"
  [[ $DRY_RUN == 1 ]] && return 0
  scheduler_at_list
  printf '\n%sVí dụ thời điểm khác: "23:30", "now + 1 hour", "9:00 tomorrow", "noon friday"%s\n' "$C_DIM" "$C_RESET"
}

# Lệnh bên trong một công việc at (bản at mới bọc lệnh trong heredoc "marcinDELIMITER")
_at_cmd() {
  at -c "$1" 2>/dev/null | awk '
    /<< .marcinDELIMITER/ { g = 1; next }
    /^marcinDELIMITER/ { g = 0; next }
    g && NF { cmd = cmd (cmd != "" ? "; " : "") $0 }
    NF { last = $0 }
    END { print (cmd != "" ? cmd : last) }' | cut -c1-120
}

scheduler_at_list() {
  local id rest
  need_cmd atq at || return 1
  header "Công việc at đang chờ"
  if [[ -z $(atq 2>/dev/null) ]]; then printf '  (không có)\n'; return 0; fi
  while read -r id rest; do
    printf '  #%s  %s\n' "$id" "$rest"
    printf '      → %s\n' "$(_at_cmd "$id")"
  done < <(atq | sort -n)
}

scheduler_at_remove() {
  local job=$1
  need_cmd atrm at || return 1
  is_int "$job" || die "Mã công việc không hợp lệ: $job"
  run atrm "$job"
  [[ $DRY_RUN == 1 ]] || log_ok "Đã huỷ công việc at #$job"
}

scheduler_log() {
  local n=${1:-30}
  is_int "$n" || die "Số dòng không hợp lệ"
  header "Kết quả các job của toolkit ($LOG_DIR/cron.log)"
  if [[ -s $LOG_DIR/cron.log ]]; then tail -n "$n" "$LOG_DIR/cron.log"; else printf '  (chưa có — job chưa chạy lần nào)\n'; fi
  header "Log dịch vụ cron"
  if has journalctl && [[ -d /run/systemd/system ]]; then
    journalctl -u cron -u crond --no-pager -n "$n" 2>/dev/null || true
  else
    grep -h CRON /var/log/syslog /var/log/cron 2>/dev/null | tail -n "$n" || true
  fi
}

# ---------------------------------------------------------- BẢO DƯỠNG ---
_disk_used_kb() { df -Pk / | awk 'NR == 2 { print $3 }'; }

scheduler_maintenance() {
  local days=${1:-$MAINT_TMP_DAYS} before after n
  require_root
  is_int "$days" && ((days >= 1)) || die "Số ngày phải là số nguyên ≥ 1"
  detect_distro
  before=$(_disk_used_kb)
  header "Bảo dưỡng máy chủ $(hostname) — $(date '+%d/%m/%Y %H:%M')"

  # 1. File tạm cũ trong /tmp và /var/tmp (bỏ qua file đang mở bởi phiên đăng nhập: chỉ xoá file thường)
  n=$({ find /tmp /var/tmp -xdev -type f -mtime +"$days" 2>/dev/null || true; } | wc -l)
  if [[ $DRY_RUN == 1 ]]; then run find /tmp /var/tmp -xdev -type f -mtime +"$days" -delete
  else find /tmp /var/tmp -xdev -type f -mtime +"$days" -delete 2>/dev/null || true; fi
  status OK "1. Xoá $n file tạm cũ hơn $days ngày trong /tmp, /var/tmp"

  # 2. Log journald cũ
  if has journalctl; then
    run journalctl --vacuum-time="$MAINT_JOURNAL_KEEP" >/dev/null 2>&1 || true
    status OK "2. Giữ log journald trong $MAINT_JOURNAL_KEEP gần nhất ($(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -n 1 || echo '?'))"
  fi

  # 3. Cache gói phần mềm đã tải về
  case $PKG_MGR in
    apt) run apt-get clean -qq && run env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null ;;
    dnf | yum) run "$PKG_MGR" clean packages -q >/dev/null ;;
  esac
  status OK "3. Dọn cache gói ($PKG_MGR) & gói phụ thuộc thừa"

  # 4. Core dump cũ của chương trình bị crash
  if [[ -d /var/lib/systemd/coredump ]]; then
    run find /var/lib/systemd/coredump -type f -mtime +"$days" -delete 2>/dev/null || true
    status OK "4. Xoá core dump cũ hơn $days ngày"
  fi

  # 5. Xoay vòng bản sao lưu
  if declare -F backup_rotate >/dev/null && [[ -d $BACKUP_DEST ]]; then
    backup_rotate "$BACKUP_KEEP" "$BACKUP_DEST"
    status OK "5. Xoay vòng bản sao lưu (giữ $BACKUP_KEEP bản)"
  fi

  # 6. Kiểm tra nhanh sau bảo dưỡng
  after=$(_disk_used_kb)
  [[ $DRY_RUN == 1 ]] && return 0
  status INFO "Dung lượng giải phóng trên /: $(human_kb $((before > after ? before - after : 0)))"
  if [[ -f /var/run/reboot-required ]]; then status WARN "Máy chủ cần khởi động lại để áp dụng bản cập nhật (reboot-required)"; fi
  syslog_event "SCHEDULER MAINTENANCE: xong, giải phóng $(human_kb $((before > after ? before - after : 0)))"
}

# ------------------------------------------------------- SYSTEMD TIMER ---
# Các systemd unit của toolkit — tương đương 5 job cron của "scheduler install"
TK_TIMERS=(toolkit-monitor.timer toolkit-backup.timer toolkit-maintenance.timer toolkit-report.timer)
TK_UNITS=()
for _t in "${TK_TIMERS[@]}"; do TK_UNITS+=("${_t%.timer}.service" "$_t"); done
unset _t

scheduler_timers_install() {
  local u src
  require_root
  need_systemd || return 1
  if [[ $(stat -c %u "$TOOLKIT_DIR") != 0 ]]; then
    log_warn "Toolkit đang nằm trong thư mục của user thường ($TOOLKIT_DIR) nhưng timer sẽ chạy bằng root."
    log_warn "Nên cài vào /opt trước: sudo ./install.sh  (tránh user sửa script để chiếm quyền root)."
  fi
  if [[ -n $(_cron_block) ]]; then
    log_warn "Crontab đã có lịch của toolkit — gỡ bằng '$PROG scheduler remove' để tránh chạy trùng."
  fi
  for u in "${TK_UNITS[@]}"; do
    src="$TOOLKIT_DIR/systemd/$u"
    [[ -r $src ]] || die "Thiếu file mẫu $src"
    sed "s|@TOOLKIT_DIR@|$TOOLKIT_DIR|g" "$src" | write_file "/etc/systemd/system/$u" 644
  done
  run systemctl daemon-reload
  run systemctl enable --now "${TK_TIMERS[@]}"
  [[ $DRY_RUN == 1 ]] && return 0
  log_ok "Đã cài timer. Kiểm tra: systemctl list-timers 'toolkit-*'"
  systemctl list-timers 'toolkit-*' --no-pager || true
}

scheduler_timers_remove() {
  local u
  require_root
  need_systemd || return 1
  run systemctl disable --now "${TK_TIMERS[@]}" 2>/dev/null || true
  for u in "${TK_UNITS[@]}"; do
    run rm -f "/etc/systemd/system/$u"
  done
  run systemctl daemon-reload
  log_ok "Đã gỡ các timer của toolkit."
}
