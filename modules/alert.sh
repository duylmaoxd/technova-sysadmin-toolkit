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
register_action check         ""  "Kiểm tra CPU/RAM/disk, process ngốn tài nguyên, dịch vụ chết, dò mật khẩu SSH → gửi cảnh báo"
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
        _mail_message "$to" "${from:-$to}" "$subject" "$body" | msmtp -C "$CONFIG_DIR/msmtprc" -t && sent=1 ;;
      msmtp) _mail_message "$to" "$(id -un)@$(hostname)" "$subject" "$body" | msmtp -t && sent=1 ;;
      mail) printf '%s\n' "$body" | mail -s "$subject" "$to" && sent=1 ;;
      sendmail) _mail_message "$to" "root@$(hostname)" "$subject" "$body" | sendmail -t && sent=1 ;;
    esac
    if ((sent)); then log_ok "Đã gửi email tới $to ($method)"
    else log_warn "Chưa gửi được email (kênh: $method) — cấu hình bằng: $PROG alert setup-mail"; fi
  else
    log_warn "Chưa đặt ALERT_EMAIL — cảnh báo chỉ được ghi vào $LOG_DIR/alerts.log và journald."
  fi
  if [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]] && has curl; then
    if [[ $(curl -s -m 10 -o /dev/null -w '%{http_code}' --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$subject"$'\n\n'"$body" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage") == 200 ]]; then
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
  # Dò mật khẩu SSH trong 10 phút qua
  local fails=0
  if has journalctl && [[ -d /run/systemd/system ]]; then
    fails=$({ journalctl -u ssh -u sshd --since "-10min" --no-pager -q 2>/dev/null || true; } |
      grep -cE 'Failed password|Invalid user' || true)
  fi
  if ((fails >= SSH_FAIL_THRESHOLD)); then msgs+=("$fails lần đăng nhập SSH thất bại trong 10 phút (nghi dò mật khẩu)"); fi
  [[ $DRY_RUN == 1 ]] || _alert_metrics "$CPU_PCT" "$MEM_PCT" "$SWAP_PCT" "$disk_max" "$load"

  header "Kiểm tra tài nguyên $(date '+%d/%m/%Y %H:%M:%S')"
  kv "CPU" "$(bar "$CPU_PCT" 25 $((CPU_THRESHOLD - 15)) "$CPU_THRESHOLD")  ngưỡng $CPU_THRESHOLD%"
  kv "RAM" "$(bar "$MEM_PCT" 25 $((MEM_THRESHOLD - 15)) "$MEM_THRESHOLD")  ngưỡng $MEM_THRESHOLD%"
  kv "Ổ đầy nhất ($disk_mnt)" "$(bar "$disk_max" 25 $((DISK_THRESHOLD - 15)) "$DISK_THRESHOLD")  ngưỡng $DISK_THRESHOLD%"
  kv "Load 1 phút" "$load"
  kv "SSH thất bại (10 phút)" "${fails:-0} lần (ngưỡng $SSH_FAIL_THRESHOLD)"

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
