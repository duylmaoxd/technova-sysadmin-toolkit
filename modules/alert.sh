#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # biến toàn cục dùng chung giữa các file
# =============================================================================
#  modules/alert.sh — CHỨC NĂNG 3: CẢNH BÁO SỰ CỐ TỨC THỜI (email / Telegram)
#  Nhu cầu của Tech Lead: được báo ngay khi máy chủ gặp sự cố, bất kể ngày đêm.
#  "alert check" được cron / systemd timer gọi mỗi 5 phút:
#    đo CPU/RAM/disk → ghi lịch sử (metrics.csv) → phát hiện process ngốn tài
#    nguyên, dịch vụ systemd bị chết, dò mật khẩu SSH → gửi cảnh báo qua email
#    (msmtp/mail/sendmail) và Telegram → hết sự cố thì gửi tin "đã ổn định".
#    Có thời gian chờ (cooldown) để tránh spam lúc nửa đêm.
#  Dùng các hàm đo của module monitor: cpu_sample, mem_stats, disk_usage.
# =============================================================================

register_module alert 3 "Cảnh báo sự cố tức thời (email / Telegram)"
register_action check         ""  "Kiểm tra tài nguyên + PHÁT HIỆN TẤN CÔNG → gửi cảnh báo email/Telegram (job cron 5 phút)"
register_action security      "r" "Phát hiện tấn công & bất thường: brute-force SSH, dò user, sudo trái phép, file hệ thống bị sửa, cổng lạ, process độc hại"
register_action baseline      "r" "Chụp lại \"trạng thái chuẩn\" (file hệ thống quan trọng, cổng đang mở) sau khi admin thay đổi hợp lệ"
register_action ban           "rd" "Chặn một IP tấn công bằng tường lửa (ufw / iptables)" "Địa chỉ IP"
register_action unban         "rd" "Bỏ chặn một IP" "Địa chỉ IP=@_pick_banned"
register_action banned        ""  "Danh sách IP đang bị chặn"
register_action status        ""  "Ngưỡng cảnh báo, giá trị hiện tại & kênh gửi đang dùng"
register_action test          ""  "Gửi email thử nghiệm" "Email người nhận=$ALERT_EMAIL"
register_action setup-mail    "d" "Cấu hình gửi email qua SMTP (msmtp — ví dụ Gmail App Password)" "Máy chủ SMTP=smtp.gmail.com" "Cổng=587|465" "Tài khoản email dùng để gửi" "*Mật khẩu ứng dụng (App Password)" "Email nhận cảnh báo=$ALERT_EMAIL"
register_action setup-telegram "d" "Cấu hình nhận cảnh báo qua Telegram (tức thời trên điện thoại)" "*Bot token (từ @BotFather)" "Chat ID"
register_action set-threshold "d" "Đổi ngưỡng cảnh báo" "Loại=CPU|MEM|DISK|HOG_CPU|HOG_MEM" "Ngưỡng (%)=80"
register_action stress        ""  "Demo: tạo tải 100% CPU rồi chạy kiểm tra để thấy cảnh báo" "Số giây tạo tải=30"
register_action history       ""  "Lịch sử các cảnh báo đã phát ra" "Số dòng=20"

ALERT_METRICS_MAX=10000 # giữ tối đa bấy nhiêu dòng trong metrics.csv

# Thư theo định dạng chuẩn (tiêu đề tiếng Việt được mã hoá base64 theo RFC 2047)
_mail_message() { # <tới> <từ> <tiêu đề> <nội dung>
  printf 'To: %s\nFrom: %s\nSubject: =?UTF-8?B?%s?=\nDate: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n' \
    "$1" "$2" "$(printf '%s' "$3" | base64 -w0)" "$(LC_ALL=C date -R)" "$4"
}

# Kênh gửi email khả dụng: msmtp-toolkit | msmtp | mail | sendmail | none
_mail_method() {
  if has msmtp && [[ -r $CONFIG_DIR/msmtprc ]]; then echo msmtp-toolkit
  elif has msmtp && [[ -r $HOME/.msmtprc || -r /etc/msmtprc ]]; then echo msmtp
  elif has mail; then echo mail
  elif has sendmail; then echo sendmail
  else echo none; fi
}

