#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# =============================================================================
#  lib/common.sh — Thư viện dùng chung của LinuxAdmin Toolkit
#
#  Mọi module đều dùng các hàm trong file này:
#    1. Biến toàn cục & màu sắc            5. Nhận diện distro / trình quản lý gói
#    2. Định dạng đầu ra (header, kv, bar)  6. Đọc / ghi file cấu hình
#    3. Ghi log (file + journald)           7. Registry module/action — nơi khai báo
#    4. Dry-run, xác nhận, quyền root          chức năng, dùng chung cho CLI và TUI
# =============================================================================

# ============================================================ 1. BIẾN & MÀU ===
TOOLKIT_NAME="LinuxAdmin Toolkit"
COMPANY_NAME=${COMPANY_NAME:-TechNova Solutions}
TOOLKIT_VERSION="1.0.0"
PROG=${PROG:-sysadmin.sh}

DRY_RUN=${DRY_RUN:-0}          # 1 = chỉ in ra lệnh sẽ chạy, không thay đổi hệ thống
ASSUME_YES=${ASSUME_YES:-0}    # 1 = tự động đồng ý mọi câu hỏi xác nhận
TOOLKIT_COLOR=${TOOLKIT_COLOR:-1}
CUR_MODULE="" CUR_ACTION=""    # action đang chạy (dùng khi ghi log)
TK_ERR_SHOWN=0                 # đã in thông báo lỗi cho người dùng hay chưa
TK_ERR_FLAG="${TMPDIR:-/tmp}/.sysadmin-tk-err.$$" # như trên, nhưng thấy được từ subshell $(...)
TK_TMP_FILES=()                # file tạm, tự xoá khi thoát
ST_OK=0 ST_WARN=0 ST_FAIL=0    # bộ đếm cho status()

