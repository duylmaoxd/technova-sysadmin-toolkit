#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # biến toàn cục dùng chung giữa các file
# =============================================================================
#  modules/monitor.sh — CHỨC NĂNG 2: GIÁM SÁT TÀI NGUYÊN & HOẠT ĐỘNG NHÂN VIÊN
#  Nhu cầu của Tech Lead (làm việc từ xa qua SSH): ai đang đăng nhập & làm gì,
#  ai đang treo process ngốn CPU/RAM, xử lý ngay (renice/kill), máy chủ có
#  khoẻ không (CPU, RAM, disk, log, dò mật khẩu SSH), báo cáo định kỳ.
#  Kiến thức: /proc, ps, w/who/last, nice/kill & tín hiệu, free, df, iostat,
#             journald/rsyslog, quy trình chẩn đoán sự cố.
#  Các hàm đo (cpu_sample, mem_stats, disk_usage) được module alert dùng lại.
# =============================================================================

register_module monitor 2 "Giám sát tài nguyên & hoạt động nhân viên"
register_action who          ""  "Ai đang đăng nhập (từ IP nào), đang chạy lệnh gì, lịch sử đăng nhập"
register_action usage        ""  "Tài nguyên CPU/RAM đang dùng theo TỪNG NHÂN VIÊN"
register_action top          ""  "Top tiến trình tốn CPU/RAM (kèm người chạy)" "Số tiến trình=10" "Sắp xếp theo=cpu|mem"
register_action hogs         ""  "Phát hiện process \"treo\" ngốn tài nguyên vượt ngưỡng" "Ngưỡng CPU (%)=$HOG_CPU" "Ngưỡng RAM (%)=$HOG_MEM"
register_action renice       "rd" "Hạ độ ưu tiên một tiến trình (renice) thay vì kill" "PID=@_pick_pid" "Giá trị nice (0..19)=15"
register_action kill         "rd" "Dừng tiến trình gây sự cố (kill, có xác nhận)" "PID=@_pick_pid" "Tín hiệu=TERM|KILL|HUP|STOP|CONT"
register_action overview     ""  "Tổng quan máy chủ: CPU, RAM, swap, disk, tải, top tiến trình"
register_action memory       ""  "Bộ nhớ: free, /proc/meminfo, tiến trình tốn RAM, OOM"
register_action disk         ""  "Ổ đĩa: dung lượng, inode, I/O (df, iostat), thư mục lớn nhất"
register_action logs         ""  "Lỗi gần đây trong log (journald, rsyslog, kernel)" "Số dòng=30"
register_action logcheck     "r" "KIỂM TRA LOG hệ thống: đăng nhập, sudo, tài khoản, lỗi dịch vụ, kernel, tường lửa" "Số giờ gần nhất=$LOGCHECK_HOURS"
register_action log-upload   "r" "Đóng gói log (kèm báo cáo logcheck) và đưa lên Google Drive" "Số giờ gần nhất=$LOGCHECK_HOURS"
register_action auth         "r" "Đăng nhập SSH thất bại — phát hiện dò mật khẩu (brute-force)" "Số IP hiển thị=10"
register_action troubleshoot ""  "Quy trình chẩn đoán sự cố máy chủ tự động (10 bước)"
register_action report       ""  "Xuất báo cáo hệ thống ra file HTML + TXT"
register_action watch        "i" "Bảng theo dõi thời gian thực (nhấn q để thoát)" "Chu kỳ làm mới (giây)=2"
register_action history      ""  "Lịch sử số liệu đã ghi (metrics.csv do alert check ghi)" "Số dòng=20"

# ------------------------------------------------------------ HÀM ĐO CHUNG ---
# cpu_sample [giây] — %CPU toàn hệ thống và %iowait trong khoảng lấy mẫu (từ /proc/stat)
cpu_sample() {
  local -a a b
  local k ta=0 tb=0 dt
  read -r -a a </proc/stat
  sleep "${1:-1}"
  read -r -a b </proc/stat
  # cột: user nice system idle iowait irq softirq steal
  for k in 1 2 3 4 5 6 7 8; do ta=$((ta + a[k])) tb=$((tb + b[k])); done
  dt=$((tb - ta))
  if ((dt <= 0)); then CPU_PCT=0 CPU_IOWAIT=0; return 0; fi
  CPU_PCT=$((100 * (dt - (b[4] - a[4]) - (b[5] - a[5])) / dt))
  CPU_IOWAIT=$((100 * (b[5] - a[5]) / dt))
}

# mem_stats — đặt MEM_TOTAL, MEM_AVAIL, MEM_PCT, SWAP_TOTAL, SWAP_USED, SWAP_PCT (đơn vị KB)
mem_stats() {
  local k v
  MEM_TOTAL=1 MEM_AVAIL=0 SWAP_TOTAL=0 SWAP_FREE=0
  while read -r k v _; do
    case $k in
      MemTotal:) MEM_TOTAL=$v ;;
      MemAvailable:) MEM_AVAIL=$v ;;
      SwapTotal:) SWAP_TOTAL=$v ;;
      SwapFree:) SWAP_FREE=$v ;;
    esac
  done </proc/meminfo
  MEM_PCT=$(((MEM_TOTAL - MEM_AVAIL) * 100 / MEM_TOTAL))
  SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
  if ((SWAP_TOTAL > 0)); then SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL)); else SWAP_PCT=0; fi
}

# disk_usage — mỗi dòng: "<%dùng> <điểm mount> <tổng KB> <đã dùng KB>"
disk_usage() {
  local pct mnt size used
  while read -r pct mnt size used; do
    # bỏ qua mount dạng file (vd /etc/hosts trong container Docker)
    if [[ -d $mnt ]]; then printf '%s %s %s %s\n' "$pct" "$mnt" "$size" "$used"; fi
  done < <({ df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null || true; } |
    awk 'NR > 1 && $6 !~ /^\/(snap|var\/snap)\// { gsub("%", "", $5); print $5, $6, $2, $3 }')
  return 0
}

# inode_usage — mỗi dòng: "<%inode> <điểm mount>"
inode_usage() {
  { df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x vfat 2>/dev/null || true; } |
    awk 'NR > 1 && $5 ~ /%/ { gsub("%", "", $5); print $5, $6 }'
}