# alert_send <tiêu đề> <nội dung> [người nhận] — gửi cảnh báo qua mọi kênh đã cấu hình
alert_send() {
  local subject=$1 body=$2 to=${3:-$ALERT_EMAIL} sent=0 from method
  { printf '%s | %s\n' "$(date '+%F %T')" "$subject" >>"$LOG_DIR/alerts.log"; } 2>/dev/null || true
  syslog_event "ALERT: $subject"
  if [[ $DRY_RUN == 1 ]]; then
    printf '%s[DRY-RUN]%s gửi cảnh báo tới %s: %s\n' "$C_MAGENTA" "$C_RESET" "${to:-(chưa cấu hình)}" "$subject"
    return 0
  fi
  if [[ -n $to ]]; then
    method=$(_mail_method)
    case $method in
      msmtp-toolkit)
        from=$(awk '$1 == "from" { print $2; exit }' "$CONFIG_DIR/msmtprc")
        _mail_message "$to" "${from:-$to}" "$subject" "$body" | timeout 45 msmtp -C "$CONFIG_DIR/msmtprc" -t && sent=1 ;;
      msmtp) _mail_message "$to" "$(id -un)@$(hostname)" "$subject" "$body" | timeout 45 msmtp -t && sent=1 ;;
      mail) printf '%s\n' "$body" | timeout 45 mail -s "$subject" "$to" && sent=1 ;;
      sendmail) _mail_message "$to" "root@$(hostname)" "$subject" "$body" | timeout 45 sendmail -t && sent=1 ;;
    esac
    if ((sent)); then log_ok "Đã gửi email tới $to ($method)"
    else log_warn "Chưa gửi được email (kênh: $method) — cấu hình bằng: $PROG alert setup-mail"; fi
  else
    log_warn "Chưa đặt ALERT_EMAIL — cảnh báo chỉ được ghi vào $LOG_DIR/alerts.log và journald."
  fi
  if [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]] && has curl; then
    if [[ $(curl -s -m 10 -o /dev/null -w '%{http_code}' --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$subject"$'\n\n'"$body" "${TELEGRAM_API%/}/bot$TELEGRAM_BOT_TOKEN/sendMessage") == 200 ]]; then
      log_ok "Đã gửi Telegram"
      sent=1
    else
      log_warn "Gửi Telegram thất bại"
    fi
  fi
  # Không gửi được qua kênh nào → báo cho mọi người đang đăng nhập (wall)
  if ((!sent && EUID == 0)) && has wall; then printf '%s\n%s\n' "$subject" "$body" | wall 2>/dev/null || true; fi
  return 0
}

# Ghi một dòng số liệu vào metrics.csv (dùng cho monitor history & biểu đồ trong báo cáo)
_alert_metrics() {
  local f="$REPORT_DIR/metrics.csv" tmp
  if [[ ! -f $f ]]; then printf 'time,cpu,mem,swap,disk_max,load1\n' >"$f"; own_like_parent "$f"; fi
  printf '%s,%s,%s,%s,%s,%s\n' "$(date '+%F %T')" "$@" >>"$f"
  if (($(wc -l <"$f") > ALERT_METRICS_MAX + 500)); then
    tmp=$(mktemp)
    { head -n 1 "$f"; tail -n "$ALERT_METRICS_MAX" "$f"; } >"$tmp" && cat "$tmp" >"$f"
    rm -f "$tmp"
  fi
}

alert_check() {
  local pct mnt load host now last prev disk_max=0 disk_mnt=- body m subject
  local -a msgs=()
  local state="$STATE_DIR/alert.state" lastf="$STATE_DIR/alert.last"
  cpu_sample 1
  mem_stats
  read -r load _ </proc/loadavg
  while read -r pct mnt _ _; do
    if ((pct > disk_max)); then disk_max=$pct disk_mnt=$mnt; fi
    if ((pct >= DISK_THRESHOLD)); then msgs+=("Ổ đĩa $mnt đã dùng ${pct}% (ngưỡng ${DISK_THRESHOLD}%)"); fi
  done < <(disk_usage)
  if ((CPU_PCT >= CPU_THRESHOLD)); then msgs+=("CPU đang dùng ${CPU_PCT}% (ngưỡng ${CPU_THRESHOLD}%)"); fi
  if ((MEM_PCT >= MEM_THRESHOLD)); then msgs+=("RAM đang dùng ${MEM_PCT}% (ngưỡng ${MEM_THRESHOLD}%)"); fi
  # Process "treo" ngốn tài nguyên (kèm tên nhân viên chạy nó)
  local hog
  while IFS= read -r hog; do
    [[ -n $hog ]] && msgs+=("Process ngốn tài nguyên: $hog")
  done < <(ps -eo pid=,user=,pcpu=,pmem=,args= --sort=-pcpu |
    awk -v c="$HOG_CPU" -v m="$HOG_MEM" '$5 != "ps" && ($3 >= c || $4 >= m) && n++ < 3 {
      a = $5; for (i = 6; i <= NF; i++) a = a " " $i
      printf "PID %s của %s (%s) dùng %s%% CPU, %s%% RAM\n", $1, $2, substr(a, 1, 40), $3, $4 }')
  # Dịch vụ systemd bị chết
  local failed
  failed=$(_failed_units)
  if ((failed > 0)); then
    msgs+=("$failed dịch vụ systemd bị lỗi: $({ systemctl --failed --no-legend --plain 2>/dev/null || true; } | awk '{ printf "%s ", $1 }')")
  fi
  [[ $DRY_RUN == 1 ]] || _alert_metrics "$CPU_PCT" "$MEM_PCT" "$SWAP_PCT" "$disk_max" "$load"

  header "Kiểm tra tài nguyên $(date '+%d/%m/%Y %H:%M:%S')"
  kv "CPU" "$(bar "$CPU_PCT" 25 $((CPU_THRESHOLD - 15)) "$CPU_THRESHOLD")  ngưỡng $CPU_THRESHOLD%"
  kv "RAM" "$(bar "$MEM_PCT" 25 $((MEM_THRESHOLD - 15)) "$MEM_THRESHOLD")  ngưỡng $MEM_THRESHOLD%"
  kv "Ổ đầy nhất ($disk_mnt)" "$(bar "$disk_max" 25 $((DISK_THRESHOLD - 15)) "$DISK_THRESHOLD")  ngưỡng $DISK_THRESHOLD%"
  kv "Load 1 phút" "$load"

  host=$(hostname)
  now=$(date +%s)
  prev=$(cat "$state" 2>/dev/null || echo OK)
  if ((${#msgs[@]})); then
    for m in "${msgs[@]}"; do status FAIL "$m"; done
    last=$(cat "$lastf" 2>/dev/null || echo 0)
    if [[ $prev == ALERT ]] && ((now - last < ALERT_COOLDOWN_MIN * 60)); then
      log_info "Đã cảnh báo lúc $(date -d "@$last" '+%H:%M') — chờ đủ $ALERT_COOLDOWN_MIN phút mới gửi lại (tránh spam)."
    else
      subject="[CẢNH BÁO] $host: ${msgs[0]}"
      ((${#msgs[@]} > 1)) && subject+=" (+$((${#msgs[@]} - 1)) vấn đề khác)"
      body=$(
        printf 'Máy chủ : %s\nThời điểm: %s\n\nVấn đề phát hiện:\n' "$host" "$(date '+%d/%m/%Y %H:%M:%S')"
        printf '  - %s\n' "${msgs[@]}"
        printf '\nTải hệ thống: %s\n\nTop 5 tiến trình theo CPU:\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
        ps_top pid,user,pcpu,pmem,comm -pcpu 5
        printf '\nDung lượng ổ đĩa:\n'
        df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null || true
        printf '\n-- Gửi tự động bởi %s (%s alert check)\n' "$TOOLKIT_NAME" "$PROG"
      )
      alert_send "$subject" "$body"
      [[ $DRY_RUN == 1 ]] || echo "$now" >"$lastf"
    fi
    [[ $DRY_RUN == 1 ]] || echo ALERT >"$state"
  else
    status OK "Mọi chỉ số đều dưới ngưỡng"
    if [[ $prev == ALERT ]]; then
      alert_send "[ĐÃ ỔN ĐỊNH] $host: tài nguyên đã trở lại bình thường" \
        "Lúc $(date '+%d/%m/%Y %H:%M:%S'): CPU ${CPU_PCT}%, RAM ${MEM_PCT}%, ổ đầy nhất ${disk_max}% ($disk_mnt)."
    fi
    [[ $DRY_RUN == 1 ]] || echo OK >"$state"
  fi
  # Phát hiện tấn công / bất thường bảo mật (gửi cảnh báo riêng, tiêu đề [TẤN CÔNG])
  alert_security || true
  return 0
}

alert_status() {
  local method
  cpu_sample 1
  mem_stats
  header "Ngưỡng cảnh báo (sửa trong $CONFIG_FILE hoặc: $PROG alert set-threshold)"
  kv "CPU" "$(bar "$CPU_PCT" 25 $((CPU_THRESHOLD - 15)) "$CPU_THRESHOLD")  ngưỡng $CPU_THRESHOLD%"
  kv "RAM" "$(bar "$MEM_PCT" 25 $((MEM_THRESHOLD - 15)) "$MEM_THRESHOLD")  ngưỡng $MEM_THRESHOLD%"
  local pct mnt
  while read -r pct mnt _ _; do
    kv "Đĩa $mnt" "$(bar "$pct" 25 $((DISK_THRESHOLD - 15)) "$DISK_THRESHOLD")  ngưỡng $DISK_THRESHOLD%"
  done < <(disk_usage)
  kv "Thời gian chờ gửi lại" "$ALERT_COOLDOWN_MIN phút"
  header "Kênh gửi cảnh báo"
  method=$(_mail_method)
  kv "Người nhận (ALERT_EMAIL)" "${ALERT_EMAIL:-(chưa đặt)}"
  case $method in
    msmtp-toolkit) kv "Email" "msmtp với $CONFIG_DIR/msmtprc" ;;
    msmtp) kv "Email" "msmtp với ~/.msmtprc hoặc /etc/msmtprc" ;;
    mail | sendmail) kv "Email" "lệnh $method (cần MTA như postfix đã cấu hình)" ;;
    *) kv "Email" "chưa có công cụ gửi — cài msmtp: $(pkg_hint msmtp)" ;;
  esac
  kv "Telegram" "$([[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]] && printf 'đã cấu hình' || printf 'chưa cấu hình (tuỳ chọn)')"
  kv "Nhật ký cảnh báo" "$LOG_DIR/alerts.log"
  kv "Trạng thái lần trước" "$(cat "$STATE_DIR/alert.state" 2>/dev/null || echo 'chưa chạy')"
}

alert_test() {
  local to=${1:-$ALERT_EMAIL}
  [[ -n $to ]] || die "Chưa có người nhận — nhập email hoặc đặt ALERT_EMAIL (\"$PROG alert setup-mail\")."
  header "Gửi email thử tới $to"
  alert_send "[THỬ NGHIỆM] $(hostname): email từ $TOOLKIT_NAME" \
    "Xin chào!

Nếu bạn đọc được thư này, chức năng gửi cảnh báo của $TOOLKIT_NAME trên máy $(hostname) đã hoạt động.
Thời điểm gửi: $(date '+%d/%m/%Y %H:%M:%S')

Ngưỡng hiện tại: CPU $CPU_THRESHOLD% · RAM $MEM_THRESHOLD% · Disk $DISK_THRESHOLD%" "$to"
  if [[ $(_mail_method) == none && $DRY_RUN != 1 ]]; then
    log_error "Máy chưa có công cụ gửi email — cài msmtp ($(pkg_hint msmtp)) rồi chạy '$PROG alert setup-mail'."
    return 1
  fi
}

alert_setup_mail() {
  local host=${1:-smtp.gmail.com} port=${2:-587} user=${3:-} pass to=${5:-$ALERT_EMAIL} cfg trust="" starttls=on content
  cfg="$CONFIG_DIR/msmtprc"
  [[ $user =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "Tài khoản gửi phải là địa chỉ email (nhận: '$user')"
  [[ $port =~ ^[0-9]+$ ]] || die "Cổng không hợp lệ: $port"
  pass=$(resolve_secret "${4:-}" "Mật khẩu ứng dụng")
  [[ -n $pass ]] || die "Chưa nhập mật khẩu."
  [[ $port == 465 ]] && starttls=off # cổng 465 dùng TLS ngay từ đầu (SMTPS), 587 dùng STARTTLS
  to=${to:-$user}
  [[ -w $CONFIG_DIR || $DRY_RUN == 1 ]] || die "Không có quyền ghi $CONFIG_DIR — thử: sudo $PROG alert setup-mail"
  for trust in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt system; do
    [[ $trust == system || -r $trust ]] && break
  done
  content="# Cấu hình msmtp của $TOOLKIT_NAME — tạo lúc $(date '+%F %T')
# File chứa mật khẩu: giữ quyền 600, KHÔNG chia sẻ, KHÔNG đưa lên git
defaults
auth           on
tls            on
tls_starttls   $starttls
tls_trust_file $trust
timeout        20
logfile        $LOG_DIR/msmtp.log

account        toolkit
host           $host
port           $port
from           $user
user           $user
password       \"PASSWORD_PLACEHOLDER\"

account default : toolkit"
  header "Ghi cấu hình gửi mail: $cfg"
  if [[ $DRY_RUN == 1 ]]; then
    write_file "$cfg" 600 <<<"${content/PASSWORD_PLACEHOLDER/"********"}"
  else
    # msmtp đọc giá trị trong ngoặc kép: phải thoát ký tự \ và "
    local pe=${pass//\\/\\\\}
    pe=${pe//\"/\\\"}
    write_file "$cfg" 600 <<<"${content/PASSWORD_PLACEHOLDER/"$pe"}"
    own_like_parent "$cfg"
  fi
  config_set ALERT_EMAIL "$to"
  [[ $DRY_RUN == 1 ]] && return 0
  if ! has msmtp; then
    log_warn "Đã lưu cấu hình nhưng chưa cài msmtp — cài: $(pkg_hint msmtp) rồi chạy: $PROG alert test"
    return 0
  fi
  log_info "Gửi email thử tới $to ..."
  alert_test "$to"
  printf '\n%sGmail: bật xác minh 2 bước rồi tạo "Mật khẩu ứng dụng" tại myaccount.google.com/apppasswords.\n' "$C_DIM"
  printf 'Lỗi gửi thư xem trong %s/msmtp.log%s\n' "$LOG_DIR" "$C_RESET"
}

alert_set_threshold() {
  local kind=${1:-CPU} val=${2:-80}
  kind=${kind^^}
  is_int "$val" && ((val >= 1 && val <= 100)) || die "Ngưỡng phải là số 1..100"
  case $kind in
    CPU | MEM | DISK) config_set "${kind}_THRESHOLD" "$val" ;;
    HOG_CPU | HOG_MEM) config_set "$kind" "$val" ;;
    *) die "Loại phải là CPU, MEM, DISK, HOG_CPU hoặc HOG_MEM" ;;
  esac
}

_STRESS_PIDS=()
alert_stress() {
  local secs=${1:-30} n i
  is_int "$secs" && ((secs >= 5 && secs <= 600)) || die "Số giây phải trong khoảng 5..600"
  n=$(nproc)
  header "Tạo tải 100% trên $n lõi CPU trong $secs giây"
  for ((i = 0; i < n; i++)); do
    timeout "$secs" bash -c 'while :; do :; done' &
    _STRESS_PIDS+=("$!")
  done
  trap 'kill "${_STRESS_PIDS[@]}" 2>/dev/null || true; tk_cleanup' EXIT
  log_info "Chờ 3 giây cho tải tăng lên..."
  sleep 3
  alert_check
  log_info "Tải giả lập sẽ tự dừng sau $secs giây (Ctrl+C để dừng sớm)..."
  wait "${_STRESS_PIDS[@]}" 2>/dev/null || true
  log_ok "Đã dừng tải giả lập. Chạy lại '$PROG alert check' để thấy thư \"đã ổn định\"."
}

alert_history() {
  local n=${1:-20} f="$LOG_DIR/alerts.log"
  header "Các cảnh báo gần đây ($f)"
  if [[ -s $f ]]; then tail -n "$n" "$f"; else printf '  (chưa có cảnh báo nào)\n'; fi
  if has journalctl; then
    header "Trong journald (journalctl -t sysadmin-toolkit)"
    journalctl -t sysadmin-toolkit --no-pager -n "$n" 2>/dev/null | grep -F 'ALERT' || printf '  (không có)\n'
  fi
}

alert_setup_telegram() {
  local token chat=${2:-}
  token=$(resolve_secret "${1:-}" "Bot token")
  [[ $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "Bot token không đúng dạng (ví dụ 123456789:AA...)"
  [[ $chat =~ ^-?[0-9]+$ ]] || die "Chat ID phải là số (lấy bằng cách nhắn bot rồi mở https://api.telegram.org/bot<TOKEN>/getUpdates)"
  [[ -w $CONFIG_FILE || $DRY_RUN == 1 ]] || die "Không có quyền ghi $CONFIG_FILE — thử: sudo $PROG alert setup-telegram"
  header "Cấu hình Telegram"
  config_set TELEGRAM_BOT_TOKEN "$token" secret
  config_set TELEGRAM_CHAT_ID "$chat"
  [[ $DRY_RUN == 1 ]] && return 0
  [[ $(stat -c %a "$CONFIG_FILE") == 6?4 ]] && log_warn "File cấu hình chứa token: nên chmod 640 $CONFIG_FILE (chỉ root/nhóm admin đọc)."
  log_info "Gửi tin nhắn thử..."
  ALERT_EMAIL="" alert_send "[THỬ NGHIỆM] $(hostname): $COMPANY_NAME đã kết nối Telegram" "Từ giờ cảnh báo sự cố máy chủ sẽ được gửi tới đây."
}

# ======================================================= PHÁT HIỆN TẤN CÔNG (IDS) ===
# Đọc log theo "cửa sổ trượt" IDS_WINDOW_MIN phút, so trạng thái hệ thống với bản chuẩn
# (baseline), phát hiện 9 nhóm dấu hiệu, chống cảnh báo trùng, tuỳ chọn tự chặn IP.
IDS_WATCH_FILES="/etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/ssh/sshd_config /root/.ssh/authorized_keys /etc/crontab"

# _tail_window <tên> <file...> — dòng MỚI của file log trong IDS_WINDOW_MIN phút gần nhất.
# Ghi nhớ vị trí đã đọc (inode + byte) và lưu đệm các dòng kèm thời điểm đọc, nên chạy cron
# 5 phút/lần vẫn có cửa sổ 10 phút; lần chạy đầu chỉ đánh dấu vị trí (không cảnh báo log cũ).
_tail_window() {
  local name=$1 f="" buf off now size inode li=0 lo=0
  shift
  for f in "$@"; do [[ -r $f ]] && break; f=""; done
  [[ -n $f ]] || return 0
  buf="$STATE_DIR/ids-$name.buf" off="$STATE_DIR/ids-$name.off"
  now=$(date +%s) size=$(stat -c %s "$f") inode=$(stat -c %i "$f")
  if [[ -r $off ]]; then read -r li lo <"$off" || true
  else echo "$inode $size" >"$off"; : >"$buf"; return 0; fi
  if [[ $li != "$inode" ]] || ((size < lo)); then lo=0; fi # log vừa bị xoay vòng (logrotate)
  if ((size > lo)); then tail -c +$((lo + 1)) "$f" | awk -v t="$now" '{ print t "\t" $0 }' >>"$buf"; fi
  echo "$inode $size" >"$off"
  awk -F'\t' -v c=$((now - IDS_WINDOW_MIN * 60)) '$1 >= c' "$buf" >"$buf.tmp" && mv "$buf.tmp" "$buf"
  cut -f2- "$buf"
}

_ids_auth() {
  if has journalctl && [[ -d /run/systemd/system ]]; then
    journalctl --since "-${IDS_WINDOW_MIN}min" --no-pager -q -o short-iso SYSLOG_FACILITY=4 + SYSLOG_FACILITY=10 2>/dev/null || true
  else _tail_window auth /var/log/auth.log /var/log/secure; fi
}
_ids_kern() {
  if has journalctl && [[ -d /run/systemd/system ]]; then
    journalctl -k --since "-${IDS_WINDOW_MIN}min" --no-pager -q -o short-iso 2>/dev/null || true
  else _tail_window kern /var/log/kern.log /var/log/syslog /var/log/messages; fi
}

_ids_files() { local f; for f in $IDS_WATCH_FILES /etc/sudoers.d/*; do [[ -f $f ]] && printf '%s\n' "$f"; done; return 0; }
_ids_ports() { { ss -tulnH 2>/dev/null || true; } | awk '{ print $1 " " $5 }' | sed -E 's/%[^:]*:/:/' | sort -u; }

# _ids_baseline_files [quiet] — chụp lại checksum file quan trọng & danh sách cổng đang mở
_ids_baseline_files() {
  [[ $DRY_RUN == 1 ]] && return 0
  ((EUID == 0)) || return 0
  _ids_files | xargs -r sha256sum >"$STATE_DIR/ids-integrity.sha" 2>/dev/null || true
  awk -F: '{ print $1 ":" $3 }' /etc/passwd | sort >"$STATE_DIR/ids-users.list"
  _ids_ports >"$STATE_DIR/ids-ports.list"
  chmod 600 "$STATE_DIR"/ids-* 2>/dev/null || true
  [[ ${1:-} == quiet ]] || log_ok "Đã chụp trạng thái chuẩn: $(wc -l <"$STATE_DIR/ids-integrity.sha") file, $(wc -l <"$STATE_DIR/ids-ports.list") cổng."
}

_ids_whitelisted() { local w; for w in $IDS_WHITELIST; do [[ $1 == "$w" ]] && return 0; done; return 1; }

_ban_ip() { # _ban_ip <ip> <lý do>
  local ip=$1 why=${2:-thủ công}
  [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || { log_error "IP không hợp lệ: $ip"; return 1; }
  _ids_whitelisted "$ip" && { log_warn "IP $ip nằm trong IDS_WHITELIST — không chặn."; return 0; }
  grep -q "^$ip " "$STATE_DIR/banned.list" 2>/dev/null && return 0
  if has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    run ufw insert 1 deny from "$ip" comment "sysadmin-toolkit IDS" >/dev/null || return 1
  elif has iptables; then
    run iptables -I INPUT -s "$ip" -j DROP -m comment --comment "sysadmin-toolkit IDS" || return 1
  else
    log_error "Không có ufw/iptables để chặn IP."; return 1
  fi
  [[ $DRY_RUN == 1 ]] || printf '%s %s %s\n' "$ip" "$(date +%s)" "${why// /_}" >>"$STATE_DIR/banned.list"
  syslog_event "IDS BAN: $ip ($why)"
  return 0
}

# _ids_new <khoá> — 0 nếu dấu hiệu này CHƯA được cảnh báo trong ALERT_COOLDOWN_MIN phút (chống spam)
_ids_new() {
  local key=$1 seen="$STATE_DIR/ids-seen" now last
  now=$(date +%s)
  last=$(awk -v k="$key" '$1 == k { t = $2 } END { print t + 0 }' "$seen" 2>/dev/null || echo 0)
  ((now - last >= ALERT_COOLDOWN_MIN * 60)) || return 1
  [[ $DRY_RUN == 1 ]] || { grep -v "^$key " "$seen" 2>/dev/null; echo "$key $now"; } >"$seen.tmp" 2>/dev/null && mv "$seen.tmp" "$seen" 2>/dev/null
  return 0
}

alert_security() {
  local auth kern ip user n line key sev
  local -a finds=() keys=() sevs=() bans=()
  # add <mức> <khoá chống trùng> <mô tả>
  add() { sevs+=("$1"); keys+=("$2"); finds+=("$3"); }
  ((EUID == 0)) || log_warn "Không phải root — nhiều kiểm tra bảo mật sẽ thiếu dữ liệu (chạy bằng sudo)."
  if [[ ! -f $STATE_DIR/ids-integrity.sha ]] && ((EUID == 0)); then
    _ids_baseline_files quiet
    log_info "Lần chạy đầu: đã tạo trạng thái chuẩn (baseline) để so sánh cho các lần sau."
  fi
  auth=$(_ids_auth)
  kern=$(_ids_kern)

  # 1. Brute-force SSH: nhiều lần sai mật khẩu từ cùng một IP
  while read -r n ip; do
    [[ -n $ip ]] || continue
    _ids_whitelisted "$ip" && continue
    add WARN "ssh-brute:$ip" "Dò mật khẩu SSH: $n lần thất bại từ IP $ip trong $IDS_WINDOW_MIN phút"
    [[ ${AUTO_BAN,,} == yes ]] && bans+=("$ip")
  done < <({ grep -E 'Failed [a-z/-]+ for ' <<<"$auth" || true; } |
    grep -oE 'from [0-9a-fA-F:.]+' | awk '{ print $2 }' | sort | uniq -c |
    awk -v t="$IDS_SSH_FAIL_PER_IP" '$1 >= t { print $1, $2 }' || true)

  # 2. Dò tên tài khoản (password spraying): thử nhiều username không tồn tại
  n=$({ grep -oE 'Invalid user [^ ]+' <<<"$auth" || true; } | awk '{ print $3 }' | sort -u | grep -c . || true)
  if ((n >= IDS_SPRAY_USERS)); then
    add WARN "ssh-spray" "Dò tên tài khoản: $n username không tồn tại bị thử ($({ grep -oE 'Invalid user [^ ]+' <<<"$auth" || true; } | awk '{ print $3 }' | sort -u | take 5 | paste -sd, -)...)"
  fi

  # 3. Đăng nhập THÀNH CÔNG từ IP vừa dò mật khẩu → nghi bị chiếm tài khoản
  while read -r user ip; do
    [[ -n $ip ]] || continue
    n=$({ grep -E 'Failed [a-z/-]+ for ' <<<"$auth" || true; } | grep -cF "from $ip " || true)
    ((n > 0)) && add CRITICAL "ssh-compromise:$user@$ip" "NGHI BỊ CHIẾM TÀI KHOẢN: $user đăng nhập thành công từ $ip sau $n lần thất bại"
    [[ $user == root ]] && add WARN "ssh-root:$ip" "Đăng nhập SSH trực tiếp bằng root từ $ip"
  done < <({ grep -oE 'Accepted [a-z-]+ for [^ ]+ from [0-9a-fA-F:.]+' <<<"$auth" || true; } | awk '{ print $4, $6 }' | sort -u || true)

  # 4. Dùng sudo trái phép / sai mật khẩu nhiều lần
  while read -r n user; do
    [[ -n $user ]] || continue
    add WARN "sudo-fail:$user" "sudo thất bại $n lần bởi $user (thử chiếm quyền root?)"
  done < <({ grep -E 'sudo.*(incorrect password attempt|authentication failure)' <<<"$auth" || true; } |
    sed -nE 's/.*sudo(\[[0-9]+\])?: +([a-z_][a-z0-9_-]*) :.*/\2/p; s/.*pam_unix\(sudo:auth\).*ruser=([a-z_][a-z0-9_-]*).*/\1/p' |
    sort | uniq -c | awk -v t="$IDS_SUDO_FAIL" '$1 >= t { print $1, $2 }' || true)
  while read -r user; do
    [[ -n $user ]] && add CRITICAL "sudo-deny:$user" "$user cố dùng sudo nhưng KHÔNG có trong sudoers"
  done < <({ grep -E 'NOT in sudoers' <<<"$auth" || true; } | sed -nE 's/.*sudo(\[[0-9]+\])?: +([a-z_][a-z0-9_-]*) :.*/\2/p' | sort -u || true)

  # 5. Quét cổng: tường lửa chặn nhiều gói từ một IP
  while read -r n ip; do
    [[ -n $ip ]] || continue
    _ids_whitelisted "$ip" && continue
    add WARN "portscan:$ip" "Nghi quét cổng: tường lửa chặn $n gói từ $ip"
    [[ ${AUTO_BAN,,} == yes ]] && bans+=("$ip")
  done < <({ grep -E 'UFW BLOCK|IPTABLES.*DROP' <<<"$kern" || true; } | grep -oE 'SRC=[0-9a-fA-F:.]+' | cut -d= -f2 |
    sort | uniq -c | awk -v t="$IDS_SCAN_HITS" '$1 >= t { print $1, $2 }' || true)

  if ((EUID == 0)) && [[ -f $STATE_DIR/ids-integrity.sha ]]; then
    # 6. File hệ thống quan trọng bị sửa (tài khoản, sudoers, SSH, crontab)
    while read -r line; do
      [[ -n $line ]] && add CRITICAL "integrity:$line" "File quan trọng bị THAY ĐỔI: $line"
    done < <(sha256sum -c --quiet "$STATE_DIR/ids-integrity.sha" 2>/dev/null | awk -F: '/FAILED/ { print $1 }' || true)
    while read -r line; do
      [[ -n $line ]] && add CRITICAL "integrity-new:$line" "File quan trọng MỚI xuất hiện: $line"
    done < <(comm -13 <(awk '{ print $2 }' "$STATE_DIR/ids-integrity.sha" | sort) <(_ids_files | sort) || true)
    # 7. Tài khoản mới / tài khoản có UID 0 ngoài root
    while read -r line; do
      [[ -n $line ]] && add CRITICAL "newuser:$line" "Tài khoản MỚI không qua toolkit: ${line%%:*} (UID ${line#*:})"
    done < <(comm -13 "$STATE_DIR/ids-users.list" <(awk -F: '{ print $1 ":" $3 }' /etc/passwd | sort) 2>/dev/null || true)
    while read -r user; do
      [[ -n $user ]] && add CRITICAL "uid0:$user" "Tài khoản $user có UID 0 (quyền root) — rất nguy hiểm"
    done < <(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/passwd || true)
    # 8. Cổng mạng mới mở (backdoor?)
    while read -r line; do
      [[ -n $line ]] && add WARN "port:$line" "Cổng mới đang lắng nghe: $line ($({ ss -tulnpH 2>/dev/null | grep -F " ${line#* } " | grep -oE 'users:\(\("[^"]+' || true; } | take 1 | cut -d'"' -f2))"
    done < <(comm -13 "$STATE_DIR/ids-ports.list" <(_ids_ports) 2>/dev/null || true)
  fi

  # 9. Process đáng ngờ: chạy từ /tmp, /dev/shm; tên công cụ đào coin; reverse shell
  local pid exe cmd
  for pid in /proc/[0-9]*; do
    pid=${pid#/proc/}
    ((pid == $$ || pid == BASHPID)) && continue
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | cut -c1-120)
    if [[ $exe == /tmp/* || $exe == /dev/shm/* || $exe == /var/tmp/* ]]; then
      add CRITICAL "proc-tmp:$pid" "Process PID $pid ($(stat -c %U "/proc/$pid" 2>/dev/null)) chạy từ thư mục tạm: $exe"
    elif [[ $cmd =~ (xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|stratum\+tcp) ]]; then
      add CRITICAL "proc-miner:$pid" "Nghi phần mềm đào coin: PID $pid — $cmd"
    elif [[ $cmd =~ (bash\ -i|sh\ -i).*(/dev/tcp|>\&) || $cmd =~ (nc|ncat|netcat)\ .*-e\  || $cmd =~ /dev/tcp/[0-9] ]]; then
      add CRITICAL "proc-revshell:$pid" "Nghi reverse shell: PID $pid — $cmd"
    fi
  done

  # ---- In kết quả & gửi cảnh báo
  header "Phát hiện tấn công & bất thường (cửa sổ $IDS_WINDOW_MIN phút)"
  local crit=0 newcrit=0 i
  local -a newf=()
  if ((${#finds[@]} == 0)); then
    status OK "Không phát hiện dấu hiệu tấn công"
  fi
  for i in "${!finds[@]}"; do
    if [[ ${sevs[i]} == CRITICAL ]]; then status FAIL "${finds[i]}"; crit=$((crit + 1)); else status WARN "${finds[i]}"; fi
    if _ids_new "${keys[i]}"; then
      newf+=("[${sevs[i]}] ${finds[i]}")
      [[ ${sevs[i]} == CRITICAL ]] && newcrit=$((newcrit + 1))
    fi
  done
  for ip in $(printf '%s\n' "${bans[@]}" | sort -u); do
    if _ban_ip "$ip" "IDS tự động"; then status OK "Đã TỰ ĐỘNG CHẶN IP $ip"; newf+=("[ĐÃ CHẶN] IP $ip bị chặn tự động bằng tường lửa"); fi
  done
  if ((${#newf[@]})); then
    local body
    body=$(
      printf 'Máy chủ : %s\nThời điểm: %s\n\nDấu hiệu phát hiện:\n' "$(hostname)" "$(date '+%d/%m/%Y %H:%M:%S')"
      printf '  - %s\n' "${newf[@]}"
      printf '\nGợi ý xử lý:\n  - Xem chi tiết: %s monitor logcheck 1\n  - Chặn IP: %s alert ban <IP>\n' "$PROG" "$PROG"
      printf '  - Ngắt phiên/khoá tài khoản: %s users kick|lock <user>\n  - Nếu thay đổi là hợp lệ: %s alert baseline\n' "$PROG" "$PROG"
      printf '\n-- Gửi tự động bởi %s (IDS)\n' "$TOOLKIT_NAME"
    )
    local extra=""
    ((newcrit > 0)) && extra=" ($newcrit nghiêm trọng)"
    alert_send "[TẤN CÔNG] $(hostname): ${#newf[@]} dấu hiệu bất thường$extra" "$body"
  elif ((${#finds[@]})); then
    log_info "Các dấu hiệu trên đã được cảnh báo trong $ALERT_COOLDOWN_MIN phút qua — không gửi lại."
  fi
  syslog_event "IDS: ${#finds[@]} dấu hiệu ($crit nghiêm trọng)"
  unset -f add
  return 0
}

alert_baseline() {
  require_root
  header "Chụp trạng thái chuẩn cho hệ thống phát hiện tấn công"
  _ids_baseline_files
  [[ $DRY_RUN == 1 ]] && return 0
  printf '  File theo dõi: %s\n' "$(awk '{ print $2 }' "$STATE_DIR/ids-integrity.sha" | paste -sd' ' -)"
  printf '  Cổng đang mở : %s\n' "$(paste -sd' ' "$STATE_DIR/ids-ports.list")"
}

alert_ban() {
  require_root
  header "Chặn IP $1"
  _ban_ip "$1" "thủ công" && [[ $DRY_RUN != 1 ]] && log_ok "Đã chặn $1"
  return 0
}

alert_unban() {
  local ip=$1
  require_root
  [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || die "IP không hợp lệ: $ip"
  if has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then run ufw delete deny from "$ip" >/dev/null || true
  elif has iptables; then
    while iptables -C INPUT -s "$ip" -j DROP -m comment --comment "sysadmin-toolkit IDS" 2>/dev/null; do
      run iptables -D INPUT -s "$ip" -j DROP -m comment --comment "sysadmin-toolkit IDS" || break
      [[ $DRY_RUN == 1 ]] && break
    done
  fi
  [[ $DRY_RUN == 1 ]] || { grep -v "^$ip " "$STATE_DIR/banned.list" >"$STATE_DIR/banned.tmp" 2>/dev/null || true; mv "$STATE_DIR/banned.tmp" "$STATE_DIR/banned.list"; }
  syslog_event "IDS UNBAN: $ip"
  log_ok "Đã bỏ chặn $ip"
}

_pick_banned() {
  local ip t why
  [[ -r $STATE_DIR/banned.list ]] || return 0
  while read -r ip t why; do printf '%s\tchặn lúc %s (%s)\n' "$ip" "$(date -d "@$t" '+%d/%m %H:%M')" "${why//_/ }"; done <"$STATE_DIR/banned.list"
}

alert_banned() {
  header "IP đang bị chặn bởi toolkit"
  if [[ ! -s $STATE_DIR/banned.list ]]; then printf '  (không có)\n'; return 0; fi
  while read -r ip t why; do
    printf '  %-40s %s  %s\n' "$ip" "$(date -d "@$t" '+%d/%m/%Y %H:%M')" "${why//_/ }"
  done <"$STATE_DIR/banned.list"
  printf '\n%sBỏ chặn: %s alert unban <IP> · Tự động chặn: AUTO_BAN=yes trong toolkit.conf (hiện: %s)%s\n' "$C_DIM" "$PROG" "$AUTO_BAN" "$C_RESET"
}