# Bật màu khi đầu ra là terminal (tắt bằng --no-color hoặc biến NO_COLOR)
setup_colors() {
  if [[ -t 1 && -z ${NO_COLOR:-} && $TOOLKIT_COLOR == 1 ]]; then
    C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m' C_MAGENTA=$'\e[35m' C_CYAN=$'\e[36m'
  else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
    C_BLUE='' C_MAGENTA='' C_CYAN=''
  fi
}
setup_colors

# ======================================================= 2. ĐỊNH DẠNG ĐẦU RA ===
has()  { command -v "$1" >/dev/null 2>&1; }
take() { awk -v n="${1:-10}" 'NR <= n'; }   # như head -n nhưng đọc hết đầu vào → không gây SIGPIPE
# ps_top <các cột, cột cuối là comm> <khoá sắp xếp> <số dòng> — top tiến trình, bỏ qua chính lệnh ps
ps_top() { ps -eo "$1" --sort="$2" | awk -v n="$3" 'NR == 1 || ($NF != "ps" && c++ < n)'; }
trim() { local s=$*; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
is_int() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# table [ký tự phân cách] — căn thẳng cột dữ liệu dạng bảng
# (dùng "column" nếu có; bản cài tối giản không có column thì dùng awk)
table() {
  if has column; then
    if [[ -n ${1:-} ]]; then column -t -s "$1"; else column -t; fi
  else
    awk -F"${1:- }" '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n[NR] = NF }
      END { for (r = 1; r <= NR; r++) { for (i = 1; i <= n[r]; i++) printf "%-*s%s", (i < n[r] ? w[i] : 0), c[r, i], (i < n[r] ? "  " : "\n") } }'
  fi
}

# ls_names <thư mục> — tên các mục trong thư mục trên một dòng ("(trống)" nếu không có)
ls_names() {
  (
    shopt -s nullglob
    cd "$1" 2>/dev/null || { echo "(không có)"; exit 0; }
    local -a f=(*)
    if ((${#f[@]})); then echo "${f[*]}"; else echo "(trống)"; fi
  )
}

# rep <chuỗi> <số lần> — lặp lại một chuỗi
rep() { local out='' i; for ((i = 0; i < $2; i++)); do out+=$1; done; printf '%s' "$out"; }

# pad <chuỗi> <độ rộng> — căn trái theo số KÝ TỰ.
# (printf '%-10s' của bash đếm theo byte nên lệch cột với chữ tiếng Việt có dấu)
pad() { local n=$(($2 - ${#1})); ((n > 0)) || n=0; printf '%s%*s' "$1" "$n" ''; }

# header <tiêu đề> — in tiêu đề một mục
header() {
  local t=" $* " n
  n=$((66 - ${#t})); ((n > 3)) || n=3
  printf '\n%s──%s%s%s\n' "$C_BOLD$C_CYAN" "$t" "$(rep '─' "$n")" "$C_RESET"
}

# kv <nhãn> <giá trị> — in một dòng "nhãn : giá trị" thẳng cột
kv() { printf '  %s%s%s : %s\n' "$C_BOLD" "$(pad "$1" "${KV_WIDTH:-22}")" "$C_RESET" "${2:-}"; }

# status <OK|WARN|FAIL|INFO> <thông điệp> — in kết quả kiểm tra kiểu systemd
status() {
  local s=$1 c=$C_BLUE
  shift
  case $s in
    OK)   c=$C_GREEN;  ST_OK=$((ST_OK + 1)) ;;
    WARN) c=$C_YELLOW; ST_WARN=$((ST_WARN + 1)) ;;
    FAIL) c=$C_RED;    ST_FAIL=$((ST_FAIL + 1)) ;;
  esac
  printf '[%s%-4s%s] %s\n' "$c" "$s" "$C_RESET" "$*"
}
status_reset() { ST_OK=0 ST_WARN=0 ST_FAIL=0; }
status_summary() {
  printf '\n%sTổng kết:%s %s%d OK%s · %s%d cảnh báo%s · %s%d lỗi%s\n' \
    "$C_BOLD" "$C_RESET" "$C_GREEN" "$ST_OK" "$C_RESET" \
    "$C_YELLOW" "$ST_WARN" "$C_RESET" "$C_RED" "$ST_FAIL" "$C_RESET"
}

# bar <phần trăm> [độ rộng] [ngưỡng vàng] [ngưỡng đỏ] — thanh tiến độ có màu
bar() {
  local p=${1%%.*} w=${2:-30} y=${3:-70} r=${4:-90} c=$C_GREEN f
  is_int "$p" || p=0
  ((p <= 100)) || p=100
  if ((p >= r)); then c=$C_RED; elif ((p >= y)); then c=$C_YELLOW; fi
  f=$((p * w / 100))
  printf '%s[%s%s]%s %3s%%' "$c" "$(rep '#' "$f")" "$(rep '.' $((w - f)))" "$C_RESET" "$p"
}

# compare_row <tiêu chí> <bên A> <bên B> — một mục trong bảng so sánh
# (nhãn hai bên lấy từ mảng CMP_LABELS, ví dụ: CMP_LABELS=("Linux" "Windows"))
CMP_LABELS=("Linux" "Windows")
compare_row() {
  printf '\n%s• %s%s\n' "$C_BOLD" "$1" "$C_RESET"
  printf '    %s%s:%s %s\n' "$C_GREEN" "$(pad "${CMP_LABELS[0]}" 12)" "$C_RESET" "$2"
  printf '    %s%s:%s %s\n' "$C_BLUE" "$(pad "${CMP_LABELS[1]}" 12)" "$C_RESET" "$3"
}

human_bytes() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%sB' "$1"; }
human_kb()    { numfmt --from-unit=1024 --to=iec --suffix=B "$1" 2>/dev/null || printf '%sKB' "$1"; }

# Bảng chuyển chữ tiếng Việt có dấu → không dấu (dùng cho console tty thiếu font)
VN_SED='s/à/a/g;s/á/a/g;s/ả/a/g;s/ã/a/g;s/ạ/a/g;s/ă/a/g;s/ằ/a/g;s/ắ/a/g;s/ẳ/a/g;s/ẵ/a/g;s/ặ/a/g;s/â/a/g;s/ầ/a/g;s/ấ/a/g;s/ẩ/a/g;s/ẫ/a/g;s/ậ/a/g;s/è/e/g;s/é/e/g;s/ẻ/e/g;s/ẽ/e/g;s/ẹ/e/g;s/ê/e/g;s/ề/e/g;s/ế/e/g;s/ể/e/g;s/ễ/e/g;s/ệ/e/g;s/ì/i/g;s/í/i/g;s/ỉ/i/g;s/ĩ/i/g;s/ị/i/g;s/ò/o/g;s/ó/o/g;s/ỏ/o/g;s/õ/o/g;s/ọ/o/g;s/ô/o/g;s/ồ/o/g;s/ố/o/g;s/ổ/o/g;s/ỗ/o/g;s/ộ/o/g;s/ơ/o/g;s/ờ/o/g;s/ớ/o/g;s/ở/o/g;s/ỡ/o/g;s/ợ/o/g;s/ù/u/g;s/ú/u/g;s/ủ/u/g;s/ũ/u/g;s/ụ/u/g;s/ư/u/g;s/ừ/u/g;s/ứ/u/g;s/ử/u/g;s/ữ/u/g;s/ự/u/g;s/ỳ/y/g;s/ý/y/g;s/ỷ/y/g;s/ỹ/y/g;s/ỵ/y/g;s/đ/d/g;s/À/A/g;s/Á/A/g;s/Ả/A/g;s/Ã/A/g;s/Ạ/A/g;s/Ă/A/g;s/Ằ/A/g;s/Ắ/A/g;s/Ẳ/A/g;s/Ẵ/A/g;s/Ặ/A/g;s/Â/A/g;s/Ầ/A/g;s/Ấ/A/g;s/Ẩ/A/g;s/Ẫ/A/g;s/Ậ/A/g;s/È/E/g;s/É/E/g;s/Ẻ/E/g;s/Ẽ/E/g;s/Ẹ/E/g;s/Ê/E/g;s/Ề/E/g;s/Ế/E/g;s/Ể/E/g;s/Ễ/E/g;s/Ệ/E/g;s/Ì/I/g;s/Í/I/g;s/Ỉ/I/g;s/Ĩ/I/g;s/Ị/I/g;s/Ò/O/g;s/Ó/O/g;s/Ỏ/O/g;s/Õ/O/g;s/Ọ/O/g;s/Ô/O/g;s/Ồ/O/g;s/Ố/O/g;s/Ổ/O/g;s/Ỗ/O/g;s/Ộ/O/g;s/Ơ/O/g;s/Ờ/O/g;s/Ớ/O/g;s/Ở/O/g;s/Ỡ/O/g;s/Ợ/O/g;s/Ù/U/g;s/Ú/U/g;s/Ủ/U/g;s/Ũ/U/g;s/Ụ/U/g;s/Ư/U/g;s/Ừ/U/g;s/Ứ/U/g;s/Ử/U/g;s/Ữ/U/g;s/Ự/U/g;s/Ỳ/Y/g;s/Ý/Y/g;s/Ỷ/Y/g;s/Ỹ/Y/g;s/Ỵ/Y/g;s/Đ/D/g;s/─/-/g;s/│/|/g;s/→/->/g;s/←/<-/g;s/↓/v/g;s/•/*/g;s/…/.../g;s/«/<</g;s/»/>>/g;s/✓/v/g;s/×/x/g;s/–/-/g;s/—/-/g;s/≥/>=/g;s/≤/<=/g'
vn_ascii() { sed -e "$VN_SED"; }

# ================================================================ 3. GHI LOG ===
_log_write() {
  [[ -n ${LOG_FILE:-} ]] || return 0
  { printf '%(%Y-%m-%d %H:%M:%S)T [%-5s] [%s] %s\n' -1 "$1" \
      "${CUR_MODULE:-main}${CUR_ACTION:+/$CUR_ACTION}" "$2" >>"$LOG_FILE"; } 2>/dev/null || true
}
log_info()  { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; _log_write INFO "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; _log_write OK "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_write WARN "$*"; }
log_error() {
  printf '%s[LỖI]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  _log_write ERROR "$*"
  TK_ERR_SHOWN=1
  { : >"$TK_ERR_FLAG"; } 2>/dev/null || true
}
die()       { log_error "$*"; exit 1; }

# Ghi sự kiện quan trọng vào syslog/journald — xem lại: journalctl -t sysadmin-toolkit
syslog_event() { if has logger; then logger -t sysadmin-toolkit -- "$*" 2>/dev/null || true; fi; }

# ============================================ 4. DRY-RUN, XÁC NHẬN, QUYỀN ROOT ===
# shell_quote <tham số...> — in lệnh ở dạng có thể copy/paste chạy lại
shell_quote() {
  local a r="'\\''" out=()
  for a in "$@"; do
    if [[ $a =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+=("$a")
    else out+=("'${a//\'/"$r"}'"); fi
  done
  printf '%s' "${out[*]}"
}

# run <lệnh...> — thực thi lệnh; ở chế độ dry-run chỉ in ra lệnh
run() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '%s[DRY-RUN]%s %s\n' "$C_MAGENTA" "$C_RESET" "$(shell_quote "$@")"
    return 0
  fi
  _log_write CMD "$(shell_quote "$@")"
  "$@" && return 0
  local rc=$?
  log_error "Lệnh thất bại (mã $rc): $(shell_quote "$@")"
  return "$rc"
}

# run_input <dữ liệu> <lệnh...> — như run nhưng truyền dữ liệu qua stdin (không in dữ liệu ra)
run_input() {
  local data=$1
  shift
  if [[ $DRY_RUN == 1 ]]; then
    printf '%s[DRY-RUN]%s %s  %s(+ dữ liệu qua stdin)%s\n' "$C_MAGENTA" "$C_RESET" "$(shell_quote "$@")" "$C_DIM" "$C_RESET"
    return 0
  fi
  _log_write CMD "$(shell_quote "$@") <stdin>"
  printf '%s\n' "$data" | "$@"
}

# write_file <đường dẫn> [quyền] < nội dung — ghi file (dry-run: chỉ hiển thị nội dung)
write_file() {
  local path=$1 mode=${2:-644} content
  content=$(cat)
  if [[ $DRY_RUN == 1 ]]; then
    printf '%s[DRY-RUN]%s ghi file %s (quyền %s):\n' "$C_MAGENTA" "$C_RESET" "$path" "$mode"
    printf '%s\n' "$content" | sed 's/^/    │ /'
    return 0
  fi
  _log_write CMD "write_file $path ($mode)"
  (umask 077 && printf '%s\n' "$content" >"$path")
  chmod "$mode" "$path"
}

# confirm <câu hỏi> — hỏi y/N; trả về 0 nếu đồng ý
confirm() {
  [[ $ASSUME_YES == 1 || $DRY_RUN == 1 ]] && return 0
  if [[ ! -t 0 ]]; then
    log_warn "Cần xác nhận nhưng không có terminal — thêm tuỳ chọn --yes để tự động đồng ý."
    return 1
  fi
  local ans
  read -r -p "${C_YELLOW}[?]${C_RESET} $1 [y/N]: " ans || return 1
  [[ $ans =~ ^([yY]|[yY][eE][sS]|[cC]|[cC]ó)$ ]]
}

require_root() {
  ((EUID == 0)) && return 0
  if [[ $DRY_RUN == 1 ]]; then
    log_warn "Chức năng cần quyền root — đang ở chế độ dry-run nên chỉ mô phỏng."
    return 0
  fi
  die "Chức năng này cần quyền root. Chạy lại: sudo $PROG ${CUR_MODULE} ${CUR_ACTION} ..."
}

# need_cmd <lệnh> [gói] — báo lỗi kèm gợi ý cài đặt nếu thiếu lệnh
need_cmd() {
  has "$1" && return 0
  if [[ $DRY_RUN == 1 ]]; then
    log_warn "Thiếu lệnh '$1' (cài: $(pkg_hint "${2:-$1}")) — dry-run nên vẫn hiển thị các bước."
    return 0
  fi
  log_error "Thiếu lệnh '$1'. Cài đặt: $(pkg_hint "${2:-$1}")"
  return 1
}

# need_systemd — kiểm tra hệ thống đang chạy systemd (PID 1)
need_systemd() {
  if has systemctl && [[ -d /run/systemd/system ]]; then return 0; fi
  log_error "Hệ thống không chạy systemd (có thể đang trong container)."
  return 1
}

# tk_mktemp <tên biến> [-d] — tạo file/thư mục tạm, tự xoá khi chương trình kết thúc
tk_mktemp() {
  local _f
  if [[ ${2:-} == -d ]]; then _f=$(mktemp -d "${TMPDIR:-/tmp}/sysadmin-tk.XXXXXX")
  else _f=$(mktemp "${TMPDIR:-/tmp}/sysadmin-tk.XXXXXX"); fi
  TK_TMP_FILES+=("$_f")
  printf -v "$1" '%s' "$_f"
}
tk_cleanup() {
  local f
  for f in "${TK_TMP_FILES[@]}"; do rm -rf -- "$f"; done
  TK_TMP_FILES=()
  rm -f -- "$TK_ERR_FLAG"
}

# own_like_parent <file...> — file do root tạo trong thư mục của user thường
# được trả lại quyền sở hữu cho user đó (tránh file "kẹt" quyền root)
own_like_parent() {
  ((EUID == 0)) || return 0
  local p parent
  for p in "$@"; do
    [[ -e $p ]] || continue
    parent=$(dirname -- "$p")
    if [[ $(stat -c %u -- "$parent") != 0 ]]; then chown --reference="$parent" -- "$p" 2>/dev/null || true; fi
  done
  return 0
}

# resolve_secret <giá trị> <lời nhắc> — lấy mật khẩu: "@env" = từ biến TK_SECRET
# (giao diện truyền mật khẩu qua biến môi trường để không lộ trong danh sách tiến trình)
resolve_secret() {
  local v=${1:-}
  if [[ $v == "@env" ]]; then printf '%s' "${TK_SECRET:-}"; return 0; fi
  if [[ -z $v && -t 0 ]]; then read -r -s -p "$2: " v; echo >&2; fi
  printf '%s' "$v"
}

# ====================================== 5. DISTRO & TRÌNH QUẢN LÝ GÓI (apt/dnf) ===
detect_distro() {
  [[ -n ${DISTRO_FAMILY:-} ]] && return 0
  DISTRO_ID=unknown DISTRO_LIKE='' DISTRO_NAME="$(uname -s)" DISTRO_VERSION=''
  if [[ -r /etc/os-release ]]; then
    IFS=$'\x1f' read -r DISTRO_ID DISTRO_LIKE DISTRO_NAME DISTRO_VERSION < <(
      # shellcheck disable=SC1091
      . /etc/os-release
      printf '%s\x1f%s\x1f%s\x1f%s\n' "${ID:-unknown}" "${ID_LIKE:-}" "${PRETTY_NAME:-Linux}" "${VERSION_ID:-}"
    )
  fi
  case " $DISTRO_ID $DISTRO_LIKE " in
    *" debian "* | *" ubuntu "*) DISTRO_FAMILY=debian PKG_MGR=apt ;;
    *" rhel "* | *" fedora "* | *" centos "*)
      DISTRO_FAMILY=rhel
      if has dnf; then PKG_MGR=dnf; else PKG_MGR=yum; fi ;;
    *" arch "*) DISTRO_FAMILY=arch PKG_MGR=pacman ;;
    *" suse "* | *" opensuse "*) DISTRO_FAMILY=suse PKG_MGR=zypper ;;
    *) DISTRO_FAMILY=unknown PKG_MGR=unknown ;;
  esac
  # Nhóm có quyền sudo: Debian/Ubuntu dùng "sudo", họ Red Hat dùng "wheel"
  if [[ $DISTRO_FAMILY == debian ]] || getent group sudo >/dev/null 2>&1; then SUDO_GROUP=sudo; else SUDO_GROUP=wheel; fi
  return 0
}

# pkg_name <gói> — đổi tên gói "chung" sang tên thực tế của từng họ distro
pkg_name() {
  detect_distro
  case "$DISTRO_FAMILY:$1" in
    rhel:build-essential) echo "gcc make" ;;
    rhel:mailutils) echo "s-nail" ;;
    rhel:dnsutils) echo "bind-utils" ;;
    rhel:cron) echo "cronie" ;;
    rhel:openssh-client) echo "openssh-clients" ;;
    rhel:iproute2) echo "iproute" ;;
    rhel:fdisk) echo "util-linux" ;;
    *) echo "$1" ;;
  esac
}

