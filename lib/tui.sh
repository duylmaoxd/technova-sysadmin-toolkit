#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # biến toàn cục dùng chung giữa các file
# =============================================================================
#  lib/tui.sh — CHẾ ĐỘ GIAO DIỆN (TUI) dùng dialog hoặc whiptail
#
#  Nguyên tắc thiết kế: giao diện chỉ là "lớp vỏ" của CLI.
#    Chọn chức năng → hỏi tham số bằng hộp thoại → chạy đúng lệnh CLI
#    "sysadmin.sh <module> <action> ..." trong tiến trình riêng → hiển thị kết quả
#    kèm lệnh tương đương. Nhờ vậy hai chế độ luôn cho kết quả giống hệt nhau.
# =============================================================================

UI_BIN=""          # dialog | whiptail
UI_H=20 UI_W=76    # kích thước hộp thoại (tính lại theo terminal)
ASCII_UI=0         # 1 = bỏ dấu tiếng Việt khi hiển thị

tui_backend_name() {
  if has dialog; then echo dialog; elif has whiptail; then echo whiptail; fi
  return 0
}
tui_backend_available() { has dialog || has whiptail; }

# ui_init — chọn bộ giao diện: --ui / TUI_BACKEND trong cấu hình / tự động
ui_init() {
  local want=${UI_PREF:-${TUI_BACKEND:-auto}}
  UI_BIN=""
  case $want in
    dialog | whiptail) if has "$want"; then UI_BIN=$want; fi ;;
  esac
  [[ -n $UI_BIN ]] || UI_BIN=$(tui_backend_name)
  [[ -n $UI_BIN ]] || return 1
  # Tên tuỳ chọn đặt nhãn nút khác nhau giữa dialog và whiptail
  if [[ $UI_BIN == dialog ]]; then
    L_OK=--ok-label L_CANCEL=--cancel-label L_YES=--yes-label L_NO=--no-label L_EXIT=--exit-label
  else
    L_OK=--ok-button L_CANCEL=--cancel-button L_YES=--yes-button L_NO=--no-button L_EXIT=--ok-button
  fi
  # Console tty thuần (TERM=linux) thường thiếu font tiếng Việt → tự bỏ dấu
  case ${ASCII_MODE:-auto} in
    1 | yes | on) ASCII_UI=1 ;;
    0 | no | off) ASCII_UI=0 ;;
    *) if [[ ${TERM:-} == linux ]]; then ASCII_UI=1; else ASCII_UI=0; fi ;;
  esac
  return 0
}

# Tính kích thước hộp thoại theo kích thước terminal hiện tại
_ui_dims() {
  local rows=0 cols=0 sz
  sz=$(stty size </dev/tty 2>/dev/null) || sz=""
  if [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]]; then rows=${BASH_REMATCH[1]} cols=${BASH_REMATCH[2]}; fi
  ((rows >= 12)) || rows=24
  ((cols >= 50)) || cols=80
  UI_H=$((rows - 4)) UI_W=$((cols - 6))
  ((UI_W <= 110)) || UI_W=110
  return 0
}

