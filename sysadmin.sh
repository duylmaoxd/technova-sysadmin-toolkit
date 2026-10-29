#!/usr/bin/env bash
# =============================================================================
#  sysadmin.sh — LinuxAdmin Toolkit
#  Bộ công cụ quản trị hệ thống Linux viết bằng Bash
#  Môn OSG203 — Đề tài 3: Bash Scripting cho System Administration
#  Kịch bản: TechNova Solutions — máy chủ Ubuntu "technova-core-srv", Tech Lead
#  quản trị từ xa hoàn toàn qua SSH với 5 chức năng chính:
#    users (nhân sự & phân quyền) · monitor (giám sát) · alert (cảnh báo)
#    backup (sao lưu) · scheduler (tự động hoá bảo dưỡng)
#
#  CÁCH DÙNG
#    sysadmin.sh                               hỏi chọn chế độ: Giao diện (TUI) / CLI
#    sysadmin.sh --tui                         mở giao diện menu (dialog / whiptail)
#    sysadmin.sh --cli                         mở menu dòng lệnh
#    sysadmin.sh <module> <action> [tham số]   chạy trực tiếp một chức năng
#    sysadmin.sh help [module]                 xem hướng dẫn
#
#  CẤU TRÚC
#    lib/common.sh   hàm dùng chung (log, màu, dry-run, cấu hình, registry)
#    lib/cli.sh      chế độ dòng lệnh      lib/tui.sh   chế độ giao diện
#    modules/*.sh    mỗi file = một chức năng chính
#    config/         cấu hình, danh sách user (CSV), danh sách server
# =============================================================================

# -e: dừng khi có lệnh lỗi     -u: báo lỗi khi dùng biến chưa khai báo
# -o pipefail: pipeline lỗi nếu bất kỳ lệnh nào trong đó lỗi
# -E: bẫy ERR có hiệu lực cả bên trong hàm
set -Eeuo pipefail

# Đủ PATH khi chạy từ cron / systemd / sudo (các lệnh quản trị nằm trong /usr/sbin)
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SELF=$(readlink -f "${BASH_SOURCE[0]}")
TOOLKIT_DIR=$(dirname "$SELF")
# Tên lệnh hiển thị trong hướng dẫn: "sysadmin" nếu đã cài vào PATH, ngược lại dùng đúng cách gọi
PROG=$(basename "$0")
if [[ $(command -v "$PROG" 2>/dev/null) != /* || $(readlink -f "$(command -v "$PROG")") != "$SELF" ]]; then
  PROG=$0
fi
# Tiến trình con (giao diện gọi lại chính toolkit) dùng chung tên lệnh với tiến trình cha
if [[ -n ${TK_PROG:-} ]]; then PROG=$TK_PROG; fi
export TK_PROG=$PROG

# shellcheck source=lib/common.sh
source "$TOOLKIT_DIR/lib/common.sh"
# shellcheck source=lib/cli.sh
source "$TOOLKIT_DIR/lib/cli.sh"
# shellcheck source=lib/tui.sh
source "$TOOLKIT_DIR/lib/tui.sh"

# Thứ tự 5 chức năng trên menu (module mới đặt vào modules/ sẽ tự được nạp sau cùng)
MODULE_ORDER=(users monitor alert backup scheduler)

# Báo vị trí lỗi bất ngờ (lỗi đã được thông báo rõ ràng thì không in thêm)
_on_error() {
  if [[ $TK_ERR_SHOWN != 1 && ! -e $TK_ERR_FLAG && $4 != '"$@"' ]]; then
    log_error "Lệnh thất bại (mã $1) tại $2:$3 → $4"
  fi
}
trap '_on_error $? "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND"' ERR
_on_int() { echo; log_warn "Đã dừng bởi người dùng (Ctrl+C)."; exit 130; }
trap 'tk_cleanup' EXIT
trap _on_int INT

main() {
  local mode="" opt OPTIND=1
  local -a pre=()

  # Bước 1: đổi tuỳ chọn dài (--tui, --dry-run...) sang tuỳ chọn ngắn để xử lý bằng getopts
  while (($#)); do
    case $1 in
      --tui | --gui | --interface) pre+=(-t) ;;
      --cli) pre+=(-c) ;;
      --dry-run) pre+=(-n) ;;
      --yes) pre+=(-y) ;;
      --no-color) pre+=(-N) ;;
      --ascii) pre+=(-a) ;;
      --help) pre+=(-h) ;;
      --version) pre+=(-V) ;;
      --config=*) pre+=(-f "${1#*=}") ;;
      --ui=*) pre+=(-u "${1#*=}") ;;
      --config | --ui)
        (($# >= 2)) || die "Tuỳ chọn $1 cần một giá trị."
        if [[ $1 == --ui ]]; then pre+=(-u "$2"); else pre+=(-f "$2"); fi
        shift ;;
      --) shift; break ;;
      --*) die "Tuỳ chọn không hợp lệ: $1 (xem: $PROG --help)" ;;
      -*[fu])
        (($# >= 2)) || die "Tuỳ chọn $1 cần một giá trị."
        pre+=("$1" "$2")
        shift ;;
      -?*) pre+=("$1") ;;
      *) break ;; # gặp tên module → phần còn lại là lệnh
    esac
    shift
  done

  # Bước 2: phân tích tuỳ chọn ngắn bằng getopts
  set -- "${pre[@]}" -- "$@"
  while getopts ":tcnyNahVf:u:" opt; do
    case $opt in
      t) mode=tui ;;
      c) mode=cli ;;
      n) DRY_RUN=1 ;;
      y) ASSUME_YES=1 ;;
      N) TOOLKIT_COLOR=0 ;;
      a) ASCII_CLI=1 ;;
      h) mode=help ;;
      V) printf '%s %s\n' "$TOOLKIT_NAME" "$TOOLKIT_VERSION"; exit 0 ;;
      f) TOOLKIT_CONF=$OPTARG ;;
      u) UI_PREF=$OPTARG ;;
      :) die "Tuỳ chọn -$OPTARG cần một giá trị." ;;
      *) die "Tuỳ chọn không hợp lệ: -$OPTARG (xem: $PROG --help)" ;;
    esac
  done
  shift $((OPTIND - 1))

  setup_colors
  load_config
  if [[ -n ${ASCII_CLI:-} ]]; then ASCII_MODE=$ASCII_CLI; fi # tuỳ chọn dòng lệnh ưu tiên hơn file cấu hình
  load_modules

  # Có tham số → chạy trực tiếp một chức năng (chế độ lệnh)
  if (($#)); then
    cli_dispatch "$@"
    return
  fi

  # Không có tham số → mở chế độ tương tác
  [[ -n $mode ]] || mode=$(mode_get)
  if [[ $mode != help ]] && [[ ! -t 0 || ! -t 1 ]]; then mode=help; fi
  case $mode in
    tui) tui_main ;;
    cli) cli_menu ;;
    help) cli_help ;;
    *) choose_mode ;;
  esac
}

main "$@"