# pkg_hint <gói> — gợi ý câu lệnh cài gói theo distro đang dùng
pkg_hint() {
  detect_distro
  local p
  p=$(pkg_name "$1")
  case $PKG_MGR in
    apt) printf 'sudo apt install %s' "$p" ;;
    dnf | yum) printf 'sudo %s install %s' "$PKG_MGR" "$p" ;;
    pacman) printf 'sudo pacman -S %s' "$p" ;;
    zypper) printf 'sudo zypper install %s' "$p" ;;
    *) printf 'cài gói "%s" bằng trình quản lý gói của distro' "$p" ;;
  esac
}

# pkg_install <gói...> — cài gói bằng apt / dnf (tự đổi tên gói theo distro)
pkg_install() {
  detect_distro
  local -a pkgs=() names=()
  local p
  for p in "$@"; do
    read -r -a names <<<"$(pkg_name "$p")"
    pkgs+=("${names[@]}")
  done
  case $PKG_MGR in
    apt) run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
    dnf | yum) run "$PKG_MGR" install -y "${pkgs[@]}" ;;
    pacman) run pacman -S --noconfirm --needed "${pkgs[@]}" ;;
    zypper) run zypper --non-interactive install "${pkgs[@]}" ;;
    *) log_error "Không xác định được trình quản lý gói."; return 1 ;;
  esac
}

