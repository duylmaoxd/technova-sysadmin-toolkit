#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # biến toàn cục dùng chung giữa các file
# =============================================================================
#  modules/backup.sh — CHỨC NĂNG 4: SAO LƯU AN TOÀN TÀI SẢN SỐ
#  Tài sản của TechNova: mã nguồn & dữ liệu dự án (/srv/technova), thư mục
#  nhân viên (/home), cấu hình máy chủ (/etc).
#  Quy trình một lần sao lưu:
#    khoá chống chạy trùng (flock) → nén tar.gz → kiểm tra file nén →
#    tạo checksum SHA-256 → xoay vòng giữ N bản mới nhất → (tuỳ chọn) đẩy bản
#    sao lưu ra máy khác (offsite) bằng rsync → ghi log/lịch sử → cảnh báo nếu lỗi.
#  Chạy định kỳ: "scheduler install" (cron 02:00) hoặc "scheduler timers-install".
# =============================================================================

register_module backup 4 "Sao lưu an toàn tài sản số"
register_action run     "r"  "Sao lưu ngay: nén tar.gz + checksum + xoay vòng" "Thư mục nguồn=$BACKUP_SOURCES" "Thư mục lưu bản sao=$BACKUP_DEST" "Số bản giữ lại=$BACKUP_KEEP"
register_action list    ""   "Danh sách các bản sao lưu" "Thư mục lưu bản sao=$BACKUP_DEST"
register_action verify  ""   "Kiểm tra tính toàn vẹn (checksum + đọc thử)" "File sao lưu=@_pick_backup"
register_action restore "rd" "Khôi phục bản sao lưu ra một thư mục" "File sao lưu=@_pick_backup" "Giải nén vào thư mục=/tmp/restore"
register_action rotate  "rd" "Xoá bớt bản cũ, chỉ giữ N bản mới nhất" "Số bản giữ lại=$BACKUP_KEEP" "Thư mục lưu bản sao=$BACKUP_DEST"
register_action history ""   "Lịch sử các lần sao lưu" "Số dòng=20"
register_action cloud-setup  "i"  "Kết nối Google Drive (rclone) để tự đưa backup & log lên đám mây" "Tên remote rclone=gdrive" "Thư mục trên Drive=TechNova-Server"
register_action cloud-status ""   "Trạng thái kết nối Google Drive & dung lượng còn trống"
register_action upload       "r"  "Tải một bản sao lưu lên Google Drive" "File sao lưu=@_pick_backup"
register_action cloud-list   ""   "Danh sách bản sao lưu & gói log đang có trên Google Drive"

_backup_host() { hostname -s 2>/dev/null || hostname; }

# Các bản sao lưu của máy này, mới nhất trước (tên file chứa thời gian nên sắp xếp theo tên)
_backup_files() {
  local dest=${1:-$BACKUP_DEST}
  [[ -d $dest ]] || return 0
  find "$dest" -maxdepth 1 -type f -name "backup-$(_backup_host)-*.tar.gz" 2>/dev/null | sort -r
}

_pick_backup() {
  local f
  while IFS= read -r f; do
    printf '%s\t%s  %s\n' "$f" "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%d/%m/%Y %H:%M')"
  done < <(_backup_files)
}