_cpu_snapshot() { awk '/^cpu/ { t = 0; for (i = 2; i <= 9; i++) t += $i; print $1, t, $5 + $6 }' /proc/stat; }
_zombies() { ps -e -o stat= | awk '/^Z/ { z++ } END { print z + 0 }'; }
_failed_units() {
  if has systemctl && [[ -d /run/systemd/system ]]; then
    { systemctl --failed --no-legend --plain 2>/dev/null || true; } | wc -l
  else
    echo 0
  fi
}

# ------------------------------------------------------------------ ACTIONS ---
monitor_overview() {
  local l1 l5 l15 pct mnt size used
  detect_distro
  read -r l1 l5 l15 _ </proc/loadavg
  cpu_sample 1
  mem_stats
  header "Tổng quan $(hostname) — $(date '+%d/%m/%Y %H:%M:%S')"
  kv "Hệ điều hành" "$DISTRO_NAME"
  kv "Kernel" "$(uname -r)"
  kv "Thời gian chạy" "$(uptime -p 2>/dev/null || cut -d' ' -f1 /proc/uptime)"
  kv "Tải 1/5/15 phút" "$l1  $l5  $l15   (số CPU: $(nproc))"
  kv "CPU" "$(bar "$CPU_PCT" 30 $((CPU_THRESHOLD - 15)) "$CPU_THRESHOLD")  iowait ${CPU_IOWAIT}%"
  kv "RAM" "$(bar "$MEM_PCT" 30 $((MEM_THRESHOLD - 15)) "$MEM_THRESHOLD")  $(human_kb $((MEM_TOTAL - MEM_AVAIL))) / $(human_kb "$MEM_TOTAL")"
  if ((SWAP_TOTAL > 0)); then kv "Swap" "$(bar "$SWAP_PCT" 30 50 80)  $(human_kb "$SWAP_USED") / $(human_kb "$SWAP_TOTAL")"
  else kv "Swap" "(không có)"; fi
  header "Ổ đĩa"
  while read -r pct mnt size used; do
    printf '  %s %s  %s / %s\n' "$(pad "$mnt" 22)" "$(bar "$pct" 25 $((DISK_THRESHOLD - 15)) "$DISK_THRESHOLD")" "$(human_kb "$used")" "$(human_kb "$size")"
  done < <(disk_usage)
  header "Top 5 tiến trình theo CPU"
  ps_top pid,user,pcpu,pmem,comm -pcpu 5
  header "Top 5 tiến trình theo RAM"
  ps_top pid,user,pcpu,pmem,rss,comm -rss 5
  header "Khác"
  kv "Phiên đăng nhập" "$(who | wc -l)"
  kv "Dịch vụ bị lỗi" "$(_failed_units)"
  kv "Tiến trình zombie" "$(_zombies)"
}

monitor_memory() {
  mem_stats
  header "Bộ nhớ (free -h)"
  free -h
  header "Chi tiết (/proc/meminfo)"
  awk '/^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Shmem|Slab):/ {
         printf "  %-14s %10.1f MB\n", $1, $2 / 1024 }' /proc/meminfo
  header "Top 10 tiến trình theo RAM thực (RSS)"
  ps_top pid,user,pmem,rss,comm -rss 10
  header "OOM killer (hết bộ nhớ)"
  local n
  n=$(journalctl -k -b --no-pager 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)
  if ((${n:-0} > 0)); then status WARN "Kernel đã phải diệt tiến trình vì hết RAM $n lần từ lần khởi động này"
  else status OK "Chưa có sự kiện OOM từ lần khởi động này"; fi
  cat <<'EOF'

  • "free" thấp chưa chắc là thiếu RAM: Linux dùng RAM trống làm cache (buff/cache) và
    giải phóng ngay khi cần → hãy nhìn cột "available".
  • Swap tăng liên tục + iowait cao = thiếu RAM thật sự (hiện tượng "thrashing").
EOF
}