# =============================================================== 6. CẤU HÌNH ===
load_config() {
  # --- Giá trị mặc định (file config/toolkit.conf sẽ ghi đè) ---
  COMPANY_NAME="TechNova Solutions"
  CPU_THRESHOLD=80 MEM_THRESHOLD=85 DISK_THRESHOLD=90
  HOG_CPU=90 HOG_MEM=30 SSH_FAIL_THRESHOLD=10
  DEPARTMENTS="dev data qa" SHARED_ROOT=/srv/technova
  MAINT_TMP_DAYS=7 MAINT_JOURNAL_KEEP=30d CRON_MAINT="30 3 * * *"
  ALERT_EMAIL="" ALERT_COOLDOWN_MIN=30 TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID=""
  BACKUP_SOURCES="/etc /home /srv/technova" BACKUP_DEST=/var/backups/sysadmin-toolkit BACKUP_KEEP=7
  BACKUP_EXCLUDES="*.tmp *.swp */.cache/*" BACKUP_REMOTE=""
  USERS_CSV="$TOOLKIT_DIR/config/users.csv" DEFAULT_SHELL=/bin/bash
  PASS_MAX_DAYS=90 PASS_MIN_DAYS=1 PASS_WARN_AGE=7
  SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  CRON_BACKUP="0 2 * * *" CRON_CHECK="*/5 * * * *" CRON_REPORT="0 7 * * 1"
  DEFAULT_MODE=ask TUI_BACKEND=auto ASCII_MODE=${ASCII_MODE:-auto}
  LOG_DIR="$TOOLKIT_DIR/logs" REPORT_DIR="$TOOLKIT_DIR/reports" STATE_DIR=""

  CONFIG_FILE=${TOOLKIT_CONF:-$TOOLKIT_DIR/config/toolkit.conf}
  if [[ -r $CONFIG_FILE ]]; then
    # shellcheck source=../config/toolkit.conf
    source "$CONFIG_FILE"
  elif [[ -n ${TOOLKIT_CONF:-} ]]; then
    die "Không đọc được file cấu hình: $CONFIG_FILE"
  fi
  CONFIG_DIR=$(dirname "$CONFIG_FILE")
  _setup_dirs
}