backup_run() {
  local sources=${1:-$BACKUP_SOURCES} dest=${2:-$BACKUP_DEST} keep=${3:-$BACKUP_KEEP}
  local -a src=() rel=() excl=() pats=()
  local s stamp file name t0 rc=0 errlog size count p
  is_int "$keep" && ((keep >= 1)) || die "Số bản giữ lại phải là số nguyên ≥ 1 (nhận: $keep)"
  read -r -a src <<<"$sources"
  ((${#src[@]})) || die "Chưa chỉ định thư mục nguồn."
  local -a found=()
  for s in "${src[@]}"; do
    if [[ ! -e $s ]]; then log_warn "Bỏ qua (không tồn tại): $s"; continue; fi
    s=$(readlink -f "$s")
    found+=("$s")
    rel+=("${s#/}") # đường dẫn tương đối so với / (tar -C /) → khôi phục linh hoạt hơn
  done
  ((${#found[@]})) || die "Không có thư mục nguồn nào tồn tại: ${src[*]}"
  src=("${found[@]}")
  dest=$(readlink -m "$dest")
  ((EUID == 0)) || log_warn "Không chạy bằng root — các file không có quyền đọc (ví dụ /etc/shadow) sẽ bị bỏ qua."

  # Mẫu loại trừ (không để shell tự mở rộng dấu *)
  read -r -a pats <<<"$BACKUP_EXCLUDES"
  for p in "${pats[@]}"; do excl+=("--exclude=$p"); done
  excl+=("--exclude=${dest#/}") # không sao lưu chính thư mục chứa bản sao lưu

  stamp=$(date +%Y%m%d-%H%M%S)
  name="backup-$(_backup_host)-$stamp.tar.gz"
  # Hai lần chạy trong cùng một giây → chờ sang giây mới để tên file không trùng
  while [[ -e $dest/$name ]]; do
    sleep 1
    stamp=$(date +%Y%m%d-%H%M%S)
    name="backup-$(_backup_host)-$stamp.tar.gz"
  done
  file="$dest/$name"
  header "Sao lưu ${src[*]} → $file"
  if [[ $DRY_RUN == 1 ]]; then
    run mkdir -p "$dest"
    run tar -czpf "$file" --ignore-failed-read "${excl[@]}" -C / "${rel[@]}"
    run sha256sum "$name"
    log_info "Sau đó: xoay vòng giữ $keep bản mới nhất${BACKUP_REMOTE:+, đẩy sang $BACKUP_REMOTE}."
    return 0
  fi
  mkdir -p "$dest"
  chmod 700 "$dest" # bản sao lưu chứa dữ liệu nhạy cảm → chỉ chủ sở hữu được đọc

  # Khoá: tránh hai tiến trình sao lưu chạy cùng lúc (cron + chạy tay)
  exec 9>"$dest/.backup.lock"
  flock -n 9 || die "Đang có một tiến trình sao lưu khác chạy (khoá $dest/.backup.lock)."

  tk_mktemp errlog
  t0=$SECONDS
  # --ignore-failed-read: file không đọc được chỉ cảnh báo, không làm hỏng cả bản sao lưu
  tar -czpf "$file" --ignore-failed-read --warning=no-file-changed "${excl[@]}" -C / "${rel[@]}" 2>"$errlog" || rc=$?
  if ((rc > 1)) || [[ ! -s $file ]]; then
    cat "$errlog" >&2
    _backup_record "$file" 0 $((SECONDS - t0)) FAIL
    syslog_event "BACKUP FAILED: $file (tar exit $rc)"
    if declare -F alert_send >/dev/null; then
      local body
      printf -v body 'tar kết thúc với mã %s khi sao lưu %s vào %s.\n\n%s' "$rc" "${src[*]}" "$file" "$(tail -n 20 "$errlog")"
      alert_send "[$(_backup_host)] Sao lưu THẤT BẠI" "$body" || true
    fi
    die "Sao lưu thất bại (tar mã $rc)."
  fi
  if [[ -s $errlog ]]; then
    log_warn "Có $(wc -l <"$errlog") cảnh báo khi đọc file (xem chi tiết trong log)."
    _log_write WARN "tar: $(head -n 5 "$errlog" | tr '\n' ' ')"
  fi

  # Kiểm tra file nén đọc được + tạo checksum
  gzip -t "$file" || die "File nén bị lỗi: $file"
  count=$(tar -tzf "$file" | wc -l)
  (cd "$dest" && sha256sum "$name" >"$name.sha256")
  chmod 600 "$file" "$file.sha256"
  size=$(human_bytes "$(stat -c %s "$file")")
  status OK "Đã tạo $name ($size, $count mục, $((SECONDS - t0)) giây)"
  status OK "Checksum SHA-256: $(cut -d' ' -f1 "$file.sha256")"

  backup_rotate "$keep" "$dest"

  # Đẩy bản sao lưu sang máy khác (nếu cấu hình BACKUP_REMOTE="user@host:/thu/muc")
  if [[ -n $BACKUP_REMOTE ]]; then
    local -a ssh_opts
    read -r -a ssh_opts <<<"$SSH_OPTS"
    if rsync -a -e "ssh ${ssh_opts[*]}" "$file" "$file.sha256" "$BACKUP_REMOTE/" 2>>"$errlog"; then
      status OK "Đã đẩy bản sao lưu sang $BACKUP_REMOTE"
    else
      status FAIL "Không đẩy được sang $BACKUP_REMOTE (xem $LOG_FILE)"
      _log_write ERROR "rsync: $(tail -n 3 "$errlog" | tr '\n' ' ')"
    fi
  fi
  # Đưa bản sao lưu lên Google Drive (nếu đã cấu hình GDRIVE_REMOTE) — bản sao "offsite" trên đám mây
  if [[ -n $GDRIVE_REMOTE ]]; then
    if cloud_upload "$file" "$file.sha256" backups; then
      status OK "Đã tải lên Google Drive: $(cloud_path backups)/$name"
      cloud_prune backups "$GDRIVE_KEEP_DAYS"
    else
      status FAIL "Không tải được lên Google Drive — bản sao vẫn còn trên máy chủ"
      if declare -F alert_send >/dev/null; then
        alert_send "[$(_backup_host)] Không tải được backup lên Google Drive" "Bản sao lưu $name đã tạo trên máy chủ nhưng tải lên $(cloud_path backups) thất bại. Xem $LOG_DIR/rclone.log." || true
      fi
    fi
  fi
  _backup_record "$file" "$size" $((SECONDS - t0)) OK
  syslog_event "BACKUP OK: $file ($size)"
  log_ok "Sao lưu hoàn tất."
}

# Ghi lịch sử: thời gian, file, dung lượng, số giây, trạng thái
_backup_record() {
  local hist="$REPORT_DIR/backup-history.csv"
  [[ -f $hist ]] || { printf 'time,file,size,seconds,status\n' >"$hist"; own_like_parent "$hist"; }
  printf '%s,%s,%s,%s,%s\n' "$(date '+%F %T')" "$1" "$2" "$3" "$4" >>"$hist"
}

backup_list() {
  local dest=${1:-$BACKUP_DEST} f n=0 total=0 sz
  header "Bản sao lưu của máy $(_backup_host) trong $dest"
  if [[ ! -d $dest ]]; then log_warn "Chưa có thư mục $dest — hãy chạy: $PROG backup run"; return 0; fi
  [[ -r $dest && -x $dest ]] || die "Không có quyền đọc $dest (thử sudo)."
  while IFS= read -r f; do
    sz=$(stat -c %s "$f")
    total=$((total + sz)) n=$((n + 1))
    printf '  %s  %8s  %s %s\n' "$(date -r "$f" '+%Y-%m-%d %H:%M')" "$(human_bytes "$sz")" "$(basename "$f")" \
      "$([[ -f $f.sha256 ]] && printf '%s[sha256]%s' "$C_GREEN" "$C_RESET")"
  done < <(_backup_files "$dest")
  if ((n == 0)); then log_warn "Chưa có bản sao lưu nào."; return 0; fi
  printf '\n  Tổng: %d bản, %s · đang giữ tối đa %s bản (BACKUP_KEEP)\n' "$n" "$(human_bytes "$total")" "$BACKUP_KEEP"
}

backup_verify() {
  local file=$1 bad=0 n
  [[ -f $file ]] || die "Không tìm thấy file: $file"
  header "Kiểm tra $(basename "$file")"
  if [[ -f $file.sha256 ]]; then
    if (cd "$(dirname "$file")" && sha256sum --quiet -c "$(basename "$file").sha256"); then status OK "Checksum SHA-256 khớp"
    else status FAIL "Checksum KHÔNG khớp — file có thể đã bị thay đổi/hỏng"; bad=1; fi
  else
    status WARN "Không có file checksum .sha256"
  fi
  if gzip -t "$file" 2>/dev/null; then status OK "Cấu trúc gzip hợp lệ"; else status FAIL "File gzip bị hỏng"; bad=1; fi
  if n=$(tar -tzf "$file" 2>/dev/null | wc -l) && ((n > 0)); then status OK "Đọc được danh sách $n mục trong file tar"
  else status FAIL "Không đọc được nội dung tar"; bad=1; fi
  header "10 mục đầu tiên trong bản sao lưu"
  tar -tzvf "$file" 2>/dev/null | take 10
  ((bad == 0)) || die "Bản sao lưu KHÔNG toàn vẹn."
}

backup_restore() {
  local file=$1 target=${2:-/tmp/restore}
  [[ -f $file ]] || die "Không tìm thấy file: $file"
  target=$(readlink -m "$target")
  if [[ $target == / ]]; then
    log_warn "Khôi phục thẳng vào / sẽ GHI ĐÈ file hệ thống hiện tại!"
    confirm "Bạn chắc chắn muốn ghi đè lên hệ thống thật?" || { log_warn "Đã huỷ."; return 0; }
  fi
  confirm "Giải nén $(basename "$file") vào $target?" || { log_warn "Đã huỷ."; return 0; }
  run mkdir -p "$target"
  run tar -xzpf "$file" -C "$target"
  [[ $DRY_RUN == 1 ]] && return 0
  log_ok "Đã khôi phục vào $target"
  header "Nội dung đã khôi phục"
  if has tree; then tree -L 2 "$target" | take 40; else find "$target" -maxdepth 2 | take 40; fi
  printf '\n%sSo sánh với bản hiện tại, ví dụ: diff -r %s/etc/ssh /etc/ssh%s\n' "$C_DIM" "$target" "$C_RESET"
}

backup_rotate() {
  local keep=${1:-$BACKUP_KEEP} dest=${2:-$BACKUP_DEST} f i=0 removed=0
  is_int "$keep" && ((keep >= 1)) || die "Số bản giữ lại phải ≥ 1"
  local -a files=()
  mapfile -t files < <(_backup_files "$dest")
  if ((${#files[@]} <= keep)); then
    log_info "Có ${#files[@]} bản, giữ tối đa $keep — không cần xoá bản nào."
    return 0
  fi
  for f in "${files[@]}"; do
    i=$((i + 1))
    ((i > keep)) || continue
    run rm -f -- "$f" "$f.sha256"
    removed=$((removed + 1))
    log_info "Xoá bản cũ: $(basename "$f")"
  done
  log_ok "Xoay vòng: giữ $keep bản mới nhất, đã xoá $removed bản."
}

backup_history() {
  local n=${1:-20} hist="$REPORT_DIR/backup-history.csv"
  header "Lịch sử sao lưu ($hist)"
  [[ -f $hist ]] || { log_warn "Chưa có lịch sử sao lưu."; return 0; }
  { head -n 1 "$hist"; tail -n +2 "$hist" | tail -n "$n"; } | table , || tail -n "$n" "$hist"
}

# ------------------------------------------------------------ GOOGLE DRIVE ---
backup_cloud_setup() {
  local remote=${1:-gdrive} folder=${2:-TechNova-Server} token
  [[ $remote =~ ^[A-Za-z0-9_-]+$ ]] || die "Tên remote chỉ gồm chữ, số, - và _"
  need_cmd rclone rclone || return 1
  header "Kết nối Google Drive cho $(hostname)"
  if rclone listremotes 2>/dev/null | grep -qx "$remote:"; then
    status OK "Đã có remote rclone '$remote'"
  else
    cat <<EOF
  Máy chủ không có trình duyệt, nên cấp quyền Google Drive theo 2 bước:
    1) Trên máy tính CÓ trình duyệt (đã cài rclone), chạy:
         rclone authorize "drive"
       → đăng nhập Google, bấm "Cho phép", terminal in ra một chuỗi JSON {"access_token":...}
    2) Dán chuỗi JSON đó vào đây (Enter để kết thúc).
EOF
    read -r -p "  Token JSON: " token </dev/tty || die "Đã huỷ."
    [[ $token == *access_token* && $token == *refresh_token* ]] || die "Token không đúng định dạng (cần có access_token và refresh_token)."
    # scope=drive.file: toolkit chỉ thấy/sửa được file do chính nó tạo ra trên Drive
    run rclone config create "$remote" drive scope=drive.file token="$token" config_is_local=false >/dev/null
    status OK "Đã tạo remote rclone '$remote' (lưu trong $(rclone config file 2>/dev/null | tail -n 1))"
  fi
  config_set GDRIVE_REMOTE "$remote:$folder"
  [[ $DRY_RUN == 1 ]] && return 0
  log_info "Thử tải một file lên Drive..."
  local probe
  tk_mktemp probe
  printf 'Kết nối từ %s lúc %s\n' "$(hostname)" "$(date '+%F %T')" >"$probe"
  mv "$probe" "$probe.txt" && TK_TMP_FILES+=("$probe.txt")
  if cloud_upload "$probe.txt" backups; then
    rclone deletefile "$(cloud_path backups)/$(basename "$probe.txt")" 2>/dev/null || true
    log_ok "Google Drive hoạt động. Từ giờ 'backup run' và 'monitor log-upload' sẽ tự đưa dữ liệu lên $(cloud_path '')"
  else
    die "Không ghi được lên Google Drive — kiểm tra lại token/kết nối mạng."
  fi
}

backup_cloud_status() {
  header "Google Drive"
  kv "GDRIVE_REMOTE" "${GDRIVE_REMOTE:-(chưa đặt)}"
  if ! cloud_ready; then status WARN "Chưa dùng được: $(cloud_explain)"; return 0; fi
  status OK "rclone $(rclone version 2>/dev/null | awk 'NR == 1 { print $2 }') · remote ${GDRIVE_REMOTE%%:*} sẵn sàng"
  kv "Thư mục backup" "$(cloud_path backups)"
  kv "Thư mục log" "$(cloud_path logs)"
  kv "Giữ trên Drive" "$GDRIVE_KEEP_DAYS ngày (0 = giữ hết)"
  local about
  about=$(rclone about "${GDRIVE_REMOTE%%:*}:" 2>/dev/null || true)
  [[ -n $about ]] && sed 's/^/  /' <<<"$about"
  return 0
}

backup_upload() {
  local file=$1
  [[ -f $file ]] || die "Không tìm thấy file: $file"
  header "Tải $(basename "$file") lên Google Drive"
  local -a files=("$file")
  [[ -f $file.sha256 ]] && files+=("$file.sha256")
  cloud_upload "${files[@]}" backups || return 1
  [[ $DRY_RUN == 1 ]] || log_ok "Đã tải lên $(cloud_path backups)/"
}

backup_cloud_list() {
  header "Bản sao lưu trên Google Drive — $(cloud_path backups)"
  cloud_list backups || return 0
  header "Gói log trên Google Drive — $(cloud_path logs)"
  cloud_list logs || true
}