# Số dòng một đoạn văn bản chiếm khi hiển thị trong hộp thoại
_ui_lines() {
  local w=$((UI_W - 6)) n=0 line
  while IFS= read -r line; do n=$((n + ${#line} / w + 1)); done <<<"$1"
  printf '%s' "$n"
}

_ui_backtitle() {
  printf '%s · %s │ %s@%s │ Giao diện: %s │ Dry-run: %s' "$COMPANY_NAME" "$TOOLKIT_NAME" \
    "$(id -un)" "$(hostname -s 2>/dev/null || hostname)" "$UI_BIN" "$( ((DRY_RUN)) && printf 'BẬT' || printf 'TẮT')"
}

# _ui <tham số dialog/whiptail...> — lựa chọn của người dùng được in ra stdout
# (dialog/whiptail vẽ giao diện ra stdout và trả kết quả ra stderr → đổi chỗ 2 luồng)
_ui() {
  local -a args=("$@")
  local i bt
  bt=$(_ui_backtitle)
  if ((ASCII_UI)); then
    bt=$(vn_ascii <<<"$bt")
    for i in "${!args[@]}"; do args[i]=$(vn_ascii <<<"${args[i]}"); done
  fi
  "$UI_BIN" --backtitle "$bt" "${args[@]}" 3>&1 1>&2 2>&3
}

# ui_menu <tiêu đề> <lời nhắc> <tag> <mô tả> [<tag> <mô tả>...] → in tag được chọn
ui_menu() {
  local title=$1 text=$2 n tl lh h
  shift 2
  _ui_dims
  n=$(($# / 2))
  tl=$(_ui_lines "$text")
  lh=$((UI_H - tl - 7))
  ((lh >= 3)) || lh=3
  ((n <= lh)) || n=$lh
  h=$((n + tl + 7))
  local -a def=()
  [[ -n ${UI_DEFAULT_ITEM:-} ]] && def=(--default-item "$UI_DEFAULT_ITEM")
  _ui --title " $title " "${def[@]}" "$L_OK" "Chọn" "$L_CANCEL" "${UI_CANCEL_LABEL:-Quay lại}" \
    --menu "$text" "$h" "$UI_W" "$n" "$@"
}

ui_msg() { # ui_msg <tiêu đề> <nội dung>
  _ui_dims
  local h
  h=$(($(_ui_lines "$2") + 6))
  ((h <= UI_H)) || h=$UI_H
  _ui --title " $1 " "$L_OK" "OK" --msgbox "$2" "$h" "$UI_W"
}

ui_yesno() { # ui_yesno <tiêu đề> <câu hỏi> → 0 = Có
  _ui_dims
  local h
  h=$(($(_ui_lines "$2") + 6))
  ((h <= UI_H)) || h=$UI_H
  _ui --title " $1 " "$L_YES" "Có" "$L_NO" "Không" --yesno "$2" "$h" "$UI_W"
}

ui_input() { # ui_input <tiêu đề> <lời nhắc> [mặc định] → in giá trị nhập
  _ui_dims
  _ui --title " $1 " "$L_OK" "OK" "$L_CANCEL" "Huỷ" --inputbox "$2" 10 "$UI_W" "${3:-}"
}

ui_password() { # ui_password <tiêu đề> <lời nhắc>
  _ui_dims
  local -a extra=()
  [[ $UI_BIN == dialog ]] && extra=(--insecure)
  _ui --title " $1 " "${extra[@]}" "$L_OK" "OK" "$L_CANCEL" "Huỷ" --passwordbox "$2" 10 "$UI_W"
}

ui_info() { # ui_info <tiêu đề> <nội dung> — hộp thông báo không chờ phím
  _ui_dims
  # whiptail dùng màn hình phụ (alternate screen) nên infobox biến mất ngay trong xterm;
  # đặt TERM=linux cho riêng lệnh này để hộp thông báo còn hiển thị khi lệnh chạy
  if [[ $UI_BIN == whiptail ]]; then
    TERM=linux _ui --title " $1 " --infobox "$2" 8 "$UI_W"
  else
    _ui --title " $1 " --infobox "$2" 8 "$UI_W"
  fi
}

ui_textbox() { # ui_textbox <tiêu đề> <file> — xem file dài, cuộn bằng phím mũi tên
  _ui_dims
  local f
  tk_mktemp f
  # bỏ mã màu ANSI, đổi tab thành dấu cách để hiển thị gọn trong hộp thoại
  if ((ASCII_UI)); then
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$2" | expand | vn_ascii >"$f"
  else
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$2" | expand >"$f"
  fi
  if [[ $UI_BIN == dialog ]]; then
    _ui --title " $1 " "$L_EXIT" "Đóng" --textbox "$f" "$UI_H" "$UI_W"
  else
    # whiptail: phím mũi tên để cuộn, Tab rồi Enter (hoặc Esc) để đóng
    _ui --title " $1 — Tab/Esc để đóng " "$L_OK" "Đóng" --scrolltext --textbox "$f" "$UI_H" "$UI_W"
  fi
}

# tui_pick <tiêu đề> <lời nhắc> <hàm picker> <bắt buộc> — chọn từ danh sách động
tui_pick() {
  local -a items=()
  local v d
  (($4)) || items+=("-" "(bỏ trống — dùng mặc định)")
  while IFS=$'\t' read -r v d; do
    if [[ -n $v ]]; then items+=("$v" "${d:- }"); fi
  done < <("$3" 2>/dev/null)
  items+=("+" "Nhập giá trị khác...")
  v=$(ui_menu "$1" "$2" "${items[@]}") || return 1
  case $v in
    -) v="" ;;
    +) v=$(ui_input "$1" "$2") || return 1 ;;
  esac
  printf '%s' "$v"
}

# tui_choice <tiêu đề> <lời nhắc> <a|b|c>
tui_choice() {
  local -a items=() c
  local x first=1
  IFS='|' read -r -a c <<<"$3"
  for x in "${c[@]}"; do
    if ((first)); then items+=("$x" "(mặc định)"); first=0; else items+=("$x" " "); fi
  done
  ui_menu "$1" "$2" "${items[@]}"
}

# ------------------------------------------------------------ CHẠY 1 ACTION ---
tui_run_action() {
  local mod=$1 act=$2 key="$1/$2" spec val secret="" dry=$DRY_RUN rc c out cli_line
  local flags=${ACT_FLAGS[$key]} title="$1 $2"
  local -a args=() cmd=() disp=()

  # 1) Hỏi từng tham số bằng hộp thoại
  action_specs "$mod" "$act"
  for spec in "${ACT_SPECS[@]}"; do
    param_parse "$spec"
    case $P_KIND in
      pick) val=$(tui_pick "$title" "$P_PROMPT:" "$P_PICKER" "$P_REQUIRED") || return 0 ;;
      choice) val=$(tui_choice "$title" "$P_PROMPT:" "$P_CHOICES") || return 0 ;;
      secret) val=$(ui_password "$title" "$P_PROMPT:") || return 0; secret=$val val=@env ;;
      *)
        while true; do
          val=$(ui_input "$title" "$P_PROMPT$( ((P_REQUIRED)) && printf ' (bắt buộc)'):" "$P_DEFAULT") || return 0
          if ((P_REQUIRED)) && [[ -z $(trim "$val") ]]; then ui_msg "Thiếu thông tin" "Vui lòng nhập: $P_PROMPT"; continue; fi
          break
        done ;;
    esac
    args+=("$val")
  done
  while ((${#args[@]})) && [[ -z ${args[-1]} ]]; do unset 'args[-1]'; done

  # 2) Thao tác thay đổi hệ thống → cho chọn chạy thật / chạy thử
  if [[ $flags == *d* ]] && ((!dry)); then
    c=$(UI_CANCEL_LABEL="Huỷ" ui_menu "Xác nhận" "Thao tác sau có thể THAY ĐỔI hệ thống:

  $PROG $(shell_quote "$mod" "$act" "${args[@]}")

Bạn muốn:" run "Chạy thật" dry "Chạy thử (dry-run) — chỉ xem các lệnh sẽ chạy" cancel "Huỷ") || return 0
    case $c in
      run) ;;
      dry) dry=1 ;;
      *) return 0 ;;
    esac
  fi

  # 3) Dựng lệnh CLI tương đương
  ((dry)) && disp+=(--dry-run)
  disp+=("$mod" "$act" "${args[@]}")
  cli_line="$PROG $(shell_quote "${disp[@]}")"
  cmd=("$SELF" --yes)
  [[ -n ${TOOLKIT_CONF:-} ]] && cmd+=(--config "$TOOLKIT_CONF")
  [[ $flags == *i* ]] || cmd+=(--no-color) # đầu ra hiển thị trong hộp thoại → không cần màu
  cmd+=("${disp[@]}")

  # 4) Cần root mà đang là user thường → dùng sudo (hỏi mật khẩu ngoài giao diện nếu cần)
  if [[ $flags == *r* ]] && ((EUID != 0 && !dry)); then
    if ! has sudo; then ui_msg "Không đủ quyền" "Chức năng cần quyền root nhưng hệ thống không có sudo."; return 0; fi
    if ! sudo -n true 2>/dev/null; then
      clear
      printf 'Chức năng "%s" cần quyền root.\nNhập mật khẩu sudo (Ctrl+C để huỷ):\n\n' "$title"
      if ! sudo -v; then ui_msg "Không đủ quyền" "Không lấy được quyền sudo — đã huỷ thao tác."; return 0; fi
    fi
    if [[ -n $secret ]]; then cmd=(sudo -n --preserve-env=TK_SECRET "${cmd[@]}"); else cmd=(sudo -n "${cmd[@]}"); fi
    cli_line="sudo $cli_line"
  fi

  # 5) Chạy lệnh — Ctrl+C chỉ dừng lệnh con, không thoát giao diện
  trap : INT
  if [[ $flags == *i* ]]; then
    # chức năng tương tác: tạm rời giao diện, chạy trực tiếp trên terminal
    clear
    printf '$ %s\n\n' "$cli_line"
    TK_SECRET=$secret "${cmd[@]}"
    rc=$?
    trap _on_int INT
    printf '\n[mã thoát %s] ' "$rc"
    read -r -p "Nhấn Enter để quay lại giao diện..." _ </dev/tty || true
    return 0
  fi
  tk_mktemp out
  printf '$ %s\n\n' "$cli_line" >"$out"
  if [[ $UI_BIN == dialog ]]; then
    # dialog: hiển thị đầu ra trực tiếp trong lúc chạy (progressbox)
    local rcf
    tk_mktemp rcf
    { TK_SECRET=$secret "${cmd[@]}" </dev/null 2>&1; echo $? >"$rcf"; } | tee -a "$out" |
      dialog --backtitle "$(_ui_backtitle)" --title " Đang chạy: $title " --progressbox "$cli_line" "$UI_H" "$UI_W"
    rc=$(<"$rcf")
  else
    ui_info "Đang chạy" "$cli_line

Vui lòng chờ..."
    TK_SECRET=$secret "${cmd[@]}" </dev/null >>"$out" 2>&1
    rc=$?
  fi
  trap _on_int INT
  [[ $rc =~ ^[0-9]+$ ]] || rc=130
  if ((rc == 0)); then
    printf '\n── Hoàn tất (mã thoát 0) ──\n' >>"$out"
  else
    printf '\n── Kết thúc với mã thoát %s (có lỗi) ──\n' "$rc" >>"$out"
  fi
  ui_textbox "Kết quả: $title  [mã thoát $rc]" "$out"
}

