#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # biến toàn cục dùng chung giữa các file
# =============================================================================
#  modules/alert.sh — CHỨC NĂNG 3: CẢNH BÁO SỰ CỐ TỨC THỜI (email / Telegram)
#  Nhu cầu của Tech Lead: được báo ngay khi máy chủ gặp sự cố, bất kể ngày đêm.
#  - "alert watch" (dịch vụ nền toolkit-ids): đọc log xác thực LIÊN TỤC, phát hiện
#    dò mật khẩu / chiếm tài khoản / sudo trái phép và chặn IP trong vài giây.
#  - "alert check" (timer mỗi phút): đo CPU/RAM/disk, process treo, dịch vụ chết,
#    kiểm tra toàn vẹn file / cổng lạ / process độc hại → cảnh báo email + Telegram;
#    hết sự cố thì gửi tin "đã ổn định".
#  - Chống spam: gộp các sự kiện gần nhau thành một tin, chỉ báo lại khi NẶNG THÊM
#    hoặc sau ALERT_REPEAT_MIN phút, giới hạn ALERT_RATE_MAX tin / 10 phút,
#    CPU/RAM phải vượt ngưỡng ALERT_CONFIRM lần liên tiếp mới báo.
#  Dùng các hàm đo của module monitor: cpu_sample, mem_stats, disk_usage.
# =============================================================================

register_module alert 3 "Cảnh báo sự cố tức thời (email / Telegram)"
register_action check         ""  "Kiểm tra tài nguyên + PHÁT HIỆN TẤN CÔNG → gửi cảnh báo email/Telegram (timer mỗi phút)"
register_action watch         "r" "Phát hiện tấn công THỜI GIAN THỰC: đọc log liên tục, chặn IP & báo trong vài giây (chạy nền bởi dịch vụ toolkit-ids; Ctrl+C để dừng)"
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

# ================================================================ CHỐNG SPAM ===
# Mọi cảnh báo đi qua 2 bước:
#   _notify_event <res|sec> <WARN|CRITICAL> <khoá> <độ lớn> <nội dung>
#       quyết định có báo không; có thì đưa vào hàng đợi NOTIFY_Q, không thì trả về 1
#   _notify_flush   gộp cả hàng đợi thành MỘT tin và gửi (có giới hạn số tin / 10 phút)
# Quy tắc chống nhiễu:
#   - dấu hiệu mới → báo ngay;
#   - đã báo rồi → chỉ báo lại khi nặng thêm (độ lớn ≥ ALERT_ESCALATE × lần trước, hoặc
#     WARN → CRITICAL) hoặc vẫn còn sau ALERT_REPEAT_MIN phút; tin sau ghi "đã gộp N lần";
#   - quá ALERT_RATE_MAX tin trong 10 phút → giữ lại, gộp vào tin kế tiếp (CRITICAL vẫn gửi).
# Trạng thái lưu ở STATE_DIR/notify.* (dùng chung giữa dịch vụ nền và timer, có khoá flock).
declare -ga NOTIFY_Q=()
NOTIFY_FIRST=0 NOTIFY_PEND_CHECK=0

_notify_lock() { exec 8>>"$STATE_DIR/notify.lock" && { flock -w 5 8 2>/dev/null || true; }; }
_notify_unlock() { { flock -u 8 2>/dev/null || true; } && exec 8>&-; }