_dir_ok() { mkdir -p -- "$1" 2>/dev/null && [[ -w $1 ]]; }

# Chọn thư mục log/báo cáo: ưu tiên trong toolkit, nếu không ghi được thì dùng ~/.local/state
_setup_dirs() {
  local state="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/sysadmin-toolkit"
  if ! _dir_ok "$LOG_DIR" || { [[ -e $LOG_DIR/toolkit.log && ! -w $LOG_DIR/toolkit.log ]]; }; then
    LOG_DIR="$state/logs"
    _dir_ok "$LOG_DIR" || LOG_DIR=/tmp
  fi
  _dir_ok "$REPORT_DIR" || { REPORT_DIR="$state/reports"; _dir_ok "$REPORT_DIR" || REPORT_DIR=/tmp; }
  STATE_DIR=${STATE_DIR:-$LOG_DIR/state}
  _dir_ok "$STATE_DIR" || { STATE_DIR="$state/state"; _dir_ok "$STATE_DIR" || STATE_DIR=/tmp; }
  LOG_FILE="$LOG_DIR/toolkit.log"
  if [[ ! -e $LOG_FILE ]]; then
    { : >"$LOG_FILE"; } 2>/dev/null || true
    own_like_parent "$LOG_FILE" "$STATE_DIR"
  fi
  return 0
}