# ---------------------------------------------------------------- CÁC MENU ---
tui_module() {
  local mod=$1 choice last="" a
  local -a acts items
  read -r -a acts <<<"${MOD_ACTIONS[$mod]}"
  while true; do
    items=()
    # Chỉ ghi chú [root] cho gọn; thao tác thay đổi hệ thống sẽ được hỏi xác nhận khi chạy
    for a in "${acts[@]}"; do
      items+=("$a" "${ACT_DESC[$mod/$a]}$([[ ${ACT_FLAGS[$mod/$a]} == *r* ]] && printf ' [root]')")
    done
    items+=(".." "« Quay lại menu chính")
    choice=$(UI_DEFAULT_ITEM=$last ui_menu "[${MOD_TOPIC[$mod]}] ${MOD_TITLE[$mod]}" \
      "Chọn chức năng (lệnh tương đương: $PROG $mod <action>):" "${items[@]}") || return 0
    [[ $choice == ".." ]] && return 0
    last=$choice
    tui_run_action "$mod" "$choice"
  done
}

tui_settings() {
  local c b m f
  while true; do
    c=$(ui_menu "Cài đặt" "Thiết lập cho phiên làm việc hiện tại:" \
      dryrun "Chế độ chạy thử (dry-run): $( ((DRY_RUN)) && printf 'BẬT' || printf 'TẮT')" \
      backend "Bộ giao diện đang dùng: $UI_BIN" \
      startup "Chế độ khi khởi động: $(mode_get)" \
      ascii "Hiển thị không dấu (cho console tty): $( ((ASCII_UI)) && printf 'BẬT' || printf 'TẮT')" \
      config "Xem file cấu hình" \
      edit "Sửa file cấu hình (\$EDITOR)" \
      log "Xem log hoạt động" \
      back "« Quay lại") || return 0
    case $c in
      dryrun) DRY_RUN=$((1 - DRY_RUN)) ;;
      ascii) ASCII_UI=$((1 - ASCII_UI)) ;;
      backend)
        local -a opts=()
        has dialog && opts+=(dialog "dialog — nhiều tính năng (hiển thị tiến trình trực tiếp)")
        has whiptail && opts+=(whiptail "whiptail — gọn nhẹ, có sẵn trên Debian/Ubuntu")
        b=$(ui_menu "Bộ giao diện" "Chọn chương trình vẽ giao diện:" "${opts[@]}") || continue
        UI_PREF=$b
        ui_init ;;
      startup)
        m=$(ui_menu "Chế độ khởi động" "Khi chạy '$PROG' không kèm tham số thì mở:" \
          ask "Hỏi mỗi lần" tui "Giao diện menu (TUI)" cli "Dòng lệnh (CLI menu)") || continue
        mode_set "$m" >/dev/null 2>&1
        ui_msg "Đã lưu" "Chế độ khởi động mặc định: $m" ;;
      config) ui_textbox "Cấu hình: $CONFIG_FILE" "$CONFIG_FILE" ;;
      edit)
        clear
        if [[ -w $CONFIG_FILE ]]; then "${EDITOR:-$(command -v nano || command -v vi)}" "$CONFIG_FILE"
        else sudoedit "$CONFIG_FILE"; fi
        switch_mode tui ;; # khởi động lại để nạp cấu hình mới
      log)
        tk_mktemp f
        tail -n 300 "$LOG_FILE" >"$f" 2>/dev/null
        ui_textbox "Log: $LOG_FILE" "$f" ;;
      back) return 0 ;;
    esac
  done
}