monitor_disk() {
  local pct mnt size used
  header "Dung lượng (df)"
  while read -r pct mnt size used; do
    printf '  %s %s  %s / %s\n' "$(pad "$mnt" 22)" "$(bar "$pct" 25 $((DISK_THRESHOLD - 15)) "$DISK_THRESHOLD")" "$(human_kb "$used")" "$(human_kb "$size")"
  done < <(disk_usage)
  header "Inode (df -i) — hết inode thì không tạo được file dù còn dung lượng"
  while read -r pct mnt; do
    printf '  %s %s\n' "$(pad "$mnt" 22)" "$(bar "$pct" 25 70 90)"
  done < <(inode_usage)
  header "Hoạt động I/O"
  if has iostat; then
    { iostat -dxyz 1 1 2>/dev/null || true; } | awk '$1 !~ /^(Linux|loop|ram)/ && NF'
    printf '%s(chỉ hiện thiết bị có hoạt động trong 1 giây vừa đo; bỏ qua loop/ram)%s\n' "$C_DIM" "$C_RESET"
  else
    log_warn "Chưa có iostat — $(pkg_hint sysstat)"
    awk '$3 !~ /^(loop|ram)/ { printf "  %-10s đọc %10d lần   ghi %10d lần\n", $3, $4, $8 }' /proc/diskstats | take 10
  fi
  header "Thư mục lớn nhất trong /home và ${SHARED_ROOT} (du)"
  { du -xsh /home/* "$SHARED_ROOT"/* 2>/dev/null || true; } | sort -rh | take 10 | sed 's/^/  /'
  ((EUID == 0)) || printf '  %s(chạy bằng sudo để đo được thư mục của mọi nhân viên)%s\n' "$C_DIM" "$C_RESET"
}

monitor_logs() {
  local n=${1:-30} f
  is_int "$n" || die "Số dòng không hợp lệ"
  if has journalctl; then
    header "Lỗi từ lần khởi động này (journalctl -p err -b)"
    journalctl -p err -b -n "$n" --no-pager 2>&1 || true
    if ((EUID != 0)) && ! id -nG | grep -qwE 'adm|systemd-journal|wheel'; then
      log_warn "User thường chỉ thấy log của mình — chạy bằng sudo để xem toàn hệ thống."
    fi
  fi
  for f in /var/log/syslog /var/log/messages; do
    if [[ -r $f ]]; then
      header "Từ khoá lỗi trong $f (rsyslog)"
      grep -iE 'error|fail|critical|panic|segfault' "$f" | tail -n "$n" | cut -c1-200 || true
    fi
  done
  header "Lỗi kernel"
  dmesg --level=emerg,alert,crit,err 2>/dev/null | tail -n 10 ||
    journalctl -k -p err -b -n 10 --no-pager 2>/dev/null || log_warn "Không đọc được log kernel (cần root)."
}

monitor_auth() {
  local n=${1:-10} data fails
  if has journalctl && [[ -d /run/systemd/system ]]; then
    data=$(journalctl -u ssh -u sshd --since "7 days ago" --no-pager -o short 2>/dev/null || true)
  fi
  if [[ -z ${data:-} ]]; then data=$(cat /var/log/auth.log /var/log/secure 2>/dev/null || true); fi
  if [[ -z $data ]]; then
    log_warn "Không có log SSH (chưa cài openssh-server, chưa có đăng nhập, hoặc cần quyền root)."
    return 0
  fi
  fails=$(grep -cE 'Failed [a-z/-]+ for ' <<<"$data" || true)
  header "Đăng nhập SSH thất bại (7 ngày): $fails lần"
  if ((fails > 0)); then
    printf '  %sTop IP thử đăng nhập:%s\n' "$C_BOLD" "$C_RESET"
    { grep -E 'Failed [a-z/-]+ for ' <<<"$data" | grep -oE 'from [0-9a-fA-F:.]+' || true; } | awk '{ print $2 }' |
      sort | uniq -c | sort -rn | take "$n" | awk '{ printf "    %6d lần  %s\n", $1, $2 }'
    printf '  %sTên đăng nhập bị thử nhiều nhất:%s\n' "$C_BOLD" "$C_RESET"
    { sed -nE 's/.*Failed [a-z/-]+ for (invalid user )?([^ ]+) from .*/\2/p' <<<"$data" || true; } |
      sort | uniq -c | sort -rn | take 5 | awk '{ printf "    %6d lần  %s\n", $1, $2 }'
  fi
  header "Đăng nhập thành công gần đây"
  grep -E 'Accepted (password|publickey)' <<<"$data" | tail -n 5 | cut -c1-160 || printf '  (không có)\n'
  printf '\n%sChặn IP: sudo ufw deny from <IP> · Tự động: cài fail2ban · Tắt đăng nhập bằng mật khẩu (dùng SSH key).%s\n' "$C_DIM" "$C_RESET"
}

monitor_troubleshoot() {
  local cores l1 l100 n pct mnt gw out
  local -a tips=()
  status_reset
  cores=$(nproc)
  cat <<'EOF'
Quy trình xử lý sự cố: (1) xác định triệu chứng → (2) thu thập số liệu & log →
(3) khoanh vùng: CPU / RAM / đĩa / mạng / dịch vụ → (4) xử lý → (5) kiểm tra lại & ghi nhận.
Toolkit tự động hoá bước 2–3 dưới đây:
EOF
  header "1. Tải hệ thống (load average)"
  read -r l1 _ </proc/loadavg
  l100=$(awk -v l="$l1" 'BEGIN { print int(l * 100) }')
  if ((l100 > cores * 200)); then status FAIL "Load $l1 > 2 × số CPU ($cores) — quá tải nghiêm trọng"; tips+=("Quá tải: '$PROG monitor hogs' tìm process ngốn tài nguyên, '$PROG monitor usage' xem nhân viên nào dùng nhiều.")
  elif ((l100 > cores * 100)); then status WARN "Load $l1 > số CPU ($cores)"; tips+=("Load cao: kiểm tra CPU và I/O wait.")
  else status OK "Load $l1 (số CPU: $cores)"; fi

  header "2. CPU"
  cpu_sample 1
  if ((CPU_PCT >= 95)); then status FAIL "CPU ${CPU_PCT}%"
  elif ((CPU_PCT >= CPU_THRESHOLD)); then status WARN "CPU ${CPU_PCT}% (ngưỡng $CPU_THRESHOLD%)"
  else status OK "CPU ${CPU_PCT}%"; fi
  if ((CPU_PCT >= CPU_THRESHOLD)); then
    ps_top pid,user,pcpu,comm -pcpu 3 | sed 's/^/        /'
    tips+=("CPU cao: '$PROG monitor renice <PID>' hạ ưu tiên hoặc '$PROG monitor kill <PID>' dừng tiến trình gây tải.")
  fi

  header "3. Chờ I/O (iowait)"
  if ((CPU_IOWAIT >= 20)); then status WARN "iowait ${CPU_IOWAIT}% — ổ đĩa đang chậm/bão hoà"; tips+=("iowait cao: '$PROG monitor io' để xem ổ đĩa nào bận (%util).")
  else status OK "iowait ${CPU_IOWAIT}%"; fi

  header "4. Bộ nhớ"
  mem_stats
  if ((MEM_PCT >= 95)); then status FAIL "RAM dùng ${MEM_PCT}%"
  elif ((MEM_PCT >= MEM_THRESHOLD)); then status WARN "RAM dùng ${MEM_PCT}% (ngưỡng $MEM_THRESHOLD%)"
  else status OK "RAM dùng ${MEM_PCT}% (còn khả dụng $(human_kb "$MEM_AVAIL"))"; fi
  if ((SWAP_TOTAL > 0 && SWAP_PCT >= 50)); then status WARN "Swap dùng ${SWAP_PCT}%"; tips+=("Thiếu RAM: '$PROG monitor memory' tìm tiến trình tốn RAM; cân nhắc thêm RAM/swap.")
  elif ((SWAP_TOTAL == 0)); then status INFO "Không có swap"
  else status OK "Swap dùng ${SWAP_PCT}%"; fi

  header "5. OOM killer"
  n=$(journalctl -k -b --no-pager 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)
  if ((${n:-0} > 0)); then status WARN "$n sự kiện hết bộ nhớ (OOM) từ lần khởi động này"; tips+=("Có OOM: journalctl -k | grep -i oom để biết tiến trình nào bị diệt.")
  else status OK "Không có sự kiện OOM"; fi

  header "6. Dung lượng ổ đĩa"
  while read -r pct mnt _ _; do
    if ((pct >= 95)); then status FAIL "$mnt đầy ${pct}%"; tips+=("Đĩa $mnt gần đầy: '$PROG monitor disk' xem thư mục lớn, '$PROG scheduler maintenance' dọn file tạm & log cũ.")
    elif ((pct >= DISK_THRESHOLD)); then status WARN "$mnt dùng ${pct}%"
    else status OK "$mnt dùng ${pct}%"; fi
  done < <(disk_usage)
  while read -r pct mnt; do
    if ((pct >= 90)); then status WARN "$mnt dùng ${pct}% inode"; tips+=("Hết inode ở $mnt: tìm thư mục chứa quá nhiều file nhỏ.")
    fi
  done < <(inode_usage)

  header "7. Dịch vụ systemd"
  n=$(_failed_units)
  if ((n > 0)); then
    status FAIL "$n unit bị lỗi:"
    { systemctl --failed --no-legend --plain 2>/dev/null || true; } | awk '{ print "        " $1 }'
    tips+=("Dịch vụ lỗi: systemctl status <unit> và journalctl -u <unit> -b để xem nguyên nhân.")
  else status OK "Không có unit bị lỗi"; fi

  header "8. Mạng"
  gw=$(ip route show default 2>/dev/null | awk '{ print $3; exit }')
  if [[ -n $gw ]]; then
    status OK "Có default gateway $gw"
    if ping -c 1 -W 2 "$gw" >/dev/null 2>&1; then status OK "Ping gateway thành công"
    else status WARN "Không ping được gateway (có thể bị chặn ICMP)"; fi
  else
    status FAIL "Không có default route"; tips+=("Mạng: kiểm tra 'ip addr', 'ip route' và cấu hình netplan/nmcli.")
  fi
  if getent hosts google.com >/dev/null 2>&1; then status OK "Phân giải DNS hoạt động"
  else status WARN "Không phân giải được tên miền"; tips+=("DNS: kiểm tra /etc/resolv.conf hoặc resolvectl status.")
  fi

  header "9. Lỗi trong log (1 giờ qua)"
  n=$(journalctl -p err --since "1 hour ago" --no-pager -q 2>/dev/null | wc -l || true)
  if ((${n:-0} > 20)); then status WARN "$n dòng lỗi trong 1 giờ qua"; tips+=("Nhiều lỗi: '$PROG monitor logs' để xem chi tiết.")
  else status OK "${n:-0} dòng lỗi trong 1 giờ qua"; fi

  header "10. Đồng bộ thời gian & tiến trình zombie"
  out=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  case $out in
    yes) status OK "Đồng hồ đã đồng bộ NTP" ;;
    no) status WARN "Đồng hồ CHƯA đồng bộ NTP — log & chứng chỉ có thể sai thời gian"; tips+=("Thời gian: timedatectl set-ntp true.") ;;
    *) status INFO "Không kiểm tra được NTP" ;;
  esac
  n=$(_zombies)
  if ((n > 0)); then status WARN "$n tiến trình zombie"; tips+=("Zombie: tiến trình cha không wait() — khởi động lại tiến trình cha.")
  else status OK "Không có tiến trình zombie"; fi

  status_summary
  if ((${#tips[@]})); then
    header "Gợi ý xử lý"
    printf '  • %s\n' "${tips[@]}"
  fi
}

_html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Biểu đồ đường (SVG) CPU & RAM từ metrics.csv
_metrics_svg() {
  local f="$REPORT_DIR/metrics.csv"
  [[ -f $f ]] || return 0
  tail -n +2 "$f" | tail -n 96 | awk -F, '
    { cpu[NR] = $2; mem[NR] = $3; t[NR] = $1 }
    END {
      if (NR < 2) exit
      W = 720; H = 160
      for (i = 1; i <= NR; i++) {
        x = (i - 1) * W / (NR - 1)
        pc = pc sprintf("%.1f,%.1f ", x, H - cpu[i] * H / 100)
        pm = pm sprintf("%.1f,%.1f ", x, H - mem[i] * H / 100)
      }
      printf "<h2>Lịch sử CPU / RAM (%d lần đo gần nhất)</h2>\n", NR
      printf "<svg viewBox=\"-30 -10 %d %d\" class=\"chart\" role=\"img\">\n", W + 40, H + 40
      for (g = 0; g <= 100; g += 25) printf "<line x1=\"0\" x2=\"%d\" y1=\"%.1f\" y2=\"%.1f\" class=\"grid\"/><text x=\"-28\" y=\"%.1f\">%d%%</text>\n", W, H - g * H / 100, H - g * H / 100, H - g * H / 100 + 4, g
      printf "<polyline points=\"%s\" class=\"cpu\"/>\n<polyline points=\"%s\" class=\"mem\"/>\n", pc, pm
      printf "<text x=\"0\" y=\"%d\">%s</text><text x=\"%d\" y=\"%d\" text-anchor=\"end\">%s</text>\n", H + 22, t[1], W, H + 22, t[NR]
      printf "</svg>\n<p class=\"legend\"><span class=\"k cpu\"></span>CPU %% <span class=\"k mem\"></span>RAM %%</p>\n"
    }'
}

monitor_report() {
  local host ts txt html s title fn out
  local -a parts
  host=$(hostname -s 2>/dev/null || hostname)
  ts=$(date +%Y%m%d-%H%M%S)
  txt="$REPORT_DIR/report-$host-$ts.txt"
  html="$REPORT_DIR/report-$host-$ts.html"
  local -a sections=(
    "Tổng quan|monitor_overview"
    "Chẩn đoán tự động|monitor_troubleshoot"
    "Bộ nhớ|monitor_memory"
    "Ổ đĩa|monitor_disk"
    "Nhân viên đang đăng nhập|monitor_who"
    "Tài nguyên theo nhân viên|monitor_usage"
    "Process ngốn tài nguyên|monitor_hogs"
    "Lỗi gần đây|monitor_logs 20"
    "Người dùng|users_list"
  )
  log_info "Đang thu thập số liệu cho báo cáo (khoảng 10 giây)..."
  TOOLKIT_COLOR=0
  setup_colors
  {
    printf 'BÁO CÁO HỆ THỐNG — %s — %s\n' "$host" "$(date '+%d/%m/%Y %H:%M:%S')"
    printf 'Tạo bởi %s v%s\n\n' "$TOOLKIT_NAME" "$TOOLKIT_VERSION"
  } >"$txt"
  cat >"$html" <<EOF
<!doctype html>
<html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Báo cáo hệ thống $host</title>
<style>
  :root { --bg:#f6f7f9; --card:#fff; --fg:#1d2330; --muted:#5b6475; --line:#d9dde5; --cpu:#2563eb; --mem:#ea580c; }
  @media (prefers-color-scheme: dark) { :root { --bg:#14171c; --card:#1d2128; --fg:#e6e9ef; --muted:#9aa3b2; --line:#333a45; --cpu:#60a5fa; --mem:#fb923c; } }
  body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 system-ui, sans-serif; }
  main { max-width:1000px; margin:0 auto; padding:24px 16px; }
  header p { color:var(--muted); margin:4px 0 0; }
  section { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:4px 18px 14px; margin:16px 0; }
  h1 { margin:0; font-size:1.6rem; } h2 { font-size:1.1rem; margin:14px 0 8px; }
  pre { margin:0; overflow-x:auto; font:13px/1.45 "DejaVu Sans Mono", "Noto Sans Mono", ui-monospace, Menlo, Consolas, monospace; }
  .chart { width:100%; height:auto; } .chart text { fill:var(--muted); font-size:11px; }
  .grid { stroke:var(--line); } polyline { fill:none; stroke-width:2; }
  polyline.cpu { stroke:var(--cpu); } polyline.mem { stroke:var(--mem); }
  .legend { color:var(--muted); } .k { display:inline-block; width:12px; height:12px; border-radius:2px; margin:0 6px 0 14px; vertical-align:-1px; }
  .k.cpu { background:var(--cpu); } .k.mem { background:var(--mem); }
</style></head><body><main>
<header><h1>Báo cáo hệ thống: $host</h1>
<p>Thời điểm: $(date '+%d/%m/%Y %H:%M:%S') · Tạo bởi $TOOLKIT_NAME v$TOOLKIT_VERSION</p></header>
EOF
  for s in "${sections[@]}"; do
    title=${s%%|*}
    read -r -a parts <<<"${s#*|}"
    fn=${parts[0]}
    declare -F "$fn" >/dev/null || continue
    # Mỗi mục chạy trong subshell: một mục lỗi không làm hỏng cả báo cáo
    out=$( ("${parts[@]}") 2>&1) || true
    printf '===== %s =====\n%s\n\n' "$title" "$out" >>"$txt"
    printf '<section><h2>%s</h2><pre>%s</pre></section>\n' "$title" "$(_html_escape <<<"$out")" >>"$html"
  done
  {
    printf '<section>%s</section>\n' "$(_metrics_svg)"
    printf '</main></body></html>\n'
  } >>"$html"
  own_like_parent "$txt" "$html"
  TOOLKIT_COLOR=1
  setup_colors
  log_ok "Đã tạo báo cáo:"
  kv "HTML (mở bằng trình duyệt)" "$html"
  kv "Văn bản" "$txt"
}

monitor_watch() {
  local interval=${1:-2} key name t idle dt di p first=1 pct mnt l1 l5 l15 ncpu cpu_lines frame
  local -A t0=() i0=()
  is_int "$interval" && ((interval >= 1)) || die "Chu kỳ phải là số nguyên ≥ 1"
  [[ -t 0 && -t 1 ]] || die "Bảng theo dõi cần terminal tương tác."
  ncpu=$(nproc)
  while read -r name t idle; do t0[$name]=$t i0[$name]=$idle; done < <(_cpu_snapshot)
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null; printf "\n"; exit 0' INT TERM
  while true; do
    # Chờ hết chu kỳ, đồng thời bắt phím q để thoát
    if ((first)); then
      sleep 0.5
      first=0
    elif read -rsn1 -t "$interval" key && [[ $key == [qQ] ]]; then
      break
    fi
    # %CPU từng lõi = phần thời gian không rảnh kể từ lần đo trước
    cpu_lines=""
    while read -r name t idle; do
      dt=$((t - t0[$name])) di=$((idle - i0[$name])) p=0
      if ((dt > 0)); then p=$((100 * (dt - di) / dt)); fi
      if [[ $name == cpu ]]; then
        cpu_lines+="  $(pad CPU 8) $(bar "$p" 40 $((CPU_THRESHOLD - 15)) "$CPU_THRESHOLD")"$'\n'
      elif ((ncpu <= 16)); then
        cpu_lines+="  $(pad " $name" 8) $(bar "$p" 40)"$'\n'
      fi
      t0[$name]=$t i0[$name]=$idle
    done < <(_cpu_snapshot)
    mem_stats
    read -r l1 l5 l15 _ </proc/loadavg
    frame=$(
      printf '%s%s — %s — %s%s\n\n' "$C_BOLD" "$TOOLKIT_NAME: theo dõi trực tiếp" "$(hostname)" "$(date '+%H:%M:%S')" "$C_RESET"
      printf '%s' "$cpu_lines"
      printf '  %s %s  %s / %s\n' "$(pad RAM 8)" "$(bar "$MEM_PCT" 40 $((MEM_THRESHOLD - 15)) "$MEM_THRESHOLD")" \
        "$(human_kb $((MEM_TOTAL - MEM_AVAIL)))" "$(human_kb "$MEM_TOTAL")"
      if ((SWAP_TOTAL > 0)); then printf '  %s %s\n' "$(pad Swap 8)" "$(bar "$SWAP_PCT" 40 50 80)"; fi
      printf '  %s %s  %s  %s\n\n' "$(pad Load 8)" "$l1" "$l5" "$l15"
      while read -r pct mnt _ _; do
        printf '  %s %s\n' "$(pad "$mnt" 20)" "$(bar "$pct" 28 $((DISK_THRESHOLD - 15)) "$DISK_THRESHOLD")"
      done < <(disk_usage | take 6)
      printf '\n'
      ps_top pid,user,pcpu,pmem,stat,comm -pcpu 8
      printf '\n%sNhấn q để thoát · làm mới mỗi %s giây%s' "$C_DIM" "$interval" "$C_RESET"
    )
    printf '\e[H\e[2J%s' "$frame" # về góc trên & xoá màn hình rồi vẽ cả khung một lần (ít nháy)
  done
  tput cnorm 2>/dev/null || true
  printf '\n'
}

monitor_history() {
  local n=${1:-20} f="$REPORT_DIR/metrics.csv"
  header "Lịch sử số liệu ($f)"
  [[ -f $f ]] || { log_warn "Chưa có số liệu — chạy '$PROG alert check' hoặc cài lịch: '$PROG scheduler install'."; return 0; }
  { head -n 1 "$f"; tail -n +2 "$f" | tail -n "$n"; } | table , || tail -n "$n" "$f"
}

# ------------------------------------------- GIÁM SÁT HOẠT ĐỘNG NHÂN VIÊN ---
# Danh sách tiến trình cho giao diện chọn — mỗi dòng: "PID<TAB>mô tả"
_pick_pid() {
  ps -eo pid=,user=,pcpu=,pmem=,comm= --sort=-pcpu | awk '$5 != "ps"' | take 40 |
    awk '{ c = $5; for (i = 6; i <= NF; i++) c = c " " $i; printf "%s\t%-10s CPU %5s%%  RAM %5s%%  %s\n", $1, $2, $3, $4, c }'
}

_need_pid() {
  is_int "$1" || die "PID không hợp lệ: '$1'"
  [[ -d /proc/$1 ]] || die "Không có tiến trình nào mang PID $1"
  if (($1 == 1 || $1 == $$ || $1 == PPID)); then die "Từ chối thao tác với PID $1 (systemd hoặc chính toolkit)."; fi
}

monitor_who() {
  header "Đang đăng nhập — ai, từ đâu, đang làm gì (w)"
  if has w; then w -i 2>/dev/null || w; else who -H; fi
  printf '  %sCột FROM = IP/máy SSH vào · IDLE = thời gian không gõ phím · WHAT = lệnh đang chạy%s\n' "$C_DIM" "$C_RESET"
  header "Số phiên theo nhân viên"
  who | awk '{ n[$1]++ } END { for (u in n) printf "  %-16s %d phiên\n", u, n[u] }' | sort
  header "10 lần đăng nhập gần nhất (last)"
  if has last; then last -i -n 10 2>/dev/null | grep -v '^$' || log_warn "Không đọc được lịch sử đăng nhập (wtmp)."
  else log_warn "Không có lệnh last."; fi
  if ((EUID == 0)) && has lastb; then
    header "Đăng nhập THẤT BẠI gần đây (lastb)"
    lastb -i -n 10 2>/dev/null | grep -v '^$' || true
  fi
}

monitor_usage() {
  local min
  min=$(awk '/^UID_MIN/ { print $2 }' /etc/login.defs 2>/dev/null)
  header "Tài nguyên đang dùng theo từng người (tổng hợp từ ps)"
  printf '  %-2s %-16s %8s %7s %7s %10s\n' "" USER PROCESS %CPU %RAM "RAM(MB)"
  # Cộng dồn %CPU, %RAM, RSS và số tiến trình theo user, sắp xếp theo %CPU giảm dần
  ps -eo user:20=,uid=,pcpu=,pmem=,rss= | awk -v min="${min:-1000}" '
    { u = $1; p[u]++; c[u] += $3; m[u] += $4; r[u] += $5; id[u] = $2 }
    END { for (u in p) printf "%.1f\t  %-2s %-16s %8d %7.1f %7.1f %10.0f\n", c[u],
            (id[u] >= min && id[u] < 65534 ? "*" : ""), u, p[u], c[u], m[u], r[u] / 1024 }' |
    sort -t$'\t' -k1,1 -rn | cut -f2- | take 20
  printf '\n  %s* = tài khoản nhân viên · %%CPU cộng dồn có thể > 100%% trên máy nhiều lõi%s\n' "$C_DIM" "$C_RESET"
  printf '  %sXem chi tiết một người: ps -u <user> -o pid,pcpu,pmem,etime,args --sort=-pcpu%s\n' "$C_DIM" "$C_RESET"
}

monitor_top() {
  local n=${1:-10} by=${2:-cpu} key
  is_int "$n" || die "Số tiến trình không hợp lệ: $n"
  case $by in cpu) key=-pcpu ;; mem | ram) key=-pmem ;; *) die "Chỉ sắp xếp theo 'cpu' hoặc 'mem'." ;; esac
  header "Top $n tiến trình theo ${by^^}"
  ps_top pid,user,ni,pcpu,pmem,rss,stat,etime,comm "$key" "$n"
  printf '\n%sNI = nice (19 = ưu tiên thấp nhất) · RSS = RAM thực (KB) · ETIME = đã chạy bao lâu ·%s\n' "$C_DIM" "$C_RESET"
  printf '%sSTAT: R chạy, S ngủ, D chờ I/O, Z zombie, T dừng%s\n' "$C_DIM" "$C_RESET"
}

monitor_hogs() {
  local cpu=${1:-$HOG_CPU} mem=${2:-$HOG_MEM} out
  is_int "$cpu" && is_int "$mem" || die "Ngưỡng phải là số nguyên"
  header "Process vượt ngưỡng CPU ≥ ${cpu}% hoặc RAM ≥ ${mem}%"
  out=$(ps -eo pid=,user=,pcpu=,pmem=,etime=,args= --sort=-pcpu |
    awk -v c="$cpu" -v m="$mem" '$6 != "ps" && ($3 >= c || $4 >= m) {
      a = $6; for (i = 7; i <= NF; i++) a = a " " $i
      printf "  %-8s %-12s %6s %6s %12s  %s\n", $1, $2, $3, $4, $5, substr(a, 1, 50) }')
  if [[ -z $out ]]; then
    status OK "Không có process nào ngốn tài nguyên vượt ngưỡng"
    return 0
  fi
  printf '  %-8s %-12s %6s %6s %12s  %s\n' PID USER %CPU %RAM ELAPSED COMMAND
  printf '%s\n' "$out"
  status WARN "$(wc -l <<<"$out") process vượt ngưỡng"
  printf '\n%sXử lý: %s monitor renice <PID> (hạ ưu tiên) · %s monitor kill <PID> · %s users kick <user>%s\n' \
    "$C_DIM" "$PROG" "$PROG" "$PROG" "$C_RESET"
}

monitor_renice() {
  local pid=$1 ni=${2:-15}
  _need_pid "$pid"
  [[ $ni =~ ^-?[0-9]+$ ]] && ((ni >= -20 && ni <= 19)) || die "Giá trị nice phải trong khoảng -20..19."
  header "Hạ ưu tiên tiến trình $pid"
  ps -o pid,user,ni,pcpu,comm -p "$pid"
  run renice -n "$ni" -p "$pid"
  [[ $DRY_RUN == 1 ]] || ps -o pid,user,ni,pcpu,comm -p "$pid"
  printf '\n%sProcess vẫn chạy nhưng nhường CPU cho người khác — mềm mỏng hơn kill.%s\n' "$C_DIM" "$C_RESET"
}

monitor_kill() {
  local pid=$1 sig=${2:-TERM}
  _need_pid "$pid"
  sig=${sig#SIG}
  sig=${sig^^}
  kill -l "$sig" >/dev/null 2>&1 || die "Tín hiệu không hợp lệ: $sig"
  header "Tiến trình sẽ nhận tín hiệu SIG$sig"
  ps -o pid,user,pcpu,pmem,etime,args -p "$pid" | cut -c1-150
  confirm "Gửi SIG$sig tới PID $pid?" || { log_warn "Đã huỷ."; return 0; }
  run kill -s "$sig" "$pid"
  syslog_event "MONITOR KILL: SIG$sig -> PID $pid"
  [[ $DRY_RUN == 1 ]] && return 0
  sleep 0.5
  if [[ -d /proc/$pid ]]; then status INFO "PID $pid vẫn tồn tại — thử lại với tín hiệu KILL nếu cần"
  else status OK "PID $pid đã kết thúc"; fi
  printf '\n%sTERM = yêu cầu dừng lịch sự (chương trình kịp lưu dữ liệu) · KILL = buộc dừng ngay%s\n' "$C_DIM" "$C_RESET"
}

# ------------------------------------------------------- KIỂM TRA LOG HỆ THỐNG ---
# _log_lines <phút> <auth|all> — dòng log trong N phút gần nhất (journald nếu có, không thì /var/log)
_log_lines() {
  local min=$1 kind=${2:-all} iso trad d
  if has journalctl && [[ -d /run/systemd/system ]]; then
    if [[ $kind == auth ]]; then
      journalctl --since "-${min}min" --no-pager -q -o short-iso SYSLOG_FACILITY=4 + SYSLOG_FACILITY=10 2>/dev/null || true
    else
      journalctl --since "-${min}min" --no-pager -q -o short-iso 2>/dev/null || true
    fi
    return 0
  fi
  local -a files=(/var/log/auth.log /var/log/secure)
  [[ $kind == auth ]] || files+=(/var/log/syslog /var/log/messages /var/log/kern.log)
  # rsyslog ghi thời gian kiểu ISO (2026-10-30T10:15:01) hoặc kiểu cũ (Oct 30 10:15:01)
  iso=$(date -d "-$min min" '+%Y-%m-%dT%H:%M:%S')
  trad=$(for ((d = min / 1440; d >= 0; d--)); do LC_ALL=C date -d "-$d day" '+%b %e'; done | paste -sd'|')
  { cat "${files[@]}" 2>/dev/null || true; } | awk -v iso="$iso" -v trad="$trad" '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { if (substr($0, 1, 19) >= iso) print; next }
    { n = split(trad, t, "|"); for (i = 1; i <= n; i++) if (substr($0, 1, 6) == t[i]) { print; next } }'
}

# _grep — grep không làm lỗi pipeline khi không có dòng khớp (an toàn với set -e)
_grep() { grep "$@" || true; }

# _top <số> — đếm & xếp hạng các dòng giống nhau (dạng "  12  giá trị")
_top() { sort | uniq -c | sort -rn | take "${1:-5}" | awk '{ c = $1; $1 = ""; printf "        %5d  %s\n", c, substr($0, 2) }'; }

monitor_logcheck() {
  local hours=${1:-$LOGCHECK_HOURS} auth all n m src
  is_int "$hours" && ((hours >= 1)) || die "Số giờ phải là số nguyên ≥ 1"
  ((EUID == 0)) || log_warn "Không phải root — có thể không đọc được log xác thực (auth.log/secure)."
  status_reset
  if has journalctl && [[ -d /run/systemd/system ]]; then src="journald"; else src="/var/log (rsyslog)"; fi
  auth=$(_log_lines $((hours * 60)) auth)
  all=$(_log_lines $((hours * 60)) all)
  header "Kiểm tra log $hours giờ qua trên $(hostname) — nguồn: $src"
  kv "Số dòng log xác thực" "$(grep -c . <<<"$auth" || true)"
  kv "Số dòng log hệ thống" "$(grep -c . <<<"$all" || true)"

  header "1. Đăng nhập SSH thất bại"
  n=$(grep -cE 'Failed [a-z/-]+ for ' <<<"$auth" || true)
  if ((n >= SSH_FAIL_THRESHOLD)); then status WARN "$n lần thất bại — top IP:"; elif ((n > 0)); then status INFO "$n lần thất bại — top IP:"; else status OK "Không có"; fi
  ((n > 0)) && { _grep -E 'Failed [a-z/-]+ for ' <<<"$auth" | _grep -oE 'from [0-9a-fA-F:.]+' | awk '{ print $2 }' | _top 5; }
  m=$({ _grep -oE 'Invalid user [^ ]+' <<<"$auth" || true; } | awk '{ print $3 }' | sort -u | grep -c . || true)
  if ((m >= IDS_SPRAY_USERS)); then status WARN "$m tên đăng nhập KHÔNG tồn tại bị thử (dò tên user):"; { _grep -oE 'Invalid user [^ ]+' <<<"$auth" | awk '{ print $3 }' | _top 5; }; fi

  header "2. Đăng nhập SSH thành công"
  n=$(grep -cE 'Accepted (password|publickey|keyboard-interactive)' <<<"$auth" || true)
  status INFO "$n phiên đăng nhập thành công"
  ((n > 0)) && { _grep -oE 'Accepted [a-z-]+ for [^ ]+ from [0-9a-fA-F:.]+' <<<"$auth" | awk '{ print $4 "@" $6 " (" $2 ")" }' | _top 8; }
  if grep -qE 'Accepted [a-z-]+ for root ' <<<"$auth"; then status WARN "Có đăng nhập trực tiếp bằng root qua SSH"; else status OK "Không có đăng nhập root qua SSH"; fi

  header "3. Quyền quản trị (sudo / su)"
  n=$(grep -cE 'sudo(\[[0-9]+\])?: .*COMMAND=' <<<"$auth" || true)
  status INFO "$n lệnh sudo đã chạy — theo người dùng:"
  ((n > 0)) && { _grep -E 'sudo(\[[0-9]+\])?: .*COMMAND=' <<<"$auth" | sed -E 's/.*sudo(\[[0-9]+\])?: +([^ ]+) :.*/\2/' | _top 5; }
  m=$(grep -cE 'sudo.*(incorrect password attempt|authentication failure)|NOT in sudoers' <<<"$auth" || true)
  if ((m > 0)); then status WARN "$m lần dùng sudo thất bại / không có quyền:"; { _grep -E 'sudo.*(incorrect password|authentication failure)|NOT in sudoers' <<<"$auth" | sed -E 's/.*sudo(\[[0-9]+\])?: +([^ ]+) :.*/\2/; s/.*ruser=([^ ]*).*/\1/' | _top 5; }
  else status OK "Không có sudo thất bại"; fi
  m=$(grep -cE 'su(\[[0-9]+\])?: .*(FAILED|authentication failure)' <<<"$auth" || true)
  ((m == 0)) && status OK "Không có su thất bại" || status WARN "$m lần su thất bại"

  header "4. Thay đổi tài khoản & mật khẩu"
  n=$(grep -cE 'useradd|userdel|groupadd|groupdel|usermod|password changed|chpasswd|new user' <<<"$auth" || true)
  if ((n > 0)); then status INFO "$n sự kiện thay đổi tài khoản:"; _grep -oE '(new user|delete user|new group|delete group|password changed for|change user)[^,]*' <<<"$auth" | _top 8
  else status OK "Không có thay đổi tài khoản"; fi

  header "5. Lỗi dịch vụ"
  n=$(grep -cE 'Failed to start|failed with result|Main process exited, code=(exited|killed)' <<<"$all" || true)
  if ((n > 0)); then status WARN "$n lỗi dịch vụ:"; _grep -oE '(Failed to start [^.]+|[A-Za-z0-9@._-]+\.service: Failed with result [^.]+)' <<<"$all" | _top 5
  else status OK "Không có dịch vụ khởi động lỗi"; fi

  header "6. Kernel: hết RAM, crash, lỗi đĩa"
  n=$(grep -ciE 'out of memory|oom-kill|oom_reaper' <<<"$all" || true)
  ((n == 0)) && status OK "Không có sự kiện OOM" || status FAIL "$n sự kiện hết bộ nhớ (OOM killer)"
  n=$(grep -ciE 'segfault|general protection' <<<"$all" || true)
  ((n == 0)) && status OK "Không có chương trình bị crash (segfault)" || status WARN "$n lần chương trình crash (segfault)"
  n=$(grep -ciE 'I/O error|EXT4-fs error|XFS .*error|blk_update_request' <<<"$all" || true)
  ((n == 0)) && status OK "Không có lỗi I/O ổ đĩa" || status FAIL "$n lỗi I/O ổ đĩa — kiểm tra phần cứng (smartctl)"

  header "7. Tường lửa chặn kết nối"
  n=$(grep -cE 'UFW BLOCK|IPTABLES.*DROP' <<<"$all" || true)
  if ((n > 0)); then status INFO "$n gói tin bị chặn — top nguồn:"; _grep -oE 'SRC=[0-9a-fA-F:.]+' <<<"$all" | cut -d= -f2 | _top 5
  else status OK "Không có (hoặc tường lửa chưa bật ghi log)"; fi

  status_summary
  printf '\n%sPhát hiện tấn công theo thời gian thực: %s alert security (cron chạy mỗi 5 phút)%s\n' "$C_DIM" "$PROG" "$C_RESET"
  return 0
}

monitor_log_upload() {
  local hours=${1:-$LOGCHECK_HOURS} dir stamp name arch f
  is_int "$hours" || die "Số giờ không hợp lệ"
  stamp=$(date +%Y%m%d-%H%M%S)
  name="logs-$(hostname -s 2>/dev/null || hostname)-$stamp"
  arch="$BACKUP_DEST/logs/$name.tar.gz"
  header "Đóng gói log $hours giờ qua → $arch"
  if [[ $DRY_RUN == 1 ]]; then
    run tar -czf "$arch" "$name/"
    cloud_upload "$arch" logs
    return 0
  fi
  tk_mktemp dir -d
  mkdir -p "$dir/$name" "$BACKUP_DEST/logs"
  chmod 700 "$BACKUP_DEST" "$BACKUP_DEST/logs" 2>/dev/null || true
  # 1) báo cáo phân tích log (không màu)
  (TOOLKIT_COLOR=0; setup_colors; monitor_logcheck "$hours") >"$dir/$name/logcheck-report.txt" 2>&1 || true
  # 2) log thô trong khoảng thời gian
  _log_lines $((hours * 60)) all >"$dir/$name/system.log" || true
  _log_lines $((hours * 60)) auth >"$dir/$name/auth.log" || true
  # 3) log của toolkit (cảnh báo, cron, số liệu)
  for f in "$LOG_DIR"/toolkit.log "$LOG_DIR"/alerts.log "$LOG_DIR"/cron.log "$REPORT_DIR"/metrics.csv; do
    [[ -f $f ]] && cp -p "$f" "$dir/$name/" 2>/dev/null
  done
  tar -czf "$arch" -C "$dir" "$name"
  chmod 600 "$arch"
  (cd "$BACKUP_DEST/logs" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
  status OK "Gói log: $(human_bytes "$(stat -c %s "$arch")") — $(tar -tzf "$arch" | grep -c '[^/]$' || true) file"
  # giữ 14 gói log gần nhất trên máy chủ
  find "$BACKUP_DEST/logs" -maxdepth 1 -name 'logs-*.tar.gz' -printf '%f\n' | sort -r | awk 'NR > 14' |
    while read -r f; do rm -f "$BACKUP_DEST/logs/$f" "$BACKUP_DEST/logs/$f.sha256"; done
  if [[ -n $GDRIVE_REMOTE ]]; then
    if cloud_upload "$arch" "$arch.sha256" logs; then
      status OK "Đã tải lên Google Drive: $(cloud_path logs)/$name.tar.gz"
      cloud_prune logs "$GDRIVE_KEEP_DAYS"
    else
      status FAIL "Không tải được gói log lên Google Drive (vẫn còn bản trên máy chủ)"
      declare -F alert_send >/dev/null && alert_send "[$(hostname)] Không tải được log lên Google Drive" "Gói $name.tar.gz vẫn nằm ở $arch. Xem $LOG_DIR/rclone.log." || true
    fi
  else
    log_info "Chưa cấu hình Google Drive — gói log chỉ lưu trên máy chủ ($(cloud_explain))."
  fi
  syslog_event "LOG UPLOAD: $arch"
  return 0
}