# config_set <KHOÁ> <giá trị> [secret] — thêm/cập nhật một dòng KHOÁ='giá trị' trong file cấu hình
# (secret: không in giá trị ra màn hình/log)
config_set() {
  local key=$1 val=$2 r="'\\''" esc line tmp shown
  [[ $key =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Khoá cấu hình không hợp lệ: $key"
  esc=${val//\'/"$r"}
  line="$key='$esc'"
  shown=$line
  [[ ${3:-} == secret ]] && shown="$key='********'"
  if [[ $DRY_RUN == 1 ]]; then
    printf '%s[DRY-RUN]%s cập nhật %s: %s\n' "$C_MAGENTA" "$C_RESET" "$CONFIG_FILE" "$shown"
    return 0
  fi
  [[ -w $CONFIG_FILE ]] || die "Không có quyền ghi $CONFIG_FILE (thử chạy bằng sudo)."
  tmp=$(mktemp)
  K="$key" L="$line" awk 'BEGIN { f = 0 }
    index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["L"]; f = 1; next }
    { print }
    END { if (!f) print ENVIRON["L"] }' "$CONFIG_FILE" >"$tmp"
  cat "$tmp" >"$CONFIG_FILE"
  rm -f "$tmp"
  printf -v "$key" '%s' "$val"
  log_ok "Đã lưu cấu hình: $shown"
}

# Chế độ khởi động mặc định (tui | cli | ask) — lưu riêng cho từng người dùng
mode_file() { printf '%s/sysadmin-toolkit/mode' "${XDG_CONFIG_HOME:-${HOME:-/root}/.config}"; }
mode_get() {
  local f m=""
  f=$(mode_file)
  [[ -r $f ]] && m=$(<"$f")
  case $m in tui | cli | ask) printf '%s' "$m" ;; *) printf '%s' "${DEFAULT_MODE:-ask}" ;; esac
}
mode_set() {
  case ${1:-} in
    tui | cli | ask) ;;
    *) die "Chế độ không hợp lệ: '${1:-}' (chọn: tui | cli | ask)" ;;
  esac
  local f
  f=$(mode_file)
  mkdir -p "$(dirname "$f")" && printf '%s\n' "$1" >"$f"
  log_ok "Từ nay '$PROG' (không tham số) sẽ mở chế độ: $1"
}