_notify_event() {
  local cat=$1 sev=$2 key=${3// /_} level=${4:-1} msg=$5 st="$STATE_DIR/notify.state"
  local now t l s n send=0 note=""
  printf -v now '%(%s)T' -1
  _notify_lock
  read -r t l s n < <(awk -v k="$key" '$1 == k { print $2, $3, $4, $5; f = 1 } END { if (!f) print "0 0 - 0" }' "$st" 2>/dev/null || echo "0 0 - 0")
  if ((t == 0)); then send=1
  elif [[ $sev == CRITICAL && $s != CRITICAL ]]; then send=1 note=" (nặng thêm)"
  elif ((level > l && level >= l * ALERT_ESCALATE)); then send=1 note=" (tăng từ $l)"
  elif ((now - t >= ALERT_REPEAT_MIN * 60)); then send=1 note=" (vẫn còn sau $(((now - t) / 60)) phút)"
  fi
  if ((send)); then
    ((n > 0)) && note+=" — đã gộp $n lần lặp lại"
    ((${#NOTIFY_Q[@]})) || NOTIFY_FIRST=$now
    NOTIFY_Q+=("$cat"$'\t'"$sev"$'\t'"$msg$note")
    t=$now l=$level s=$sev n=0
  else
    n=$((n + 1))
  fi
  if [[ $DRY_RUN != 1 ]]; then
    { { grep -v "^$key " "$st" 2>/dev/null || true; } && echo "$key $t $l $s $n"; } >"$st.tmp" && mv "$st.tmp" "$st"
  fi
  _notify_unlock
  ((send))
}

# _notify_clear <regex khoá> — quên các dấu hiệu đã báo (sự cố đã hết, IP vừa được bỏ chặn...)
_notify_clear() {
  local st="$STATE_DIR/notify.state"
  [[ $DRY_RUN == 1 || ! -f $st ]] && return 0
  _notify_lock
  { grep -vE "$1" "$st" || true; } >"$st.tmp" && mv "$st.tmp" "$st"
  _notify_unlock
}

_notify_flush() {
  local pend="$STATE_DIR/notify.pending" sentf="$STATE_DIR/notify.sent" now cnt crit=0 sec=0 res=0
  local item c s m subject body host
  local -a items=()
  printf -v now '%(%s)T' -1
  if [[ -s $pend ]]; then mapfile -t items <"$pend"; fi # tin bị giữ lại vì quá giới hạn lần trước
  items+=("${NOTIFY_Q[@]}")
  NOTIFY_Q=()
  ((${#items[@]})) || return 0
  for item in "${items[@]}"; do
    IFS=$'\t' read -r c s _ <<<"$item"
    if [[ $s == CRITICAL ]]; then crit=$((crit + 1)); fi
    if [[ $c == sec ]]; then sec=$((sec + 1)); else res=$((res + 1)); fi
  done
  cnt=$({ awk -v c=$((now - 600)) '$1 >= c' "$sentf" 2>/dev/null || true; } | grep -c . || true)
  if ((cnt >= ALERT_RATE_MAX && crit == 0)); then
    [[ $DRY_RUN == 1 ]] || printf '%s\n' "${items[@]}" >"$pend"
    log_warn "Đã gửi $cnt tin trong 10 phút (giới hạn ALERT_RATE_MAX=$ALERT_RATE_MAX) — giữ ${#items[@]} cảnh báo, gộp vào tin kế tiếp."
    return 0
  fi
  rm -f "$pend"
  host=$(hostname)
  if ((sec)); then subject="[TẤN CÔNG] $host: "; else subject="[CẢNH BÁO] $host: "; fi
  IFS=$'\t' read -r _ _ m <<<"${items[0]}"
  if ((${#items[@]} == 1)); then subject+=$m
  elif ((sec)); then
    subject+="${#items[@]} dấu hiệu bất thường"
    ((crit == 0)) || subject+=" ($crit nghiêm trọng)"
  else subject+="$m (+$((${#items[@]} - 1)) vấn đề khác)"; fi
  body=$(
    printf 'Máy chủ : %s\nThời điểm: %s\n\n' "$host" "$(date '+%d/%m/%Y %H:%M:%S')"
    for item in "${items[@]}"; do
      IFS=$'\t' read -r _ s m <<<"$item"
      printf '  - [%s] %s\n' "$s" "$m"
    done
    if ((res)); then
      printf '\nTải hệ thống: %s\n\nTop 5 tiến trình theo CPU:\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
      ps_top pid,user,pcpu,pmem,comm -pcpu 5
    fi
    if ((sec)); then
      printf '\nGợi ý xử lý:\n  - Xem chi tiết: %s monitor logcheck 1\n  - Chặn / bỏ chặn IP: %s alert ban|unban <IP>\n' "$PROG" "$PROG"
      printf '  - Ngắt phiên/khoá tài khoản: %s users kick|lock <user>\n  - Nếu thay đổi là hợp lệ: %s alert baseline\n' "$PROG" "$PROG"
    fi
    printf '\n-- Gửi tự động bởi %s\n' "$TOOLKIT_NAME"
  )
  alert_send "$subject" "$body"
  if [[ $DRY_RUN != 1 ]]; then
    { { awk -v c=$((now - 600)) '$1 >= c' "$sentf" 2>/dev/null || true; } && echo "$now"; } >"$sentf.tmp" && mv "$sentf.tmp" "$sentf"
  fi
  return 0
}

# _notify_tick <thời điểm> — dịch vụ nền gọi mỗi giây: gửi khi đã gom đủ ALERT_BATCH_SEC giây
_notify_tick() {
  if ((${#NOTIFY_Q[@]})) && (($1 - NOTIFY_FIRST >= ALERT_BATCH_SEC)); then _notify_flush; fi
  if (($1 - NOTIFY_PEND_CHECK >= 60)); then
    NOTIFY_PEND_CHECK=$1
    if [[ -s $STATE_DIR/notify.pending ]]; then _notify_flush; fi
  fi
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
  local pct mnt load prev disk_max=0 disk_mnt=- i skipped=0 c_cpu=0 c_mem=0 hog
  local -a ikeys=() issues=()
  local state="$STATE_DIR/alert.state" conf="$STATE_DIR/alert.confirm"
  issue() { ikeys+=("$1"); issues+=("$2"); }
  cpu_sample 1
  mem_stats
  read -r load _ </proc/loadavg
  if [[ -r $conf ]]; then read -r c_cpu c_mem <"$conf" || true; fi
  while read -r pct mnt _ _; do
    if ((pct > disk_max)); then disk_max=$pct disk_mnt=$mnt; fi
    if ((pct >= DISK_THRESHOLD)); then issue "disk:$mnt" "Ổ đĩa $mnt đã dùng ${pct}% (ngưỡng ${DISK_THRESHOLD}%)"; fi
  done < <(disk_usage)
  # CPU/RAM hay tăng vọt trong chốc lát → phải vượt ngưỡng ALERT_CONFIRM lần liên tiếp mới báo
  if ((CPU_PCT >= CPU_THRESHOLD)); then c_cpu=$((c_cpu + 1)); else c_cpu=0; fi
  if ((MEM_PCT >= MEM_THRESHOLD)); then c_mem=$((c_mem + 1)); else c_mem=0; fi
  if ((c_cpu >= ALERT_CONFIRM)); then issue cpu "CPU đang dùng ${CPU_PCT}% (ngưỡng ${CPU_THRESHOLD}%, $c_cpu lần kiểm tra liên tiếp)"; fi
  if ((c_mem >= ALERT_CONFIRM)); then issue mem "RAM đang dùng ${MEM_PCT}% (ngưỡng ${MEM_THRESHOLD}%, $c_mem lần kiểm tra liên tiếp)"; fi
  [[ $DRY_RUN == 1 ]] || echo "$c_cpu $c_mem" >"$conf"
  # Process "treo" ngốn tài nguyên (kèm tên nhân viên chạy nó)
  while IFS=$'\t' read -r pct hog; do
    [[ -n $hog ]] && issue "hog:$pct" "Process ngốn tài nguyên: $hog"
  done < <(ps -eo pid=,user=,pcpu=,pmem=,args= --sort=-pcpu |
    awk -v c="$HOG_CPU" -v m="$HOG_MEM" '$5 != "ps" && ($3 >= c || $4 >= m) && n++ < 3 {
      a = $5; for (i = 6; i <= NF; i++) a = a " " $i
      printf "%s\tPID %s của %s (%s) dùng %s%% CPU, %s%% RAM\n", $1, $1, $2, substr(a, 1, 40), $3, $4 }')
  # Dịch vụ systemd bị chết
  local failed
  failed=$(_failed_units)
  if ((failed > 0)); then
    issue units "$failed dịch vụ systemd bị lỗi: $({ systemctl --failed --no-legend --plain 2>/dev/null || true; } | awk '{ printf "%s ", $1 }')"
  fi
  [[ $DRY_RUN == 1 ]] || _alert_metrics "$CPU_PCT" "$MEM_PCT" "$SWAP_PCT" "$disk_max" "$load"

  header "Kiểm tra tài nguyên $(date '+%d/%m/%Y %H:%M:%S')"
  kv "CPU" "$(bar "$CPU_PCT" 25 $((CPU_THRESHOLD - 15)) "$CPU_THRESHOLD")  ngưỡng $CPU_THRESHOLD%"
  kv "RAM" "$(bar "$MEM_PCT" 25 $((MEM_THRESHOLD - 15)) "$MEM_THRESHOLD")  ngưỡng $MEM_THRESHOLD%"
  kv "Ổ đầy nhất ($disk_mnt)" "$(bar "$disk_max" 25 $((DISK_THRESHOLD - 15)) "$DISK_THRESHOLD")  ngưỡng $DISK_THRESHOLD%"
  kv "Load 1 phút" "$load"
  if ((c_cpu > 0 && c_cpu < ALERT_CONFIRM)); then status WARN "CPU ${CPU_PCT}% vượt ngưỡng — chờ lần kiểm tra sau xác nhận (tránh báo nhầm khi tăng vọt chốc lát)"; fi
  if ((c_mem > 0 && c_mem < ALERT_CONFIRM)); then status WARN "RAM ${MEM_PCT}% vượt ngưỡng — chờ lần kiểm tra sau xác nhận"; fi

  prev=$(cat "$state" 2>/dev/null || echo OK)
  if ((${#issues[@]})); then
    for i in "${!issues[@]}"; do
      status FAIL "${issues[i]}"
      _notify_event res WARN "res:${ikeys[i]}" 1 "${issues[i]}" || skipped=$((skipped + 1))
    done
    if ((skipped)); then log_info "$skipped vấn đề đã được báo trước đó, chưa nặng thêm — không gửi lại (nhắc lại sau $ALERT_REPEAT_MIN phút nếu vẫn còn)."; fi
    [[ $DRY_RUN == 1 ]] || echo ALERT >"$state"
  else
    status OK "Mọi chỉ số đều dưới ngưỡng"
    if [[ $prev == ALERT ]]; then
      alert_send "[ĐÃ ỔN ĐỊNH] $(hostname): tài nguyên đã trở lại bình thường" \
        "Lúc $(date '+%d/%m/%Y %H:%M:%S'): CPU ${CPU_PCT}%, RAM ${MEM_PCT}%, ổ đầy nhất ${disk_max}% ($disk_mnt)."
      _notify_clear '^res:' # sự cố lần sau sẽ được báo ngay
    fi
    [[ $DRY_RUN == 1 ]] || echo OK >"$state"
  fi
  unset -f issue
  # Phát hiện tấn công / bất thường bảo mật — gộp chung một tin với cảnh báo tài nguyên
  alert_security --no-flush || true
  _notify_flush
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
  header "Chống spam"
  kv "Gộp sự kiện trong" "$ALERT_BATCH_SEC giây thành một tin"
  kv "Báo lại khi" "nặng thêm ×$ALERT_ESCALATE, hoặc vẫn còn sau $ALERT_REPEAT_MIN phút"
  kv "Giới hạn" "$ALERT_RATE_MAX tin / 10 phút (CRITICAL luôn được gửi)"
  kv "CPU/RAM phải vượt" "$ALERT_CONFIRM lần kiểm tra liên tiếp"
  kv "Phát hiện thời gian thực" "$({ has systemctl && systemctl is-active toolkit-ids 2>/dev/null; } || echo 'chưa chạy (sudo sysadmin scheduler timers-install)')"
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
# Hai chế độ dùng CHUNG một bộ máy phân tích log (_ids_line):
#   live  — "alert watch" (dịch vụ toolkit-ids): đưa từng dòng log MỚI vào ngay khi xuất hiện
#           → chặn IP và gửi tin trong vài giây;
#   batch — "alert security" (timer mỗi phút): đưa các dòng log trong IDS_WINDOW_MIN phút qua,
#           rồi so trạng thái hệ thống với bản chuẩn (file, user, cổng, process).
IDS_WATCH_FILES="/etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/ssh/sshd_config /root/.ssh/authorized_keys /etc/crontab"
IDS_MODE="batch"
declare -gA IDS_FAIL=() IDS_CONN=() IDS_INVALID=() IDS_SUDO=() IDS_SINCE=() IDS_BANNED=() IDS_HISTORY=() IDS_HITS=()
declare -ga IDS_HIT_ORDER=()

# Mẫu log của sshd / sudo (một lần thử = một kết nối IP + cổng nguồn)
_RE_FAIL='Failed [a-z/-]+ for (invalid user )?([^ ]*) from ([0-9a-fA-F:.]+) port ([0-9]+)'
_RE_INV='Invalid user ([^ ]*) from ([0-9a-fA-F:.]+) port ([0-9]+)'
_RE_CLOSE='(Connection closed by|Disconnected from) (invalid|authenticating) user ([^ ]*) ([0-9a-fA-F:.]+) port ([0-9]+).*\[preauth\]'
_RE_MAX='maximum authentication attempts exceeded for (invalid user )?([^ ]*) from ([0-9a-fA-F:.]+) port ([0-9]+)'
_RE_OK='Accepted [a-z-]+ for ([^ ]+) from ([0-9a-fA-F:.]+)'
_RE_SUDO_FAIL='pam_unix\(sudo:auth\): authentication failure;.* ruser=([a-z_][a-z0-9_-]*)'
_RE_SUDO_DENY='sudo(\[[0-9]+\])?: +([a-z_][a-z0-9_-]*) : .*NOT in sudoers'

# _tail_window <tên> <file...> — "thời điểm<TAB>dòng" của các dòng log MỚI trong IDS_WINDOW_MIN phút.
# Ghi nhớ vị trí đã đọc (inode + byte) và lưu đệm các dòng kèm thời điểm đọc, nên timer chạy
# mỗi phút vẫn xét đủ cửa sổ; lần chạy đầu chỉ đánh dấu vị trí (không cảnh báo log cũ).
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
  cat "$buf"
}

_has_journald() { has journalctl && [[ -d /run/systemd/system ]]; }

# Log xác thực trong cửa sổ, dạng "epoch<TAB>dòng"
_ids_auth_lines() {
  if _has_journald; then
    { journalctl --since "-${IDS_WINDOW_MIN}min" --no-pager -q -o short-unix SYSLOG_FACILITY=4 + SYSLOG_FACILITY=10 2>/dev/null || true; } |
      sed -E 's/^([0-9]+)\.[0-9]+ /\1\t/'
  else _ids_file_times auth /var/log/auth.log /var/log/secure; fi
}
# Đọc file log, thay "thời điểm đọc" bằng thời điểm THẬT ghi trong dòng log (RFC 3339 của rsyslog
# hoặc kiểu cũ "Nov  2 09:34:36") — cần để mốc bỏ chặn IP chính xác. Dòng không có giờ → giữ thời điểm đọc.
_ids_file_times() {
  local tmp ep
  tmp=$(mktemp)
  _tail_window "$@" >"$tmp"
  ep=$(awk -F'\t' '{ n = split($2, a, " ")
      if (a[1] ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) print a[1]
      else if (a[1] ~ /^[A-Z][a-z][a-z]$/ && a[3] ~ /:/) print a[1] " " a[2] " " a[3]
      else print "@" $1 }' "$tmp" | date -f - +%s 2>/dev/null || true)
  if [[ $(grep -c . <<<"$ep") == "$(grep -c . "$tmp")" ]]; then paste <(printf '%s\n' "$ep") <(cut -f2- "$tmp")
  else cat "$tmp"; fi # không đổi được hết → dùng thời điểm đọc
  rm -f "$tmp"
}
_ids_kern() {
  if _has_journald; then
    journalctl -k --since "-${IDS_WINDOW_MIN}min" --no-pager -q -o short-iso 2>/dev/null || true
  else _tail_window kern /var/log/kern.log /var/log/syslog /var/log/messages | cut -f2-; fi
}
# Nguồn log cho chế độ thời gian thực: chỉ các dòng MỚI, giữ kết nối liên tục
_ids_live_source() {
  if _has_journald; then exec journalctl -f -n 0 -q -o short-unix SYSLOG_FACILITY=4 + SYSLOG_FACILITY=10; fi
  local f
  local -a files=()
  for f in /var/log/auth.log /var/log/secure; do [[ -e $f ]] && files+=("$f"); done
  ((${#files[@]})) || die "Không tìm thấy log xác thực (journald hoặc /var/log/auth.log)."
  exec tail -n 0 -F "${files[@]}" 2>/dev/null
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

_ids_whitelisted() { ip_in_list "$1" "$IDS_WHITELIST"; }

# _ban_ip <ip> <lý do> — chặn bằng ufw (nếu đang bật) hoặc iptables; ghi danh sách + lịch sử chặn
_ban_ip() {
  local ip=$1 why=${2:-thủ công} now
  [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || { log_error "IP không hợp lệ: $ip"; return 1; }
  _ids_whitelisted "$ip" && { log_warn "IP $ip nằm trong IDS_WHITELIST — không chặn."; return 1; }
  grep -q "^$ip " "$STATE_DIR/banned.list" 2>/dev/null && return 0
  if has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    run ufw insert 1 deny from "$ip" comment "sysadmin-toolkit IDS" >/dev/null || return 1
  elif has iptables; then
    run iptables -I INPUT -s "$ip" -j DROP -m comment --comment "sysadmin-toolkit IDS" || return 1
  else
    log_error "Không có ufw/iptables để chặn IP."; return 1
  fi
  now=$(date +%s)
  if [[ $DRY_RUN != 1 ]]; then
    printf '%s %s %s\n' "$ip" "$now" "${why// /_}" >>"$STATE_DIR/banned.list"
    printf '%s %s %s\n' "$ip" "$now" "${why// /_}" >>"$STATE_DIR/ban-history.log"
  fi
  IDS_BANNED[$ip]=1
  syslog_event "IDS BAN: $ip ($why)"
  return 0
}

# ---- Bộ máy phân tích log ----------------------------------------------------
_ids_reset() { IDS_FAIL=() IDS_CONN=() IDS_INVALID=() IDS_SUDO=() IDS_HITS=() IDS_HIT_ORDER=(); }

# Nạp lại: IP đang bị chặn, mốc bỏ chặn (chỉ tính lần thử SAU mốc này), số lần từng bị chặn
_ids_reload() {
  local ip t _
  IDS_BANNED=() IDS_SINCE=() IDS_HISTORY=()
  if [[ -r $STATE_DIR/banned.list ]]; then
    while read -r ip _; do [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] && IDS_BANNED[$ip]=1; done <"$STATE_DIR/banned.list"
  fi
  if [[ -r $STATE_DIR/ids-unban.list ]]; then
    while read -r ip t; do [[ $ip =~ ^[0-9a-fA-F:.]+$ && $t =~ ^[0-9]+$ ]] && IDS_SINCE[$ip]=$t; done <"$STATE_DIR/ids-unban.list"
  fi
  if [[ -r $STATE_DIR/ban-history.log ]]; then
    while read -r ip _; do
      [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || continue
      t=${IDS_HISTORY[$ip]:-0}
      IDS_HISTORY[$ip]=$((t + 1))
    done <"$STATE_DIR/ban-history.log"
  fi
  return 0
}

# _ids_keep "<mốc thời gian...>" <từ> → REPLY = các mốc ≥ từ
_ids_keep() { local t; REPLY=""; for t in $1; do if ((t >= $2)); then REPLY+="$t "; fi; done; }

# Mốc bắt đầu tính cho một IP: đầu cửa sổ, hoặc lúc vừa được bỏ chặn nếu muộn hơn
_ids_since() {
  local s=$(($2 - IDS_WINDOW_MIN * 60)) u=${IDS_SINCE[$1]:-0}
  if ((u > s)); then s=$u; fi
  REPLY=$s
}

# Dọn trạng thái cũ (dịch vụ nền chạy lâu ngày)
_ids_prune() {
  local k v cut=$(($1 - IDS_WINDOW_MIN * 60))
  for k in "${!IDS_CONN[@]}"; do v=${IDS_CONN[$k]#* }; if ((v < cut)); then unset "IDS_CONN[$k]"; fi; done
  for k in "${!IDS_FAIL[@]}"; do
    _ids_keep "${IDS_FAIL[$k]}" "$cut"
    if [[ -n $REPLY ]]; then IDS_FAIL[$k]=$REPLY; else unset "IDS_FAIL[$k]"; fi
  done
  for k in "${!IDS_INVALID[@]}"; do v=${IDS_INVALID[$k]}; if ((v < cut)); then unset "IDS_INVALID[$k]"; fi; done
  return 0
}

# _ids_hit <res|sec> <mức> <khoá> <độ lớn> <nội dung> [IP cần chặn]
_ids_hit() {
  local cat=$1 sev=$2 key=$3 level=$4 msg=$5 ip=${6:-}
  if [[ $IDS_MODE == live ]]; then
    local banned=""
    if [[ -n $ip && ${AUTO_BAN,,} == yes && -z ${IDS_BANNED[$ip]:-} ]] && _ban_ip "$ip" "IDS thời gian thực" >/dev/null; then
      msg+=" → ĐÃ TỰ ĐỘNG CHẶN"
      banned=1
    fi
    # Chỉ in khi có tin mới (hoặc vừa chặn IP) — dấu hiệu lặp lại không làm nhiễu màn hình/journal
    if _notify_event "$cat" "$sev" "$key" "$level" "$msg" || [[ -n $banned ]]; then
      if [[ $sev == CRITICAL ]]; then status FAIL "$(date '+%H:%M:%S') $msg"; else status WARN "$(date '+%H:%M:%S') $msg"; fi
    fi
  else
    [[ -n ${IDS_HITS[$key]+x} ]] || IDS_HIT_ORDER+=("$key")
    IDS_HITS[$key]="$sev"$'\t'"$level"$'\t'"$msg"$'\t'"$ip" # giữ kết quả mới nhất (lớn nhất) cho mỗi khoá
  fi
}

# _ids_line <epoch> <dòng log> — cập nhật bộ đếm, phát hiện dấu hiệu tấn công
_ids_line() {
  local now=$1 line=$2 ip="" port="" user="" st="" bad="" k n u list=""
  local -a arr=()
  if [[ $line =~ $_RE_FAIL ]]; then
    st=F bad=${BASH_REMATCH[1]} user=${BASH_REMATCH[2]} ip=${BASH_REMATCH[3]} port=${BASH_REMATCH[4]}
  elif [[ $line =~ $_RE_INV ]]; then
    st=C bad=1 user=${BASH_REMATCH[1]} ip=${BASH_REMATCH[2]} port=${BASH_REMATCH[3]}
  elif [[ $line =~ $_RE_CLOSE ]]; then
    st=C user=${BASH_REMATCH[3]} ip=${BASH_REMATCH[4]} port=${BASH_REMATCH[5]}
    if [[ ${BASH_REMATCH[2]} == invalid ]]; then bad=1; fi
  elif [[ $line =~ $_RE_MAX ]]; then
    st=C bad=${BASH_REMATCH[1]} user=${BASH_REMATCH[2]} ip=${BASH_REMATCH[3]} port=${BASH_REMATCH[4]}
  elif [[ $line =~ $_RE_OK ]]; then
    _ids_login_ok "$now" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  elif [[ $line =~ $_RE_SUDO_DENY ]]; then
    _ids_hit sec CRITICAL "sudo-deny:${BASH_REMATCH[2]}" 1 "${BASH_REMATCH[2]} cố dùng sudo nhưng KHÔNG có trong sudoers"
    return 0
  elif [[ $line =~ $_RE_SUDO_FAIL ]]; then
    _ids_sudo_fail "$now" "${BASH_REMATCH[1]}"
    return 0
  else
    return 0
  fi
  # Tên đăng nhập do kẻ tấn công tự đặt → chỉ giữ ký tự an toàn trước khi dùng làm khoá
  user=${user//[^A-Za-z0-9._-]/_}
  _ids_whitelisted "$ip" && return 0
  [[ -n ${IDS_BANNED[$ip]:-} ]] && return 0 # IP đã bị chặn: không báo thêm (chống nhiễu)
  # Đếm theo kết nối: "Invalid user" rồi "Failed password" của cùng một kết nối = 1 lần thử
  k="$ip $port"
  case ${IDS_CONN[$k]:-} in
    "") IDS_CONN[$k]="$st $now"; IDS_FAIL[$ip]+="$now " ;;
    C\ *) if [[ $st == F ]]; then IDS_CONN[$k]="F $now"; fi ;;
    F\ *) if [[ $st == F ]]; then IDS_FAIL[$ip]+="$now "; fi ;;
  esac
  if [[ -n $bad ]]; then IDS_INVALID[${user:-?}]=$now; fi

  # 1. Dò mật khẩu: ≥ IDS_SSH_FAIL_PER_IP lần thử từ một IP (chỉ tính sau lần bỏ chặn gần nhất)
  _ids_since "$ip" "$now"
  _ids_keep "${IDS_FAIL[$ip]:-}" "$REPLY"
  IDS_FAIL[$ip]=$REPLY
  read -ra arr <<<"$REPLY"
  n=${#arr[@]}
  if ((n >= IDS_SSH_FAIL_PER_IP)); then
    if [[ -n ${IDS_HISTORY[$ip]:-} ]]; then
      _ids_hit sec CRITICAL "ssh-brute:$ip" "$n" "Dò mật khẩu SSH: $n lần thất bại từ IP $ip trong $IDS_WINDOW_MIN phút — IP TÁI PHẠM, đã từng bị chặn ${IDS_HISTORY[$ip]} lần" "$ip"
    else
      _ids_hit sec WARN "ssh-brute:$ip" "$n" "Dò mật khẩu SSH: $n lần thất bại từ IP $ip trong $IDS_WINDOW_MIN phút" "$ip"
    fi
  fi
  # 2. Dò tên tài khoản (password spraying): nhiều username không tồn tại bị thử
  if [[ -n $bad ]]; then
    n=0
    for u in "${!IDS_INVALID[@]}"; do
      k=${IDS_INVALID[$u]}
      if ((k >= now - IDS_WINDOW_MIN * 60)); then
        n=$((n + 1))
        if ((n <= 5)); then list+="$u,"; fi
      fi
    done
    if ((n >= IDS_SPRAY_USERS)); then
      _ids_hit sec WARN "ssh-spray" "$n" "Dò tên tài khoản: $n username không tồn tại bị thử (${list%,}...)"
    fi
  fi
  return 0
}

# 3. Đăng nhập THÀNH CÔNG từ IP vừa thử sai nhiều lần → nghi bị chiếm tài khoản
_ids_login_ok() {
  local now=$1 user=${2//[^A-Za-z0-9._-]/_} ip=$3 n
  local -a arr=()
  _ids_whitelisted "$ip" && return 0
  _ids_since "$ip" "$now"
  _ids_keep "${IDS_FAIL[$ip]:-}" "$REPLY"
  read -ra arr <<<"$REPLY"
  n=${#arr[@]}
  # Gõ nhầm mật khẩu 1-2 lần là bình thường → chỉ báo từ IDS_COMPROMISE_FAILS lần trở lên
  if ((n >= IDS_COMPROMISE_FAILS)); then
    _ids_hit sec CRITICAL "ssh-compromise:$user@$ip" 1 "NGHI BỊ CHIẾM TÀI KHOẢN: $user đăng nhập thành công từ $ip sau $n lần thất bại"
  fi
  if [[ $user == root ]]; then _ids_hit sec WARN "ssh-root:$ip" 1 "Đăng nhập SSH trực tiếp bằng root từ $ip"; fi
  return 0
}

# 4. sudo sai mật khẩu nhiều lần (đếm theo dòng pam_unix: mỗi lần gõ sai một dòng)
_ids_sudo_fail() {
  local now=$1 user=$2 n
  local -a arr=()
  IDS_SUDO[$user]+="$now "
  _ids_keep "${IDS_SUDO[$user]}" $((now - IDS_WINDOW_MIN * 60))
  IDS_SUDO[$user]=$REPLY
  read -ra arr <<<"$REPLY"
  n=${#arr[@]}
  if ((n >= IDS_SUDO_FAIL)); then _ids_hit sec WARN "sudo-fail:$user" "$n" "sudo thất bại $n lần bởi $user (thử chiếm quyền root?)"; fi
  return 0
}

# ---- Chế độ thời gian thực ---------------------------------------------------
alert_watch() {
  local line t now last=0 rc src mtime cmtime
  require_root
  IDS_MODE="live"
  _ids_reset
  _ids_reload
  if _has_journald; then src="journald"; else src="/var/log/auth.log"; fi
  header "Phát hiện tấn công THỜI GIAN THỰC trên $(hostname)"
  kv "Nguồn log" "$src"
  kv "Tự chặn IP" "$AUTO_BAN (ngưỡng $IDS_SSH_FAIL_PER_IP lần thử / $IDS_WINDOW_MIN phút)"
  kv "Gộp tin" "$ALERT_BATCH_SEC giây · tối đa $ALERT_RATE_MAX tin / 10 phút"
  log_info "Đang theo dõi — sự kiện mới hiện ngay bên dưới. Ctrl+C để dừng."
  syslog_event "IDS WATCH: bắt đầu theo dõi $src"
  mtime=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || echo 0)
  while :; do
    if IFS= read -r -t 1 line; then
      printf -v now '%(%s)T' -1
      if [[ $line =~ ^([0-9]+)\.[0-9]+\ (.*)$ ]]; then t=${BASH_REMATCH[1]} line=${BASH_REMATCH[2]}; else t=$now; fi
      _ids_line "$t" "$line" || true
    else
      rc=$?
      if ((rc <= 128)); then log_warn "Nguồn log đã đóng — dừng (systemd sẽ tự khởi động lại)."; break; fi
    fi
    printf -v now '%(%s)T' -1
    if ((now - last >= 5)); then # nạp lại danh sách chặn/bỏ chặn do lệnh khác thay đổi
      cmtime=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || echo 0)
      if [[ $cmtime != "$mtime" ]]; then # toolkit.conf vừa được sửa → áp dụng ngay
        mtime=$cmtime
        load_config
        log_info "Đã nạp lại cấu hình (AUTO_BAN=$AUTO_BAN, ngưỡng $IDS_SSH_FAIL_PER_IP lần)."
      fi
      _ids_reload
      _ids_prune "$now"
      last=$now
    fi
    _notify_tick "$now"
  done < <(_ids_live_source)
  _notify_flush
  return 0
}

# ---- Chế độ quét định kỳ -----------------------------------------------------
alert_security() {
  local flush=1 kern ip user line key sev level msg t i crit=0 skipped=0
  local -a finds=() keys=() sevs=() levels=() bans=()
  local -A justbanned=()
  [[ ${1:-} == --no-flush ]] && flush=0
  # add <mức> <khoá chống trùng> <mô tả> [độ lớn]
  add() { sevs+=("$1"); keys+=("$2"); finds+=("$3"); levels+=("${4:-1}"); }
  ((EUID == 0)) || log_warn "Không phải root — nhiều kiểm tra bảo mật sẽ thiếu dữ liệu (chạy bằng sudo)."
  if [[ ! -f $STATE_DIR/ids-integrity.sha ]] && ((EUID == 0)); then
    _ids_baseline_files quiet
    log_info "Lần chạy đầu: đã tạo trạng thái chuẩn (baseline) để so sánh cho các lần sau."
  fi

  # 1–4. Log xác thực: cùng bộ máy với chế độ thời gian thực
  IDS_MODE="batch"
  _ids_reset
  _ids_reload
  while IFS=$'\t' read -r t line; do
    [[ $t =~ ^[0-9]+$ ]] && _ids_line "$t" "$line"
  done < <(_ids_auth_lines)
  for key in "${IDS_HIT_ORDER[@]}"; do
    IFS=$'\t' read -r sev level msg ip <<<"${IDS_HITS[$key]}"
    add "$sev" "$key" "$msg" "$level"
    if [[ -n $ip && ${AUTO_BAN,,} == yes ]]; then bans+=("$ip"); fi
  done

  # 5. Quét cổng: tường lửa chặn nhiều gói từ một IP
  kern=$(_ids_kern)
  while read -r t ip; do
    [[ -n $ip ]] || continue
    _ids_whitelisted "$ip" && continue
    [[ -n ${IDS_BANNED[$ip]:-} ]] && continue
    add WARN "portscan:$ip" "Nghi quét cổng: tường lửa chặn $t gói từ $ip" "$t"
    if [[ ${AUTO_BAN,,} == yes ]]; then bans+=("$ip"); fi
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

  # ---- In kết quả, chặn IP, đưa vào hàng đợi cảnh báo
  header "Phát hiện tấn công & bất thường (cửa sổ $IDS_WINDOW_MIN phút)"
  ((${#finds[@]})) || status OK "Không phát hiện dấu hiệu tấn công"
  for ip in $(printf '%s\n' "${bans[@]}" | sort -u); do
    if _ban_ip "$ip" "IDS tự động"; then status OK "Đã TỰ ĐỘNG CHẶN IP $ip"; justbanned[$ip]=1; fi
  done
  for i in "${!finds[@]}"; do
    if [[ ${sevs[i]} == CRITICAL ]]; then status FAIL "${finds[i]}"; crit=$((crit + 1)); else status WARN "${finds[i]}"; fi
    _notify_event sec "${sevs[i]}" "${keys[i]}" "${levels[i]}" "${finds[i]}" || skipped=$((skipped + 1))
  done
  for ip in "${!justbanned[@]}"; do
    _notify_event sec WARN "ban:$ip" 1 "IP $ip đã bị chặn tự động bằng tường lửa" || true
  done
  if ((skipped)); then
    log_info "$skipped dấu hiệu đã được báo trước đó và chưa nặng thêm — không gửi lại (nhắc lại sau $ALERT_REPEAT_MIN phút nếu vẫn còn)."
  fi
  if ((flush)); then _notify_flush; fi
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
  local ip=$1 now
  require_root
  [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || die "IP không hợp lệ: $ip"
  if has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then run ufw delete deny from "$ip" >/dev/null || true
  elif has iptables; then
    while iptables -C INPUT -s "$ip" -j DROP -m comment --comment "sysadmin-toolkit IDS" 2>/dev/null; do
      run iptables -D INPUT -s "$ip" -j DROP -m comment --comment "sysadmin-toolkit IDS" || break
      [[ $DRY_RUN == 1 ]] && break
    done
  fi
  if [[ $DRY_RUN != 1 ]]; then
    now=$(date +%s)
    { grep -v "^$ip " "$STATE_DIR/banned.list" 2>/dev/null || true; } >"$STATE_DIR/banned.tmp" && mv "$STATE_DIR/banned.tmp" "$STATE_DIR/banned.list"
    # Mốc bỏ chặn: các lần thử TRƯỚC mốc này không còn được tính → không bị chặn lại oan,
    # nhưng nếu IP tấn công tiếp thì bị chặn lại ngay và báo là IP tái phạm
    { grep -v "^$ip " "$STATE_DIR/ids-unban.list" 2>/dev/null || true; echo "$ip $now"; } >"$STATE_DIR/ids-unban.tmp" &&
      mv "$STATE_DIR/ids-unban.tmp" "$STATE_DIR/ids-unban.list"
  fi
  _notify_clear "^[^ ]*[:@]${ip//./\\.} " # lần tấn công sau được báo ngay, không bị coi là "đã báo"
  syslog_event "IDS UNBAN: $ip"
  log_ok "Đã bỏ chặn $ip — nếu IP này tấn công lại sẽ bị chặn ngay và được báo là IP tái phạm."
}

_pick_banned() {
  local ip t why
  [[ -r $STATE_DIR/banned.list ]] || return 0
  while read -r ip t why; do printf '%s\tchặn lúc %s (%s)\n' "$ip" "$(date -d "@$t" '+%d/%m %H:%M')" "${why//_/ }"; done <"$STATE_DIR/banned.list"
}

alert_banned() {
  local ip t why times
  header "IP đang bị chặn bởi toolkit"
  if [[ ! -s $STATE_DIR/banned.list ]]; then printf '  (không có)\n'
  else
    while read -r ip t why; do
      times=$(grep -c "^$ip " "$STATE_DIR/ban-history.log" 2>/dev/null || true)
      printf '  %-40s %s  %s%s\n' "$ip" "$(date -d "@$t" '+%d/%m/%Y %H:%M')" "${why//_/ }" "$( ((times > 1)) && printf ' — bị chặn lần thứ %s' "$times" || true)"
    done <"$STATE_DIR/banned.list"
  fi
  printf '\n%sBỏ chặn: %s alert unban <IP> · Tự động chặn: AUTO_BAN=yes trong toolkit.conf (hiện: %s)%s\n' "$C_DIM" "$PROG" "$AUTO_BAN" "$C_RESET"
}