tui_about() {
  local f
  tk_mktemp f
  topics_text >"$f"
  ui_textbox "Giới thiệu" "$f"
}

tui_main() {
  set +e # giao diện tương tác: tự xử lý lỗi, không để "set -e" thoát chương trình đột ngột
  trap - ERR
  if ! ui_init; then
    printf '%sKhông tìm thấy dialog hoặc whiptail để vẽ giao diện.%s\n' "$C_YELLOW" "$C_RESET"
    printf 'Cài đặt: %s   (hoặc: %s)\n\n' "$(pkg_hint dialog)" "$(pkg_hint whiptail)"
    if [[ -t 0 ]] && confirm "Chuyển sang chế độ dòng lệnh (CLI)?"; then switch_mode cli; fi
    exit 1
  fi
  [[ -t 0 && -t 1 ]] || die "Giao diện cần chạy trong terminal tương tác."
  local choice last="" m
  local -a items
  while true; do
    items=()
    for m in "${MODULES[@]}"; do items+=("$m" "${MOD_TOPIC[$m]}. ${MOD_TITLE[$m]}"); done
    items+=(settings "» Cài đặt: dry-run, bộ giao diện, cấu hình, log"
      cli "» Chuyển sang chế độ DÒNG LỆNH (CLI)"
      about "» Kịch bản $COMPANY_NAME & 5 chức năng"
      quit "» Thoát")
    choice=$(UI_DEFAULT_ITEM=$last UI_CANCEL_LABEL="Thoát" ui_menu "Menu chính" \
      "$COMPANY_NAME · $(hostname -s 2>/dev/null) — chọn chức năng (↑↓ di chuyển, Enter chọn):" \
      "${items[@]}") || choice=quit
    last=$choice
    case $choice in
      settings) tui_settings ;;
      cli) switch_mode cli ;;
      about) tui_about ;;
      quit) break ;;
      *) tui_module "$choice" ;;
    esac
  done
  clear
}