# ================================================= 7. REGISTRY MODULE / ACTION ===
# Mỗi module khai báo:
#   register_module <tên> <số thứ tự chức năng> <tiêu đề>
#   register_action <tên> <cờ> <mô tả> [tham số...]
#     cờ  : r = cần root · d = thay đổi hệ thống (hỏi xác nhận) · i = tương tác (cần terminal)
#     tham số (dạng "Lời nhắc=mặc định"):
#       "Tên"            bắt buộc nhập
#       "Tên=giá trị"    không bắt buộc, có giá trị mặc định
#       "Tên=a|b|c"      chọn một trong các giá trị (mặc định là giá trị đầu)
#       "Tên=@hàm"       chọn từ danh sách do hàm sinh ra ("@hàm?" = được bỏ trống)
#       "*Tên"           mật khẩu (nhập ẩn)
#     (lời nhắc không được chứa dấu "=" vì "=" ngăn cách lời nhắc và giá trị mặc định)
# Hàm thực thi tương ứng: <module>_<action> (dấu - đổi thành _)
declare -ga MODULES=()
declare -gA MOD_TITLE=() MOD_TOPIC=() MOD_ACTIONS=() ACT_DESC=() ACT_FLAGS=() ACT_PARAMS=()
_REG_MOD=""

register_module() {
  MODULES+=("$1")
  MOD_TOPIC[$1]=$2 MOD_TITLE[$1]=$3 MOD_ACTIONS[$1]=""
  _REG_MOD=$1
}

register_action() {
  local key="$_REG_MOD/$1"
  MOD_ACTIONS[$_REG_MOD]+="$1 "
  ACT_FLAGS[$key]=$2
  ACT_DESC[$key]=$3
  shift 3
  local IFS=$'\x1f'
  ACT_PARAMS[$key]="$*"
}

action_exists() { [[ -n ${ACT_DESC[$1/$2]+x} ]]; }
action_fn() { printf '%s_%s' "$1" "${2//-/_}"; }

