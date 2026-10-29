#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # biến toàn cục dùng chung giữa các file
# =============================================================================
#  modules/users.sh — CHỨC NĂNG 1: QUẢN LÝ NHÂN VIÊN & PHÂN QUYỀN
#  Nhu cầu của Tech Lead: cấp tài khoản cho nhân viên mới theo phòng ban
#  (dev / data / qa), thư mục dự án dùng chung đúng quyền, cấp/thu hồi sudo,
#  chính sách mật khẩu, khoá & thu hồi quyền khi nhân viên nghỉ việc (offboard),
#  kiểm tra bảo mật tài khoản định kỳ (audit).
#  Kiến thức: /etc/passwd, /etc/shadow, useradd/usermod/chage, chmod/chown,
#             SGID, sticky bit, sudo/wheel, PAM pwquality.
# =============================================================================

register_module users 1 "Quản lý nhân viên & phân quyền"
register_action list       ""   "Danh sách nhân viên, phòng ban (nhóm) và người có quyền sudo"
register_action create     "rd" "Tạo tài khoản nhân viên mới hàng loạt từ file CSV" "File CSV=$USERS_CSV"
register_action delete     "rd" "Xoá user hàng loạt theo file CSV" "File CSV=$USERS_CSV"
register_action add        "rd" "Tạo một user" "Tên đăng nhập" "Họ tên=" "Nhóm phụ (cách nhau dấu phẩy)=" "Cấp quyền sudo=no|yes"
register_action remove     "rd" "Xoá một user (kèm thư mục home)" "User=@_pick_user"
register_action lock       "rd" "Khoá tài khoản (không cho đăng nhập)" "User=@_pick_user"
register_action unlock     "rd" "Mở khoá tài khoản" "User=@_pick_user"
register_action passwd     "rd" "Đặt lại mật khẩu ngẫu nhiên, bắt đổi ở lần đăng nhập tới" "User=@_pick_user"
register_action sudo       "rd" "Cấp / thu hồi quyền sudo" "User=@_pick_user" "Thao tác=grant|revoke"
register_action policy     ""   "Xem chính sách mật khẩu (login.defs, pwquality, chage)" "User=@_pick_user?"
register_action set-policy "rd" "Áp dụng chính sách hết hạn mật khẩu (chage + login.defs)" "User hoặc 'all'=all" "Số ngày tối đa=$PASS_MAX_DAYS" "Số ngày tối thiểu=$PASS_MIN_DAYS" "Cảnh báo trước (ngày)=$PASS_WARN_AGE"
register_action audit      "r"  "Kiểm tra bảo mật: UID 0, mật khẩu rỗng, quyền file, sudoers, SUID, SSH"
register_action perm       ""   "Giải thích quyền của file/thư mục (rwx, số octal, SUID/SGID/sticky)" "Đường dẫn=/etc/shadow"
register_action shared-dir "rd" "Tạo thư mục dùng chung cho một nhóm (chown + chmod 2770)" "Thư mục=$SHARED_ROOT/dev" "Nhóm=dev" "Quyền (octal)=2770"
register_action setup-dirs "rd" "Tạo cây thư mục dự án theo phòng ban ($SHARED_ROOT/{${DEPARTMENTS// /,}}, chung)"
register_action kick       "rd" "Ngắt mọi phiên SSH & tiến trình của một nhân viên" "User=@_pick_user"
register_action offboard   "rd" "Nhân viên nghỉ việc: khoá TK, ngắt phiên, thu hồi sudo, lưu trữ home" "User=@_pick_user"
register_action demo       "rd" "Demo TechNova: tạo nhân viên + thư mục phòng ban + tự thử quyền truy cập"
register_action demo-clean "rd" "Dọn dẹp toàn bộ dữ liệu demo (nhân viên, nhóm, thư mục)"


_uid_min() { awk '/^UID_MIN/ { print $2 }' /etc/login.defs 2>/dev/null | grep . || echo 1000; }

# User "người thật": UID_MIN ≤ UID < 65534 (nobody)
_human_users() { getent passwd | awk -F: -v min="$(_uid_min)" '$3 >= min && $3 < 65534 { print $1 }'; }

_pick_user() {
  getent passwd | awk -F: -v min="$(_uid_min)" '$3 >= min && $3 < 65534 { printf "%s\tUID %s  %s\n", $1, $3, $5 }'
}

