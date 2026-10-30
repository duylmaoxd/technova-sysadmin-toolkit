#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # biến toàn cục dùng chung giữa các file
# =============================================================================
#  lib/cli.sh — CHẾ ĐỘ DÒNG LỆNH (CLI)
#    cli_dispatch : chạy trực tiếp  sysadmin.sh <module> <action> [tham số...]
#    cli_help     : trang hướng dẫn (tự sinh từ registry của các module)
#    cli_menu     : menu văn bản — chọn module/chức năng bằng số
#    choose_mode  : màn hình chọn chế độ (Giao diện TUI / CLI) khi khởi động
# =============================================================================

# Banner chữ lớn (ASCII art) — chỉ dùng ký tự ASCII để hiển thị đúng ở mọi terminal
_banner() {
  printf '%s' "$C_CYAN$C_BOLD"
  cat <<'EOF'
   _     _                         _       _           _
  | |   (_)_ __  _   ___  __      / \   __| |_ __ ___ (_)_ __
  | |   | | '_ \| | | \ \/ /     / _ \ / _` | '_ ` _ \| | '_ \
  | |___| | | | | |_| |>  <     / ___ \ (_| | | | | | | | | | |
  |_____|_|_| |_|\__,_/_/\_\   /_/   \_\__,_|_| |_| |_|_|_| |_|
EOF
  printf '%s' "$C_RESET"
  printf '  %sT O O L K I T  v%s%s  —  %s · Quản trị máy chủ bằng Bash (OSG203)\n' \
    "$C_BOLD" "$TOOLKIT_VERSION" "$C_RESET" "$COMPANY_NAME"
  detect_distro
  printf '  %sMáy: %s · User: %s%s · %s · Dry-run: %s%s\n\n' "$C_DIM" "$(hostname)" "$(id -un)" \
    "$( ((EUID == 0)) && printf ' (root)')" "$DISTRO_NAME" \
    "$( ((DRY_RUN)) && printf 'BẬT' || printf 'TẮT')" "$C_RESET"
}

# ---------------------------------------------------------------- TRỢ GIÚP ---
_flag_note() {
  local f=$1 out=''
  [[ $f == *r* ]] && out+=' [root]'
  [[ $f == *d* ]] && out+=' [thay đổi hệ thống]'
  [[ $f == *i* ]] && out+=' [tương tác]'
  printf '%s' "$out"
}

cli_help() {
  if [[ -n ${1:-} ]]; then cli_help_module "$1"; return; fi
  cat <<EOF
${C_BOLD}$TOOLKIT_NAME v$TOOLKIT_VERSION${C_RESET} — bộ công cụ quản trị hệ thống Linux viết bằng Bash

${C_BOLD}CÁCH DÙNG${C_RESET}
  $PROG                          Hỏi chọn chế độ (Giao diện / CLI)
  $PROG -t | --tui               Mở giao diện menu (dialog / whiptail)
  $PROG -c | --cli               Mở menu dòng lệnh dạng văn bản
  $PROG [tuỳ chọn] <module> <action> [tham số...]
  $PROG help <module>            Xem các chức năng của một module
  $PROG mode <tui|cli|ask>       Đặt chế độ mặc định khi khởi động
  $PROG topics                   Kịch bản TechNova & 5 chức năng chính

${C_BOLD}TUỲ CHỌN${C_RESET}
  -n, --dry-run     Chỉ in ra các lệnh sẽ chạy, KHÔNG thay đổi hệ thống
  -y, --yes         Tự động đồng ý mọi câu hỏi xác nhận (dùng trong cron/script)
  -N, --no-color    Tắt màu
  -a, --ascii       Giao diện TUI không dấu (console tty thiếu font tiếng Việt)
  -f, --config F    Dùng file cấu hình F thay cho config/toolkit.conf
  -u, --ui B        Chọn bộ giao diện: dialog | whiptail
  -h, --help        Trợ giúp          -V, --version   Phiên bản

${C_BOLD}5 CHỨC NĂNG CHÍNH${C_RESET}
EOF
  local m
  for m in "${MODULES[@]}"; do
    printf '  %s%s%s %s %s\n' "$C_CYAN" "$(pad "$m" 10)" "$C_RESET" "$(pad "[${MOD_TOPIC[$m]}]" 4)" "${MOD_TITLE[$m]}"
  done
  cat <<EOF

${C_BOLD}VÍ DỤ${C_RESET}
  sudo $PROG users create              # tạo tài khoản nhân viên từ config/users.csv
  $PROG monitor who                    # ai đang đăng nhập, đang chạy gì
  $PROG monitor usage                  # CPU/RAM theo từng nhân viên
  sudo $PROG alert check               # kiểm tra & gửi cảnh báo nếu có sự cố
  sudo $PROG --dry-run backup run      # xem trước các lệnh sao lưu
  sudo $PROG scheduler install         # cài lịch tự động (backup, kiểm tra, bảo dưỡng)
EOF
}

cli_help_module() {
  local mod=$1 a spec n
  [[ -n ${MOD_TITLE[$mod]+x} ]] || die "Không có module '$mod'. Xem danh sách: $PROG help"
  printf '%s%s%s — [%s] %s\n' "$C_BOLD" "$mod" "$C_RESET" "${MOD_TOPIC[$mod]}" "${MOD_TITLE[$mod]}"
  printf '%sCú pháp: %s %s <action> [tham số theo thứ tự]%s\n' "$C_DIM" "$PROG" "$mod" "$C_RESET"
  local -a acts
  read -r -a acts <<<"${MOD_ACTIONS[$mod]}"
  for a in "${acts[@]}"; do
    printf '\n  %s%s %s%s  %s%s%s\n' "$C_CYAN$C_BOLD" "$mod" "$a" "$C_RESET" "${ACT_DESC[$mod/$a]}" \
      "$C_YELLOW" "$(_flag_note "${ACT_FLAGS[$mod/$a]}")$C_RESET"
    action_specs "$mod" "$a"
    n=1
    for spec in "${ACT_SPECS[@]}"; do
      param_parse "$spec"
      local note
      case $P_KIND in
        choice) note="chọn: ${P_CHOICES//|/ | }" ;;
        secret) note="mật khẩu — bỏ trống để nhập ẩn" ;;
        pick) if ((P_REQUIRED)); then note="bắt buộc"; else note="có thể bỏ trống"; fi ;;
        *) if ((P_REQUIRED)); then note="bắt buộc"; else note="mặc định: ${P_DEFAULT:-(trống)}"; fi ;;
      esac
      printf '      %s%d.%s %s %s(%s)%s\n' "$C_DIM" "$n" "$C_RESET" "$(pad "$P_PROMPT" 30)" "$C_DIM" "$note" "$C_RESET"
      n=$((n + 1))
    done
  done
  echo
}

# __complete — dữ liệu cho bash-completion (xem install.sh)
_complete() {
  case ${1:-} in
    modules) printf '%s\n' "${MODULES[@]}" help mode topics ;;
    actions)
      if [[ -n ${MOD_ACTIONS[${2:-}]+x} ]]; then
        local -a acts
        read -r -a acts <<<"${MOD_ACTIONS[$2]}"
        printf '%s\n' "${acts[@]}" help
      fi ;;
  esac
  return 0
}

# -------------------------------------------------------- CHẠY LỆNH TRỰC TIẾP ---
cli_dispatch() {
  local mod=$1
  shift
  case $mod in
    help | --help | -h) cli_help "${1:-}"; return 0 ;;
    list) printf '%s\n' "${MODULES[@]}"; return 0 ;;
    topics) topics_text; return 0 ;;
    mode) if (($#)); then mode_set "$1"; else printf 'Chế độ khởi động hiện tại: %s\n' "$(mode_get)"; fi; return 0 ;;
    version) printf '%s %s\n' "$TOOLKIT_NAME" "$TOOLKIT_VERSION"; return 0 ;;
    __complete) _complete "$@"; return 0 ;;
  esac
  [[ -n ${MOD_TITLE[$mod]+x} ]] || die "Không có module '$mod'. Xem danh sách: $PROG help"

  local act=help
  if (($#)); then act=$1; shift; fi
  case $act in help | -h | --help) cli_help_module "$mod"; return 0 ;; esac
  action_exists "$mod" "$act" || die "Module '$mod' không có chức năng '$act'. Xem: $PROG help $mod"

  local fn
  fn=$(action_fn "$mod" "$act")
  declare -F "$fn" >/dev/null || die "Chưa cài đặt hàm $fn()"

  # Kiểm tra đủ tham số bắt buộc
  local i=0 need=0 spec
  action_specs "$mod" "$act"
  for spec in "${ACT_SPECS[@]}"; do
    i=$((i + 1))
    param_parse "$spec"
    if ((P_REQUIRED)); then need=$i; fi
  done
  if (($# < need)); then
    log_error "Thiếu tham số cho '$mod $act' (cần ít nhất $need)."
    cli_help_module "$mod" | grep -A "$((${#ACT_SPECS[@]} + 1))" -- " $mod $act " >&2 || true
    exit 2
  fi

  # Tham số không nhập → dùng giá trị mặc định đã khai báo (giống hệt khi chạy từ giao diện)
  local -a args=("$@")
  i=0
  for spec in "${ACT_SPECS[@]}"; do
    if ((i >= ${#args[@]})); then
      param_parse "$spec"
      args+=("$P_DEFAULT")
    fi
    i=$((i + 1))
  done

  CUR_MODULE=$mod CUR_ACTION=$act
  _log_write RUN "$(shell_quote "$mod" "$act" "$@")$( ((DRY_RUN)) && printf ' (dry-run)')"
  "$fn" "${args[@]}"
  # Admin vừa thay đổi tài khoản qua toolkit → cập nhật "trạng thái chuẩn" của hệ thống phát hiện
  # tấn công, để chỉ những thay đổi KHÔNG qua toolkit mới bị cảnh báo
  if [[ $mod == users && ${ACT_FLAGS[$mod/$act]} == *d* ]] && declare -F _ids_baseline_files >/dev/null; then
    _ids_baseline_files quiet
  fi
  return 0
}

# ------------------------------------------------------------ MENU VĂN BẢN ---
_pause() { read -r -p $'\n'"Nhấn Enter để tiếp tục..." _ </dev/tty || true; }

# switch_mode <tui|cli> — khởi động lại chương trình ở chế độ còn lại (giữ nguyên tuỳ chọn)
switch_mode() {
  local -a a=("--$1")
  if ((DRY_RUN)); then a+=(--dry-run); fi
  if [[ -n ${TOOLKIT_CONF:-} ]]; then a+=(--config "$TOOLKIT_CONF"); fi
  if [[ -n ${UI_PREF:-} ]]; then a+=(--ui "$UI_PREF"); fi
  if [[ $ASCII_MODE == 1 ]]; then a+=(--ascii); fi
  tk_cleanup
  clear
  exec "$SELF" "${a[@]}"
}

cli_menu() {
  set +e # menu tương tác: tự xử lý lỗi, không để "set -e" thoát chương trình đột ngột
  trap - ERR
  [[ -t 0 ]] || die "Menu CLI cần terminal tương tác. Xem cách gọi lệnh trực tiếp: $PROG help"
  local choice i m
  while true; do
    clear
    _banner
    printf '  %sCHẾ ĐỘ DÒNG LỆNH (CLI)%s — chọn chức năng theo số hoặc tên:\n\n' "$C_BOLD" "$C_RESET"
    i=1
    for m in "${MODULES[@]}"; do
      printf '  %s%2d)%s %s %s %s\n' "$C_CYAN" "$i" "$C_RESET" "$(pad "$m" 10)" \
        "${C_DIM}[${MOD_TOPIC[$m]}]${C_RESET}" "${MOD_TITLE[$m]}"
      i=$((i + 1))
    done
    printf '\n  %s t)%s Chuyển sang GIAO DIỆN (TUI)    %s d)%s Dry-run: %s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" \
      "$( ((DRY_RUN)) && printf '%sBẬT%s' "$C_MAGENTA" "$C_RESET" || printf 'TẮT')"
    printf '  %s h)%s Trợ giúp lệnh   %s a)%s Kịch bản TechNova   %s l)%s Xem log   %s q)%s Thoát\n' \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    read -r -p $'\n'"Lựa chọn: " choice || { echo; exit 0; }
    choice=$(trim "$choice")
    case $choice in
      q | Q | 0 | exit) clear; exit 0 ;;
      t | T) switch_mode tui ;;
      d | D) DRY_RUN=$((1 - DRY_RUN)) ;;
      h | H) if has less; then cli_help | less -R; else cli_help; _pause; fi ;;
      a | A) clear; topics_text; _pause ;;
      l | L) clear; header "50 dòng log gần nhất — $LOG_FILE"; tail -n 50 "$LOG_FILE" 2>/dev/null; _pause ;;
      '') ;;
      *)
        if [[ $choice =~ ^[0-9]+$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#MODULES[@]})); then
          _cli_module_menu "${MODULES[10#$choice - 1]}"
        elif [[ -n ${MOD_TITLE[$choice]+x} ]]; then
          _cli_module_menu "$choice"
        else
          printf '%sLựa chọn không hợp lệ: %s%s\n' "$C_RED" "$choice" "$C_RESET"
          sleep 1
        fi ;;
    esac
  done
}

_cli_module_menu() {
  local mod=$1 choice i a
  local -a acts
  read -r -a acts <<<"${MOD_ACTIONS[$mod]}"
  while true; do
    clear
    printf '%s[%s] %s%s\n' "$C_BOLD" "${MOD_TOPIC[$mod]}" "${MOD_TITLE[$mod]}" "$C_RESET"
    printf '%sLệnh tương đương: %s %s <action>%s\n\n' "$C_DIM" "$PROG" "$mod" "$C_RESET"
    i=1
    for a in "${acts[@]}"; do
      printf '  %s%2d)%s %s %s%s%s%s\n' "$C_CYAN" "$i" "$C_RESET" "$(pad "$a" 15)" "${ACT_DESC[$mod/$a]}" \
        "$C_YELLOW" "$(_flag_note "${ACT_FLAGS[$mod/$a]}")" "$C_RESET"
      i=$((i + 1))
    done
    printf '\n  %s b)%s Quay lại   %s q)%s Thoát\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    read -r -p $'\n'"Chọn chức năng: " choice || return 0
    choice=$(trim "$choice")
    case $choice in
      b | B) return 0 ;;
      q | Q) clear; exit 0 ;;
      '') continue ;;
    esac
    if [[ $choice =~ ^[0-9]+$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#acts[@]})); then
      a=${acts[10#$choice - 1]}
    elif action_exists "$mod" "$choice"; then
      a=$choice
    else
      printf '%sLựa chọn không hợp lệ%s\n' "$C_RED" "$C_RESET"; sleep 1; continue
    fi
    _cli_run_action "$mod" "$a"
  done
}

# _cli_pick <hàm> <lời nhắc> <bắt buộc> — chọn một giá trị từ danh sách; kết quả trong PICKED
_cli_pick() {
  local -a vals=() descs=()
  local v d c i
  while IFS=$'\t' read -r v d; do
    [[ -n $v ]] || continue
    vals+=("$v") descs+=("$d")
  done < <("$1" 2>/dev/null)
  printf '  %s%s%s\n' "$C_BOLD" "$2" "$C_RESET"
  for i in "${!vals[@]}"; do
    printf '    %s%2d)%s %s %s%s%s\n' "$C_CYAN" "$((i + 1))" "$C_RESET" "$(pad "${vals[i]}" 22)" "$C_DIM" "${descs[i]}" "$C_RESET"
  done
  ((${#vals[@]})) || printf '    %s(danh sách trống — hãy nhập trực tiếp)%s\n' "$C_DIM" "$C_RESET"
  while true; do
    read -r -e -p "  → Nhập số thứ tự hoặc giá trị$( (($3)) || printf ' (Enter = bỏ trống)'): " c || return 1
    c=$(trim "$c")
    if [[ -z $c ]]; then
      if (($3)); then continue; fi
      PICKED=""
      return 0
    fi
    if [[ $c =~ ^[0-9]+$ ]] && ((10#$c >= 1 && 10#$c <= ${#vals[@]})); then PICKED=${vals[10#$c - 1]}; else PICKED=$c; fi
    return 0
  done
}

_cli_run_action() {
  local mod=$1 act=$2 key="$1/$2" spec val secret="" dry=$DRY_RUN rc ans
  local flags=${ACT_FLAGS[$key]}
  local -a args=() cmd=() disp=()
  clear
  printf '%s» %s %s%s — %s\n\n' "$C_BOLD" "$mod" "$act" "$C_RESET" "${ACT_DESC[$key]}"
  action_specs "$mod" "$act"
  for spec in "${ACT_SPECS[@]}"; do
    param_parse "$spec"
    case $P_KIND in
      secret)
        read -r -s -p "  $P_PROMPT: " val || return 0
        echo
        secret=$val val=@env ;;
      choice)
        read -r -e -i "$P_DEFAULT" -p "  $P_PROMPT (${P_CHOICES//|/ | }): " val || return 0 ;;
      pick)
        _cli_pick "$P_PICKER" "$P_PROMPT" "$P_REQUIRED" || return 0
        val=$PICKED ;;
      *)
        while true; do
          read -r -e -i "$P_DEFAULT" -p "  $P_PROMPT$( ((P_REQUIRED)) && printf ' (bắt buộc)'): " val || return 0
          if ((P_REQUIRED)) && [[ -z $(trim "$val") ]]; then continue; fi
          break
        done ;;
    esac
    args+=("$val")
  done
  # bỏ các tham số rỗng ở cuối để lệnh tương đương gọn hơn
  while ((${#args[@]})) && [[ -z ${args[-1]} ]]; do unset 'args[-1]'; done

  if [[ $flags == *d* ]] && ((!dry)); then
    printf '\n%sThao tác này có thể THAY ĐỔI hệ thống.%s\n' "$C_YELLOW" "$C_RESET"
    read -r -p "  Chạy thật (y) / chạy thử dry-run (d) / huỷ (N): " ans || return 0
    case $ans in
      y | Y | c | C) ;;
      d | D) dry=1 ;;
      *) printf 'Đã huỷ.\n'; _pause; return 0 ;;
    esac
  fi

  # Lệnh thực thi = đúng lệnh CLI tương đương (chạy trong tiến trình riêng)
  ((dry)) && disp+=(--dry-run)
  disp+=("$mod" "$act" "${args[@]}")
  cmd=("$SELF" --yes)
  [[ -n ${TOOLKIT_CONF:-} ]] && cmd+=(--config "$TOOLKIT_CONF")
  cmd+=("${disp[@]}")
  if [[ $flags == *r* ]] && ((EUID != 0 && !dry)); then
    if has sudo; then
      if [[ -n $secret ]]; then cmd=(sudo --preserve-env=TK_SECRET "${cmd[@]}"); else cmd=(sudo "${cmd[@]}"); fi
    else
      printf '%sChức năng cần quyền root nhưng không có sudo.%s\n' "$C_RED" "$C_RESET"
    fi
  fi

  printf '\n%s$ %s%s %s%s\n\n' "$C_DIM" "$([[ ${cmd[0]} == sudo ]] && printf 'sudo ')" "$PROG" \
    "$(shell_quote "${disp[@]}")" "$C_RESET"
  trap : INT # Ctrl+C chỉ dừng lệnh con, không thoát menu
  TK_SECRET=$secret "${cmd[@]}"
  rc=$?
  trap _on_int INT
  if ((rc == 0)); then
    printf '\n%s[ OK ] Hoàn tất (mã thoát 0)%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '\n%s[LỖI] Kết thúc với mã thoát %s%s\n' "$C_RED" "$rc" "$C_RESET"
  fi
  _pause
}

# ------------------------------------------------------- CHỌN CHẾ ĐỘ BAN ĐẦU ---
choose_mode() {
  local c note
  if tui_backend_available; then
    note="${C_GREEN}sẵn sàng — $(tui_backend_name)${C_RESET}"
  else
    note="${C_YELLOW}chưa cài dialog/whiptail${C_RESET}"
  fi
  while true; do
    clear
    _banner
    printf '  %sChọn chế độ làm việc:%s\n\n' "$C_BOLD" "$C_RESET"
    printf '   %s1)%s Giao diện menu (TUI)      %s\n' "$C_CYAN" "$C_RESET" "$note"
    printf '   %s2)%s Dòng lệnh (CLI menu)      menu văn bản, chọn bằng số\n' "$C_CYAN" "$C_RESET"
    printf '   %s3)%s Hướng dẫn gọi lệnh trực tiếp (%s <module> <action>)\n' "$C_CYAN" "$C_RESET" "$PROG"
    printf '   %s0)%s Thoát\n\n' "$C_CYAN" "$C_RESET"
    printf '  %sMẹo: "%s mode tui" hoặc "%s mode cli" để lần sau mở thẳng chế độ đó.%s\n\n' \
      "$C_DIM" "$PROG" "$PROG" "$C_RESET"
    read -r -p "  Lựa chọn [1]: " c || exit 0
    case ${c:-1} in
      1) tui_main; return ;;
      2) cli_menu; return ;;
      3) clear; cli_help; return ;;
      0 | q | Q) return ;;
    esac
  done
}