# action_specs <module> <action> — đưa danh sách tham số vào mảng ACT_SPECS
action_specs() {
  ACT_SPECS=()
  if [[ -n ${ACT_PARAMS[$1/$2]:-} ]]; then IFS=$'\x1f' read -r -a ACT_SPECS <<<"${ACT_PARAMS[$1/$2]}"; fi
  return 0
}

# param_parse <đặc tả> — tách đặc tả tham số thành P_PROMPT, P_DEFAULT, P_KIND, P_REQUIRED...
param_parse() {
  local spec=$1
  P_KIND=text P_CHOICES="" P_PICKER=""
  if [[ $spec == \** ]]; then P_KIND=secret; spec=${spec#\*}; fi
  if [[ $spec == *=* ]]; then
    P_PROMPT=${spec%%=*} P_DEFAULT=${spec#*=} P_REQUIRED=0
  else
    P_PROMPT=$spec P_DEFAULT="" P_REQUIRED=1
  fi
  if [[ $P_KIND == secret ]]; then return 0; fi
  if [[ $P_DEFAULT == @* ]]; then
    P_KIND=pick P_PICKER=${P_DEFAULT#@} P_DEFAULT="" P_REQUIRED=1
    if [[ $P_PICKER == *\? ]]; then P_PICKER=${P_PICKER%\?} P_REQUIRED=0; fi
  elif [[ $P_DEFAULT == *"|"* ]]; then
    P_KIND=choice P_CHOICES=$P_DEFAULT P_DEFAULT=${P_DEFAULT%%|*}
  fi
  return 0
}

# load_modules — nạp các module theo thứ tự trên menu; module mới thả vào thư mục modules/ cũng tự được nạp
load_modules() {
  local m f
  for m in "${MODULE_ORDER[@]}"; do
    f="$TOOLKIT_DIR/modules/$m.sh"
    # shellcheck source=/dev/null
    if [[ -r $f ]]; then source "$f"; fi
  done
  for f in "$TOOLKIT_DIR"/modules/*.sh; do
    m=$(basename "$f" .sh)
    # shellcheck source=/dev/null
    if [[ -z ${MOD_TITLE[$m]+x} ]]; then source "$f"; fi
  done
  return 0
}

# topics_text — giới thiệu kịch bản doanh nghiệp & 5 chức năng chính
topics_text() {
  cat <<EOF
$TOOLKIT_NAME v$TOOLKIT_VERSION — Đề tài OSG203 #3: Bash Scripting cho System Administration

KỊCH BẢN: $COMPANY_NAME — công ty phát triển phần mềm & phân tích dữ liệu.
  • Máy chủ Ubuntu Server tập trung "technova-core-srv" tại trụ sở; Lập trình viên,
    Data Analyst, Tester cùng SSH vào làm việc, commit code, huấn luyện mô hình.
  • Anh Hưng — Tech Lead/Sysadmin — làm việc từ xa, chỉ dùng terminal qua SSH để điều hành.

  Nhu cầu của anh Hưng                           Chức năng    Lệnh tiêu biểu
  ─────────────────────────────────────────────  ───────────  ─────────────────────────
  1. Cấp quyền & quản lý nhân viên làm việc      users        users create · users offboard
  2. Ai đang làm gì, ai treo process ngốn tài    monitor      monitor who · monitor usage
     nguyên CPU/RAM                                           monitor hogs · monitor kill
  3. Nhận cảnh báo tức thời ngày lẫn đêm         alert        alert check · alert setup-mail
  4. Sao lưu an toàn tài sản số                  backup       backup run · backup restore
  5. Tự động hoá bảo dưỡng hằng ngày             scheduler    scheduler install · maintenance

Hai chế độ làm việc (chuyển qua lại bất cứ lúc nào, đều chạy tốt qua SSH):
  • Giao diện (TUI) : $PROG --tui   — menu dialog/whiptail, dùng phím mũi tên
  • Dòng lệnh (CLI) : $PROG --cli   — menu văn bản, hoặc gọi trực tiếp:
                      $PROG <chức năng> <action> [tham số...]
Giao diện chỉ là "lớp vỏ": mỗi thao tác trên menu đều chạy đúng một lệnh CLI
và hiển thị lệnh tương đương — học giao diện cũng là học dòng lệnh.
EOF
}