# Mật khẩu ngẫu nhiên 12 ký tự (đọc lượng byte hữu hạn từ /dev/urandom → không gây SIGPIPE)
gen_password() {
  local p=''
  while ((${#p} < 12)); do p+=$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9@#%+=_'); done
  printf '%s' "${p:0:12}"
}

_valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

# Tạo nhóm nếu chưa có, ghi nhớ nhóm do toolkit tạo để demo-clean xoá đúng
_ensure_group() {
  getent group "$1" >/dev/null && return 0
  run groupadd "$1"
  [[ $DRY_RUN == 1 ]] || printf '%s\n' "$1" >>"$STATE_DIR/created-groups"
  status OK "Tạo nhóm $1"
}

# _create_user <user> <họ tên> <nhóm phụ a,b> <shell> <sudo yes/no> → in mật khẩu tạm ra stdout
_create_user() {
  local user=$1 full=$2 groups=$3 shell=${4:-$DEFAULT_SHELL} sudo=${5:-no} g pass
  local -a opts=(-m -s "$shell")
  [[ -n $full ]] && opts+=(-c "$full")
  groups=${groups//;/,}
  groups=${groups// /}
  for g in ${groups//,/ }; do _ensure_group "$g" >&2; done
  if [[ $sudo == yes ]]; then groups+="${groups:+,}$SUDO_GROUP"; fi
  [[ -n $groups ]] && opts+=(-G "$groups")
  pass=$(gen_password)
  # Hàm này chạy trong $(...) nên "set -e" không có hiệu lực → kiểm tra lỗi từng bước
  run useradd "${opts[@]}" "$user" >&2 || return 1
  run_input "$user:$pass" chpasswd >&2 || return 1
  # Bắt đổi mật khẩu ở lần đăng nhập đầu + áp chính sách hết hạn
  run chage -d 0 -M "$PASS_MAX_DAYS" -m "$PASS_MIN_DAYS" -W "$PASS_WARN_AGE" "$user" >&2 || return 1
  printf '%s' "$pass"
}

users_list() {
  local min
  min=$(_uid_min)
  header "User thường (UID ≥ $min) — từ /etc/passwd"
  {
    printf 'USER\tUID\tSHELL\tHOME\tNHÓM\n'
    getent passwd | awk -F: -v min="$min" '$3 >= min && $3 < 65534' |
      while IFS=: read -r u _ uid _ _ home shell; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$u" "$uid" "$shell" "$home" "$(id -nG "$u" 2>/dev/null | tr ' ' ',')"
      done
  } | table $'\t'
  detect_distro
  header "Thành viên nhóm quản trị ($SUDO_GROUP)"
  local members
  members=$(getent group "$SUDO_GROUP" | cut -d: -f4) || true
  printf '  %s\n' "${members:-(không có)}"
  header "Nhóm có thành viên (GID ≥ $min)"
  getent group | awk -F: -v min="$min" '$3 >= min && $3 < 65534 && $4 != "" { printf "  %-16s %s\n", $1, $4 }'
  if ((EUID == 0)) && has passwd; then
    header "Trạng thái mật khẩu (passwd -S)"
    local u
    for u in $(_human_users); do passwd -S "$u" 2>/dev/null | awk '{ s["P"]="có mật khẩu"; s["PS"]="có mật khẩu"; s["L"]="ĐÃ KHOÁ"; s["LK"]="ĐÃ KHOÁ"; s["NP"]="KHÔNG MẬT KHẨU"; d = ($3 == "1970-01-01" ? "chưa đổi — bắt buộc đổi ở lần đăng nhập tới" : "đổi lần cuối " $3); printf "  %-16s %s (%s)\n", $1, s[$2], d }'; done
  fi
}

users_create() {
  local csv=${1:-$USERS_CSV} line user full groups shell sudo pass cred n_ok=0 n_skip=0 n_err=0
  require_root
  [[ -r $csv ]] || die "Không đọc được file CSV: $csv"
  detect_distro
  cred="$REPORT_DIR/users-created-$(date +%Y%m%d-%H%M%S).csv"
  if [[ $DRY_RUN != 1 ]]; then
    (umask 077 && printf 'username,temp_password\n' >"$cred")
  fi
  header "Tạo user hàng loạt từ $csv"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'} # file soạn trên Windows có ký tự \r cuối dòng
    [[ -z $(trim "$line") || $line == \#* ]] && continue
    IFS=, read -r user full groups shell sudo <<<"$line"
    user=$(trim "$user") sudo=$(trim "${sudo:-no}") shell=$(trim "$shell")
    if ! _valid_username "$user"; then status FAIL "Tên không hợp lệ: '$user'"; n_err=$((n_err + 1)); continue; fi
    if id "$user" >/dev/null 2>&1; then status WARN "Bỏ qua $user: đã tồn tại"; n_skip=$((n_skip + 1)); continue; fi
    if pass=$(_create_user "$user" "$(trim "$full")" "$(trim "$groups")" "$shell" "$sudo"); then
      [[ $DRY_RUN == 1 ]] || printf '%s,%s\n' "$user" "$pass" >>"$cred"
      status OK "Tạo $user ($(trim "$full")) — nhóm: ${groups:+${groups//;/, }}${groups:-không}$([[ $sudo == yes ]] && printf ' + %s' "$SUDO_GROUP")"
      n_ok=$((n_ok + 1))
    else
      status FAIL "Không tạo được $user"
      n_err=$((n_err + 1))
    fi
  done <"$csv"
  header "Kết quả"
  kv "Tạo mới" "$n_ok"
  kv "Bỏ qua (đã có)" "$n_skip"
  kv "Lỗi" "$n_err"
  if [[ $DRY_RUN != 1 ]] && ((n_ok > 0)); then
    own_like_parent "$cred"
    kv "Mật khẩu tạm" "$cred (quyền 600)"
    printf '\n%sGửi mật khẩu tạm cho từng người; họ BẮT BUỘC đổi mật khẩu ở lần đăng nhập đầu (chage -d 0).%s\n' "$C_DIM" "$C_RESET"
  fi
  syslog_event "USERS CREATE: $n_ok tạo mới, $n_skip bỏ qua, $n_err lỗi (từ $csv)"
  if ((n_err > 0)); then log_error "Có $n_err dòng bị lỗi."; return 1; fi
  return 0
}

# _safe_to_delete <user> — chỉ cho xoá user thường, không phải root / tài khoản hệ thống
_safe_to_delete() {
  local uid
  uid=$(id -u "$1" 2>/dev/null) || return 1
  ((uid >= $(_uid_min) && uid < 65534))
}

_delete_user() {
  local user=$1
  _safe_to_delete "$user" || { status FAIL "Từ chối xoá $user (tài khoản hệ thống)"; return 1; }
  run pkill -KILL -u "$user" 2>/dev/null || true
  if run userdel -r "$user" 2>/dev/null; then status OK "Đã xoá $user"; else status WARN "userdel $user báo lỗi (có thể thiếu mail spool)"; fi
}

users_delete() {
  local csv=${1:-$USERS_CSV} line user
  local -a list=()
  require_root
  [[ -r $csv ]] || die "Không đọc được file CSV: $csv"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $(trim "$line") || $line == \#* ]] && continue
    user=$(trim "${line%%,*}")
    id "$user" >/dev/null 2>&1 && list+=("$user")
  done <"$csv"
  ((${#list[@]})) || { log_info "Không có user nào trong file đang tồn tại trên hệ thống."; return 0; }
  header "Sẽ xoá ${#list[@]} user: ${list[*]}"
  confirm "Xoá các user trên cùng thư mục home của họ?" || { log_warn "Đã huỷ."; return 0; }
  for user in "${list[@]}"; do _delete_user "$user" || true; done
  syslog_event "USERS DELETE: ${list[*]}"
}

users_add() {
  local user=$1 full=${2:-} groups=${3:-} sudo=${4:-no} pass
  require_root
  _valid_username "$user" || die "Tên đăng nhập không hợp lệ: '$user' (chữ thường, số, _ hoặc -)"
  id "$user" >/dev/null 2>&1 && die "User $user đã tồn tại."
  detect_distro
  pass=$(_create_user "$user" "$full" "$groups" "$DEFAULT_SHELL" "$sudo")
  [[ $DRY_RUN == 1 ]] && return 0
  log_ok "Đã tạo $user"
  id "$user"
  kv "Mật khẩu tạm" "$pass  (bắt buộc đổi khi đăng nhập lần đầu)"
}

users_remove() {
  local user=$1
  require_root
  id "$user" >/dev/null 2>&1 || die "Không có user $user"
  confirm "Xoá user $user và thư mục home của họ?" || { log_warn "Đã huỷ."; return 0; }
  _delete_user "$user"
}

users_lock() {
  require_root
  id "$1" >/dev/null 2>&1 || die "Không có user $1"
  _safe_to_delete "$1" || die "Từ chối khoá tài khoản hệ thống $1"
  run usermod -L -e 1 "$1" # khoá mật khẩu + đặt ngày hết hạn tài khoản (chặn cả đăng nhập bằng SSH key)
  [[ $DRY_RUN == 1 ]] || passwd -S "$1"
  log_ok "Đã khoá $1"
}

users_unlock() {
  require_root
  id "$1" >/dev/null 2>&1 || die "Không có user $1"
  run usermod -U -e '' "$1"
  [[ $DRY_RUN == 1 ]] || passwd -S "$1"
  log_ok "Đã mở khoá $1"
}

users_passwd() {
  local user=$1 pass
  require_root
  id "$user" >/dev/null 2>&1 || die "Không có user $user"
  _safe_to_delete "$user" || die "Từ chối đổi mật khẩu tài khoản hệ thống $user"
  pass=$(gen_password)
  run_input "$user:$pass" chpasswd
  run chage -d 0 "$user"
  [[ $DRY_RUN == 1 ]] && return 0
  kv "Mật khẩu tạm mới" "$pass"
  log_ok "User $user phải đổi mật khẩu ở lần đăng nhập tới."
}

users_sudo() {
  local user=$1 op=${2:-grant}
  require_root
  detect_distro
  id "$user" >/dev/null 2>&1 || die "Không có user $user"
  case $op in
    grant) run usermod -aG "$SUDO_GROUP" "$user" ;;
    revoke) run gpasswd -d "$user" "$SUDO_GROUP" ;;
    *) die "Thao tác phải là grant hoặc revoke" ;;
  esac
  [[ $DRY_RUN == 1 ]] || id "$user"
  printf '\n%sQuyền sudo của nhóm %s được khai báo trong /etc/sudoers (dòng %%%s ALL=(ALL:ALL) ALL).\n' "$C_DIM" "$SUDO_GROUP" "$SUDO_GROUP"
  printf 'Luôn sửa sudoers bằng "visudo" để được kiểm tra cú pháp. Kiểm tra: sudo -l -U %s%s\n' "$user" "$C_RESET"
}

users_policy() {
  local user=${1:-}
  header "Mặc định cho user mới — /etc/login.defs"
  grep -E '^(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|PASS_MIN_LEN|ENCRYPT_METHOD|UID_MIN|UMASK)' /etc/login.defs 2>/dev/null | sed 's/^/  /' || true
  header "Độ phức tạp mật khẩu — pam_pwquality"
  if [[ -r /etc/security/pwquality.conf ]]; then
    local conf
    conf=$(grep -Ehv '^[[:space:]]*(#|$)' /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null || true)
    if [[ -n $conf ]]; then sed 's/^/  /' <<<"$conf"; else printf '  (chưa cấu hình — mặc định minlen = 8)\n'; fi
  else
    printf '  Chưa cài pwquality (%s)\n' "$(pkg_hint libpam-pwquality)"
  fi
  if grep -qs pam_pwquality /etc/pam.d/common-password /etc/pam.d/system-auth; then status OK "pam_pwquality đang được dùng trong PAM"
  else status WARN "PAM chưa bật pam_pwquality"; fi
  header "Chính sách hết hạn của user (chage -l)"
  if [[ -n $user ]]; then
    chage -l "$user" 2>&1 | sed 's/^/  /'
  elif ((EUID == 0)); then
    printf '  %s %s %s %s %s\n' "$(pad USER 16)" "$(pad 'ĐỔI LẦN CUỐI' 14)" "$(pad 'TỐI ĐA' 8)" "$(pad 'TỐI THIỂU' 10)" "CẢNH BÁO"
    local u last max minimum warn
    for u in $(_human_users); do
      IFS=: read -r _ _ last minimum max warn _ < <(getent shadow "$u")
      if [[ $last == 0 ]]; then last="phải đổi"
      elif [[ -n $last ]]; then last=$(date -d "@$((last * 86400))" +%F); fi
      printf '  %s %s %s %s %s\n' "$(pad "$u" 16)" "$(pad "${last:--}" 14)" "$(pad "${max:--}" 8)" "$(pad "${minimum:--}" 10)" "${warn:--}"
    done
  else
    chage -l "$(id -un)" 2>&1 | sed 's/^/  /'
    log_warn "Xem của mọi user cần quyền root."
  fi
}

users_set_policy() {
  local target=${1:-all} max=${2:-$PASS_MAX_DAYS} min=${3:-$PASS_MIN_DAYS} warn=${4:-$PASS_WARN_AGE} u k v
  local -a list
  require_root
  for v in "$max" "$min" "$warn"; do is_int "$v" || die "Giá trị phải là số nguyên: $v"; done
  if [[ $target == all ]]; then mapfile -t list < <(_human_users); else list=("$target"); fi
  header "Áp dụng: đổi mật khẩu tối đa $max ngày, tối thiểu $min ngày, cảnh báo trước $warn ngày"
  for u in "${list[@]}"; do
    id "$u" >/dev/null 2>&1 || { status FAIL "Không có user $u"; continue; }
    if run chage -M "$max" -m "$min" -W "$warn" "$u"; then status OK "$u"; else status FAIL "$u"; fi
  done
  if [[ $target == all ]]; then
    header "Cập nhật mặc định cho user tạo sau này (/etc/login.defs)"
    [[ $DRY_RUN == 1 ]] || cp -p /etc/login.defs /etc/login.defs.bak-toolkit
    for k in PASS_MAX_DAYS:$max PASS_MIN_DAYS:$min PASS_WARN_AGE:$warn; do
      if grep -q "^${k%%:*}[[:space:]]" /etc/login.defs; then
        run sed -i -E "s/^${k%%:*}[[:space:]].*/${k%%:*}\t${k#*:}/" /etc/login.defs
      else
        run sed -i -e "\$a ${k%%:*}\t${k#*:}" /etc/login.defs
      fi
    done
    [[ $DRY_RUN == 1 ]] || grep -E '^PASS_(MAX|MIN|WARN)' /etc/login.defs | sed 's/^/  /'
    log_info "Bản sao lưu: /etc/login.defs.bak-toolkit"
  fi
}

# _perm_max <file> <octal tối đa> — quyền thực tế không được "rộng" hơn mức cho phép
_perm_max() {
  local p
  p=$(stat -c %a "$1" 2>/dev/null) || return 2
  (((8#$p & ~8#$2) == 0))
}

users_audit() {
  local min out n
  min=$(_uid_min)
  status_reset
  ((EUID == 0)) || log_warn "Không phải root: bỏ qua các kiểm tra cần đọc /etc/shadow và cấu hình sshd."

  header "1. Tài khoản có UID 0 (toàn quyền như root)"
  out=$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/passwd)
  if [[ -z $out ]]; then status OK "Chỉ có root mang UID 0"; else status FAIL "Tài khoản UID 0 lạ: $out"; fi

  header "2. Mật khẩu"
  if [[ -r /etc/shadow ]]; then
    out=$(awk -F: '$2 == "" { print $1 }' /etc/shadow)
    if [[ -z $out ]]; then status OK "Không có tài khoản mật khẩu rỗng"; else status FAIL "Tài khoản KHÔNG có mật khẩu: $out"; fi
    out=$(awk -F: -v list="$(_human_users | xargs)" 'BEGIN { split(list, a, " "); for (i in a) h[a[i]] = 1 }
      ($1 in h) && ($5 == "" || $5 >= 99999) { print $1 }' /etc/shadow | xargs)
    if [[ -z $out ]]; then status OK "Mọi user thường đều có hạn đổi mật khẩu"; else status WARN "Mật khẩu không bao giờ hết hạn: $out"; fi
  else
    status INFO "Bỏ qua (cần root để đọc /etc/shadow)"
  fi
  n=$(awk '/^PASS_MAX_DAYS/ { print $2 }' /etc/login.defs 2>/dev/null)
  if [[ -n $n ]] && ((n <= 180)); then status OK "PASS_MAX_DAYS = $n"; else status WARN "PASS_MAX_DAYS = ${n:-?} (nên ≤ 90–180 ngày)"; fi

  header "3. Quyền của các file nhạy cảm"
  local spec file maxp
  for spec in /etc/passwd:644 /etc/group:644 /etc/shadow:640 /etc/gshadow:640 /etc/sudoers:440 /etc/ssh/sshd_config:644; do
    file=${spec%:*} maxp=${spec#*:}
    [[ -e $file ]] || continue
    if _perm_max "$file" "$maxp"; then status OK "$(stat -c '%A %U:%G' "$file")  $file"
    else status FAIL "$(stat -c '%A %U:%G' "$file")  $file (nên ≤ $maxp)"; fi
  done

  header "4. Quyền sudo"
  detect_distro
  out=$(getent group "$SUDO_GROUP" | cut -d: -f4)
  status INFO "Thành viên nhóm $SUDO_GROUP: ${out:-(không có)}"
  if ((EUID == 0)); then
    out=$(grep -rhs 'NOPASSWD' /etc/sudoers /etc/sudoers.d/ | grep -v '^[[:space:]]*#' || true)
    if [[ -z $out ]]; then status OK "Không có quy tắc sudo NOPASSWD"; else status WARN "Có quy tắc NOPASSWD: $(head -n 1 <<<"$out")"; fi
  fi

  header "5. Tài khoản đăng nhập được (có shell)"
  out=$(awk -F: -v min="$min" '$3 >= min && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1 }' /etc/passwd | xargs)
  status INFO "User thường có shell: ${out:-(không có)}"
  out=$(awk -F: -v min="$min" '$3 < min && $3 != 0 && $7 !~ /(nologin|false|sync|halt|shutdown)$/ { print $1 "(" $7 ")" }' /etc/passwd | xargs)
  if [[ -z $out ]]; then status OK "Tài khoản hệ thống không có shell đăng nhập"; else status WARN "Tài khoản hệ thống có shell: $out"; fi

  header "6. UID / tên trùng lặp"
  out=$(cut -d: -f3 /etc/passwd | sort | uniq -d | xargs)
  if [[ -z $out ]]; then status OK "Không có UID trùng"; else status FAIL "UID trùng: $out"; fi
  out=$(cut -d: -f1 /etc/passwd | sort | uniq -d | xargs)
  if [[ -z $out ]]; then status OK "Không có tên user trùng"; else status FAIL "Tên trùng: $out"; fi

  header "7. Thư mục home"
  local u home
  while IFS=: read -r u _ _ _ _ home _; do
    [[ -d $home ]] || { status WARN "$u: thư mục home $home không tồn tại"; continue; }
    if _perm_max "$home" 750; then status OK "$(stat -c '%A' "$home") $home"
    elif ! _perm_max "$home" 775; then status FAIL "$(stat -c '%A' "$home") $home — AI CŨNG GHI được (nên chmod 750)"
    else status WARN "$(stat -c '%A' "$home") $home — user khác xem được (nên chmod 750)"; fi
  done < <(getent passwd | awk -F: -v min="$min" '$3 >= min && $3 < 65534')

  header "8. File/thư mục ai cũng ghi được trong /etc"
  out=$({ find /etc -xdev \( -type f -o -type d \) -perm -0002 2>/dev/null || true; } | take 5 | xargs)
  if [[ -z $out ]]; then status OK "Không có"; else status FAIL "World-writable: $out"; fi

  header "9. Chương trình SUID/SGID (chạy với quyền của chủ sở hữu)"
  n=$({ find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null || true; } | wc -l)
  status INFO "$n file SUID/SGID — kiểm tra file lạ trong danh sách:"
  { find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin -xdev -type f -perm -4000 2>/dev/null || true; } | take 12 | sed 's/^/        /'

  header "10. Cấu hình SSH server"
  if has sshd && ((EUID == 0)); then
    local conf v
    conf=$(sshd -T 2>/dev/null || true)
    v=$(awk '$1 == "permitrootlogin" { print $2 }' <<<"$conf")
    case $v in
      no | prohibit-password | without-password) status OK "PermitRootLogin $v" ;;
      "") status INFO "Không đọc được cấu hình sshd" ;;
      *) status WARN "PermitRootLogin $v — nên đặt 'no'" ;;
    esac
    v=$(awk '$1 == "passwordauthentication" { print $2 }' <<<"$conf")
    if [[ $v == yes ]]; then status WARN "PasswordAuthentication yes — nên chỉ cho đăng nhập bằng SSH key"
    elif [[ -n $v ]]; then status OK "PasswordAuthentication $v"; fi
    v=$(awk '$1 == "permitemptypasswords" { print $2 }' <<<"$conf")
    if [[ $v == yes ]]; then status FAIL "PermitEmptyPasswords yes"; fi
  else
    status INFO "Bỏ qua (chưa cài openssh-server hoặc không phải root)"
  fi
  status_summary
  syslog_event "USERS AUDIT: $ST_OK OK, $ST_WARN WARN, $ST_FAIL FAIL"
}

# Đổi 1 chữ số octal (0-7) thành "rwx"
_rwx() {
  local d=$1 s=''
  if ((d & 4)); then s+=r; else s+=-; fi
  if ((d & 2)); then s+=w; else s+=-; fi
  if ((d & 1)); then s+=x; else s+=-; fi
  printf '%s' "$s"
}

_rwx_text() {
  local d=$1 isdir=$2 out=()
  if ((isdir)); then
    ((d & 4)) && out+=("liệt kê nội dung")
    ((d & 2)) && out+=("tạo/xoá file bên trong")
    ((d & 1)) && out+=("đi vào (cd)")
  else
    ((d & 4)) && out+=("đọc")
    ((d & 2)) && out+=("ghi")
    ((d & 1)) && out+=("thực thi")
  fi
  ((${#out[@]})) || out=("không có quyền")
  local s
  s=$(IFS=,; printf '%s' "${out[*]}")
  printf '%s' "${s//,/, }"
}

# Dạng gọn của _rwx dùng trong chmod u=..,g=..,o=.. (bỏ dấu -)
_rwx_compact() {
  local s
  s=$(_rwx "$1")
  printf '%s' "${s//-/}"
}

users_perm() {
  local p=${1:-/etc/shadow} sym oct owner group type isdir=0 o4 sp
  [[ -e $p ]] || die "Không tồn tại: $p"
  read -r sym oct owner group < <(stat -c '%A %a %U %G' -- "$p")
  type=$(stat -c %F -- "$p")
  [[ -d $p ]] && isdir=1
  o4=$(printf '%04d' "$oct")
  header "Quyền của $p"
  kv "Loại" "$type"
  kv "Dạng ký hiệu" "$sym"
  kv "Dạng số (octal)" "$oct"
  kv "Chủ sở hữu : nhóm" "$owner : $group"
  echo
  local w=$((${#owner} > ${#group} ? ${#owner} : ${#group}))
  w=$((w + 9))
  printf '  %s %s %s  %s\n' "$(pad 'Đối tượng' "$w")" "$(pad 'Số' 4)" "$(pad 'rwx' 5)" "Ý nghĩa"
  printf '  %s %s %s  %s\n' "$(pad "user ($owner)" "$w")" "$(pad "${o4:1:1}" 4)" "$(pad "$(_rwx "${o4:1:1}")" 5)" "$(_rwx_text "${o4:1:1}" "$isdir")"
  printf '  %s %s %s  %s\n' "$(pad "group ($group)" "$w")" "$(pad "${o4:2:1}" 4)" "$(pad "$(_rwx "${o4:2:1}")" 5)" "$(_rwx_text "${o4:2:1}" "$isdir")"
  printf '  %s %s %s  %s\n' "$(pad "other" "$w")" "$(pad "${o4:3:1}" 4)" "$(pad "$(_rwx "${o4:3:1}")" 5)" "$(_rwx_text "${o4:3:1}" "$isdir")"
  sp=${o4:0:1}
  if ((sp)); then
    header "Bit đặc biệt (chữ số đầu = $sp)"
    ((sp & 4)) && printf '  SUID (4): chạy với quyền của CHỦ SỞ HỮU file (vd /usr/bin/passwd)\n'
    ((sp & 2)) && printf '  SGID (2): %s\n' "$( ((isdir)) && printf 'file tạo trong thư mục kế thừa NHÓM của thư mục' || printf 'chạy với quyền của NHÓM sở hữu')"
    ((sp & 1)) && printf '  Sticky (1): chỉ chủ file mới được xoá file của mình (vd /tmp)\n'
  fi
  if [[ $sym == *+ ]] && has getfacl; then
    header "ACL mở rộng (getfacl)"
    getfacl -p "$p" 2>/dev/null
  fi
  cat <<EOF

  Lệnh tương ứng:
    chmod $oct $p               # đặt quyền dạng số
    chmod u=$(_rwx_compact "${o4:1:1}"),g=$(_rwx_compact "${o4:2:1}"),o=$(_rwx_compact "${o4:3:1}") $p   # dạng ký hiệu
    chown $owner:$group $p       # đổi chủ sở hữu & nhóm
  Nhắc lại: r = 4, w = 2, x = 1 → 7 = rwx, 6 = rw-, 5 = r-x, 4 = r--
EOF
}

users_shared_dir() {
  local dir=${1:-$SHARED_ROOT/dev} group=${2:-dev} mode=${3:-2770}
  require_root
  [[ $mode =~ ^[0-7]{3,4}$ ]] || die "Quyền phải là số octal 3–4 chữ số, ví dụ 2770"
  [[ $dir == /* && $dir != / ]] || die "Cần đường dẫn tuyệt đối (không phải /)"
  _ensure_group "$group"
  run mkdir -p "$dir"
  run chown root:"$group" "$dir"
  run chmod "$mode" "$dir"
  [[ $DRY_RUN == 1 ]] && return 0
  ls -ld "$dir"
  log_ok "Thành viên nhóm $group cùng làm việc trong $dir"
  printf '\n%sSGID (2xxx) trên thư mục: file mới tạo tự thuộc nhóm %s → mọi thành viên cùng sửa được.\n' "$C_DIM" "$group"
  printf 'Thêm thành viên: usermod -aG %s <user>  (user cần đăng nhập lại để nhận nhóm mới)%s\n' "$group" "$C_RESET"
}

# _try_as <user> <mô tả> <kỳ vọng ok|deny> <lệnh...> — thử thao tác dưới danh nghĩa user khác
_try_as() {
  local user=$1 desc=$2 expect=$3
  shift 3
  local ok=0
  if has runuser; then runuser -u "$user" -- "$@" >/dev/null 2>&1 && ok=1
  else su -s /bin/sh "$user" -c "$(shell_quote "$@")" >/dev/null 2>&1 && ok=1; fi
  if ((ok)); then
    if [[ $expect == ok ]]; then status OK "$user $desc → được phép (đúng kỳ vọng)"; else status FAIL "$user $desc → được phép (SAI kỳ vọng)"; fi
  else
    if [[ $expect == deny ]]; then status OK "$user $desc → bị từ chối (đúng kỳ vọng)"; else status FAIL "$user $desc → bị từ chối (SAI kỳ vọng)"; fi
  fi
}

# Nhân viên đầu tiên trong CSV thuộc DUY NHẤT nhóm <phòng ban> (dùng cho bài thử quyền)
_first_member_only() {
  awk -F, -v d="$1" '!/^#/ && NF >= 3 { g = $3; gsub(/ /, "", g); if (g == d) { print $1; exit } }' "$USERS_CSV"
}

users_setup_dirs() {
  local d root=$SHARED_ROOT
  require_root
  [[ $root == /* && $root != / ]] || die "SHARED_ROOT không hợp lệ: $root"
  header "Cây thư mục dự án $COMPANY_NAME trong $root"
  run mkdir -p "$root"
  run chmod 755 "$root"
  for d in $DEPARTMENTS; do
    _ensure_group "$d"
    run mkdir -p "$root/$d"
    run chown root:"$d" "$root/$d"
    run chmod 2770 "$root/$d"
  done
  run mkdir -p "$root/chung"
  run chmod 1777 "$root/chung"
  [[ $DRY_RUN == 1 ]] && return 0
  ls -l "$root" | sed 's/^/  /'
  printf '\n  %s : 2770 = chủ + nhóm toàn quyền, phòng ban khác không vào được, SGID giữ nhóm\n' "${DEPARTMENTS// /\/, }/"
  printf '  chung/   : 1777 = mọi nhân viên ghi được nhưng sticky bit → chỉ xoá được file của mình\n'
}

users_demo() {
  local root=$SHARED_ROOT d first other
  require_root
  header "Bước 1: tạo tài khoản nhân viên từ $USERS_CSV"
  users_create "$USERS_CSV" || true
  header "Bước 2: thư mục dự án theo phòng ban"
  users_setup_dirs
  [[ $DRY_RUN == 1 ]] && return 0

  header "Bước 3: thử quyền truy cập thực tế"
  local -a depts
  read -r -a depts <<<"$DEPARTMENTS"
  first=$(_first_member_only "${depts[0]}")
  other=$(_first_member_only "${depts[1]:-}")
  if [[ -n $first ]] && id "$first" >/dev/null 2>&1; then
    _try_as "$first" "(${depts[0]}) tạo file trong ${depts[0]}/" ok touch "$root/${depts[0]}/test-$first.txt"
    _try_as "$first" "(${depts[0]}) tạo file trong ${depts[1]}/" deny touch "$root/${depts[1]}/test-$first.txt"
    _try_as "$first" "(${depts[0]}) tạo file trong chung/" ok touch "$root/chung/$first.txt"
  fi
  if [[ -n $other ]] && id "$other" >/dev/null 2>&1; then
    _try_as "$other" "(${depts[1]}) xem thư mục ${depts[0]}/" deny ls "$root/${depts[0]}"
    _try_as "$other" "(${depts[1]}) tạo file trong ${depts[1]}/" ok touch "$root/${depts[1]}/test-$other.txt"
    [[ -n $first ]] && _try_as "$other" "xoá file của $first trong chung/" deny rm -f "$root/chung/$first.txt"
  fi
  header "Kết quả"
  for d in "${depts[@]}" chung; do ls -l "$root/$d" 2>/dev/null | sed "s|^|  $d/ |"; done
  printf '\n%sFile trong thư mục phòng ban luôn thuộc nhóm phòng ban dù người tạo có nhóm chính khác → tác dụng của SGID.%s\n' "$C_DIM" "$C_RESET"
  printf '%sDọn dẹp: %s users demo-clean%s\n' "$C_DIM" "$PROG" "$C_RESET"
}

users_demo_clean() {
  local g
  require_root
  ASSUME_YES=1 users_delete "$USERS_CSV"
  run rm -rf "$SHARED_ROOT"
  if [[ -f $STATE_DIR/created-groups ]]; then
    for g in $(sort -u "$STATE_DIR/created-groups"); do
      if getent group "$g" >/dev/null && [[ -z $(getent group "$g" | cut -d: -f4) ]]; then
        run groupdel "$g" && status OK "Xoá nhóm $g"
      fi
    done
    [[ $DRY_RUN == 1 ]] || rm -f "$STATE_DIR/created-groups"
  fi
  log_ok "Đã dọn dẹp dữ liệu demo."
}

# Ngắt mọi phiên đăng nhập & tiến trình của một user
_kick_user() {
  local user=$1
  if has loginctl && [[ -d /run/systemd/system ]]; then run loginctl terminate-user "$user" 2>/dev/null || true; fi
  run pkill -KILL -u "$user" 2>/dev/null || true
}

users_kick() {
  local user=$1 n
  require_root
  _safe_to_delete "$user" || die "Chỉ áp dụng cho tài khoản nhân viên (không phải root/tài khoản hệ thống)."
  n=$({ pgrep -u "$user" || true; } | wc -l)
  header "Ngắt phiên của $user ($n tiến trình đang chạy)"
  who | awk -v u="$user" '$1 == u { print "  phiên: " $0 }'
  confirm "Ngắt toàn bộ phiên & tiến trình của $user?" || { log_warn "Đã huỷ."; return 0; }
  _kick_user "$user"
  syslog_event "USERS KICK: $user"
  [[ $DRY_RUN == 1 ]] || log_ok "Đã ngắt $user (còn $({ pgrep -u "$user" || true; } | wc -l) tiến trình)."
}

users_offboard() {
  local user=$1 home arch
  require_root
  detect_distro
  _safe_to_delete "$user" || die "Chỉ áp dụng cho tài khoản nhân viên (không phải root/tài khoản hệ thống)."
  home=$(getent passwd "$user" | cut -d: -f6)
  arch="$BACKUP_DEST/offboard/$user-$(date +%Y%m%d-%H%M%S).tar.gz"
  header "Thủ tục nghỉ việc cho $user ($(getent passwd "$user" | cut -d: -f5))"
  confirm "Khoá tài khoản, ngắt phiên, thu hồi sudo và lưu trữ $home?" || { log_warn "Đã huỷ."; return 0; }
  run usermod -L -e 1 "$user" && status OK "1. Khoá mật khẩu + hết hạn tài khoản (chặn cả SSH key)"
  _kick_user "$user"; status OK "2. Ngắt mọi phiên SSH & tiến trình"
  if id -nG "$user" | grep -qw "$SUDO_GROUP"; then run gpasswd -d "$user" "$SUDO_GROUP" >/dev/null; fi
  status OK "3. Thu hồi quyền quản trị ($SUDO_GROUP)"
  if [[ -n $(crontab -l -u "$user" 2>/dev/null) ]]; then run crontab -r -u "$user"; fi
  status OK "4. Xoá các cron job cá nhân"
  if [[ -d $home ]]; then
    run mkdir -p "$(dirname "$arch")"
    run tar -czpf "$arch" -C "$(dirname "$home")" "$(basename "$home")"
    [[ $DRY_RUN == 1 ]] || chmod 600 "$arch"
    status OK "5. Lưu trữ thư mục home → $arch"
  fi
  syslog_event "USERS OFFBOARD: $user (home lưu tại $arch)"
  printf '\n%sTài khoản vẫn còn (để bàn giao/kiểm toán). Xoá hẳn khi xong: %s users remove %s%s\n' "$C_DIM" "$PROG" "$user" "$C_RESET"
}
