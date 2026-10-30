#!/usr/bin/env bash
# =============================================================================
#  tests/demo-test.sh — Kiểm thử tự động 5 chức năng của LinuxAdmin Toolkit
#  theo kịch bản TechNova (nhân viên mới → process treo → cảnh báo → sao lưu →
#  tự động hoá → nghỉ việc → dọn dẹp). Mỗi bước in PASS/FAIL, cuối cùng tổng kết.
#
#  CẢNH BÁO: script TẠO/XOÁ user thật, tạo /srv/technova, sửa crontab của root.
#  Chỉ chạy trên máy ảo hoặc container Docker:
#     docker run --rm --cap-add SYS_NICE -v "$PWD/tests:/tests:ro" \
#        technova/sysadmin-toolkit:1.0 bash /tests/demo-test.sh --yes
#     sudo bash tests/demo-test.sh --yes          # trên VM đã cài toolkit
# =============================================================================
set -uo pipefail

SA=${SA:-sysadmin}                     # lệnh toolkit (hoặc đường dẫn ./sysadmin.sh)
LOG=${LOG:-/tmp/technova-demo-test.log}
PASS=0 FAIL=0 N=0
G=$'\e[32m' R=$'\e[31m' B=$'\e[1m' D=$'\e[2m' Z=$'\e[0m'
[[ -t 1 ]] || G='' R='' B='' D='' Z=''

if [[ ${1:-} != --yes ]]; then
  echo "Script này tạo/xoá user và sửa crontab. Chỉ chạy trên VM/container: bash $0 --yes"
  exit 2
fi
((EUID == 0)) || { echo "Cần chạy bằng root (sudo)."; exit 2; }
command -v "$SA" >/dev/null || { echo "Không tìm thấy lệnh '$SA' (đặt SA=/đường/dẫn/sysadmin.sh)"; exit 2; }

: >"$LOG"
sa() { "$SA" --no-color --yes "$@" >>"$LOG" 2>&1; }                 # chạy toolkit, ghi log
out() { "$SA" --no-color --yes "$@" 2>&1 | tee -a "$LOG"; }          # chạy và lấy đầu ra
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$Z"; echo "== $* ==" >>"$LOG"; }
check() { # check "<mô tả>" <lệnh kiểm tra...>
  local desc=$1; shift
  N=$((N + 1))
  if "$@" >>"$LOG" 2>&1; then PASS=$((PASS + 1)); printf '  %s[PASS]%s T%02d %s\n' "$G" "$Z" "$N" "$desc"
  else FAIL=$((FAIL + 1)); printf '  %s[FAIL]%s T%02d %s\n' "$R" "$Z" "$N" "$desc"; fi
}
as() { local u=$1; shift; runuser -u "$u" -- "$@"; }
in_group() { id -nG "$1" | tr ' ' '\n' | grep -qx "$2"; }
perm() { [[ $(stat -c %a "$1") == "$2" ]]; }
start_hog() { (as cuonglv bash -c 'exec -a train_model.py bash -c "while :; do :; done"' 2>/dev/null &); sleep 3; }
hog_pid() { pgrep -u cuonglv -f train_model.py | head -n 1; }

CONF=$(dirname "$(readlink -f "$(command -v "$SA")")")/config/toolkit.conf
SHARED=/srv/technova
BK=/var/backups/sysadmin-toolkit

echo "${B}Kiểm thử LinuxAdmin Toolkit — $(hostname) — $(date '+%d/%m/%Y %H:%M')${Z}"
echo "Log chi tiết: $LOG"

# ---------------------------------------------------------------- 0. Nền tảng
step "0. Nền tảng & hai chế độ"
check "In được phiên bản" bash -c "'$SA' --version | grep -q 'LinuxAdmin Toolkit'"
check "Help liệt kê đủ 5 chức năng" bash -c "'$SA' --no-color help | grep -cE '^  (users|monitor|alert|backup|scheduler) ' | grep -qx 5"
check "Help của module sinh tự động (users)" bash -c "'$SA' --no-color help users | grep -q offboard"
check "Tham số sai bị từ chối (mã thoát ≠ 0)" bash -c "! '$SA' --no-color khong-co-module 2>/dev/null"
check "Dry-run không tạo user" bash -c "'$SA' --no-color --dry-run --yes users add dryrunuser >/dev/null 2>&1; ! id dryrunuser"

# ------------------------------------------------------- 1. users: nhân viên mới
step "1. users — nhân viên mới & phân quyền"
sa users create
check "Tạo 7 nhân viên từ users.csv" bash -c 'for u in annv binhtt cuonglv dungpt emhd giangvt hungnv; do id $u >/dev/null || exit 1; done'
check "Phòng ban đúng: annv∈dev, cuonglv∈data, giangvt∈qa+dev" bash -c "$(declare -f in_group); in_group annv dev && in_group cuonglv data && in_group giangvt qa && in_group giangvt dev"
check "Tech Lead hungnv có quyền sudo" bash -c "id -nG hungnv | grep -qwE 'sudo|wheel'"
check "Mật khẩu tạm bắt buộc đổi ở lần đăng nhập đầu" bash -c "chage -l annv | grep -qi 'must be changed'"
check "File mật khẩu tạm có quyền 600" bash -c "ls -l \$(ls -t $(dirname "$CONF")/../reports/users-created-*.csv | head -1) | grep -q '^-rw-------'"
check "Chạy lại không tạo trùng (idempotent)" bash -c "'$SA' --no-color --yes users create | grep -q 'Bỏ qua (đã có)  *: 7'"
sa users setup-dirs
check "Thư mục phòng ban dev/data/qa quyền 2770 (SGID)" bash -c "$(declare -f perm); perm $SHARED/dev 2770 && perm $SHARED/data 2770 && perm $SHARED/qa 2770"
check "Thư mục chung quyền 1777 (sticky bit)" bash -c "$(declare -f perm); perm $SHARED/chung 1777"
check "annv (dev) ghi được vào dev/" runuser -u annv -- touch $SHARED/dev/annv.txt
check "SGID: file mới thuộc nhóm dev" bash -c "[[ \$(stat -c %G $SHARED/dev/annv.txt) == dev ]]"
check "annv (dev) KHÔNG ghi được vào data/" bash -c "! runuser -u annv -- touch $SHARED/data/x 2>/dev/null"
check "cuonglv (data) KHÔNG xem được dev/" bash -c "! runuser -u cuonglv -- ls $SHARED/dev >/dev/null 2>&1"
runuser -u annv -- touch $SHARED/chung/annv.txt
check "Sticky: cuonglv KHÔNG xoá được file của annv trong chung/" bash -c "! runuser -u cuonglv -- rm -f $SHARED/chung/annv.txt 2>/dev/null; [[ -e $SHARED/chung/annv.txt ]]"
sa users sudo binhtt grant
check "Cấp sudo cho binhtt" bash -c "id -nG binhtt | grep -qwE 'sudo|wheel'"
sa users sudo binhtt revoke
check "Thu hồi sudo của binhtt" bash -c "! id -nG binhtt | grep -qwE 'sudo|wheel'"
sa users lock emhd
check "Khoá tài khoản emhd" bash -c "passwd -S emhd | awk '{print \$2}' | grep -qE '^L'"
sa users unlock emhd
check "Mở khoá tài khoản emhd" bash -c "passwd -S emhd | awk '{print \$2}' | grep -qE '^P'"
check "Audit bảo mật chạy và có tổng kết" bash -c "'$SA' --no-color users audit | grep -q 'Tổng kết'"

# ---------------------------------------------- 2. monitor: process treo ngốn CPU
step "2. monitor — ai đang làm gì, ai treo process"
start_hog
P=$(hog_pid)
check "Mô phỏng: cuonglv chạy train_model.py ngốn CPU (PID ${P:-?})" test -n "$P"
check "monitor usage thấy cuonglv đứng đầu CPU" bash -c "'$SA' --no-color monitor usage | grep -E '^\s+\*?\s*[a-z]' | head -1 | grep -q cuonglv"
check "monitor hogs phát hiện train_model.py" bash -c "'$SA' --no-color monitor hogs | grep -q 'train_model.py'"
check "monitor top hiển thị người chạy" bash -c "'$SA' --no-color monitor top 3 | grep -q cuonglv"
check "monitor who / overview / troubleshoot chạy được" bash -c "'$SA' --no-color monitor who >/dev/null && '$SA' --no-color monitor overview >/dev/null && '$SA' --no-color monitor troubleshoot | grep -q 'Tổng kết'"
if sa monitor renice "$P" 19; then
  check "renice: hạ ưu tiên process xuống nice 19" bash -c "[[ \$(ps -o ni= -p $P | tr -d ' ') == 19 ]]"
else
  echo "  ${D}(bỏ qua renice — môi trường thiếu quyền CAP_SYS_NICE, chạy docker với --cap-add SYS_NICE)${Z}"
fi

# -------------------------------------------------------- 3. alert: cảnh báo
step "3. alert — cảnh báo tức thời"
rm -f "$(dirname "$CONF")/../logs/state/alert."* 2>/dev/null
check "alert check phát hiện process ngốn tài nguyên" bash -c "'$SA' --no-color alert check | grep -q 'Process ngốn tài nguyên'"
check "Cảnh báo được ghi vào alerts.log" bash -c "grep -q 'CẢNH BÁO' $(dirname "$CONF")/../logs/alerts.log"
check "Cooldown: lần kiểm tra kế tiếp không gửi lại" bash -c "'$SA' --no-color alert check 2>&1 | grep -q 'chờ đủ'"
sa monitor kill "$P"
sleep 1
check "monitor kill dừng process treo" bash -c "! kill -0 $P 2>/dev/null"
check "Hết sự cố → gửi tin 'ĐÃ ỔN ĐỊNH'" bash -c "'$SA' --no-color alert check >/dev/null 2>&1; grep -q 'ĐÃ ỔN ĐỊNH' $(dirname "$CONF")/../logs/alerts.log"
check "Số liệu được ghi vào metrics.csv" bash -c "[[ \$(wc -l < $(dirname "$CONF")/../reports/metrics.csv) -ge 3 ]]"
check "Đổi ngưỡng HOG_MEM qua config_set" bash -c "'$SA' --no-color --yes alert set-threshold HOG_MEM 40 >/dev/null && grep -q \"^HOG_MEM='40'\" $CONF"
sa alert set-threshold HOG_MEM 30

# ------------------------------------------- 3'. alert: phát hiện tấn công (IDS)
step "3'. alert — phát hiện tấn công bất thường (IDS)"
STATE=$(dirname "$CONF")/../logs/state
sa alert baseline
sa alert security            # đánh dấu vị trí log hiện tại cho cửa sổ trượt
rm -f "$STATE/ids-seen"
check "Chụp trạng thái chuẩn (checksum file + cổng + user)" bash -c "[[ -s $STATE/ids-integrity.sha && -s $STATE/ids-users.list ]]"
check "Hệ thống bình thường → không có dấu hiệu tấn công" bash -c "'$SA' --no-color alert security | grep -q 'Không phát hiện'"
# Mô phỏng tấn công: dò mật khẩu SSH từ 203.0.113.9 rồi đăng nhập thành công,
# tạo tài khoản UID 0 ngoài toolkit và chạy mã độc từ /tmp
for i in 1 2 3 4 5 6; do logger -p authpriv.notice -t "sshd[4242]" "Failed password for invalid user u$i from 203.0.113.9 port 5$i ssh2"; done
for u in admin oracle test guest postgres; do logger -p authpriv.notice -t "sshd[4242]" "Invalid user $u from 203.0.113.9 port 5000"; done
logger -p authpriv.notice -t "sshd[4243]" "Accepted password for annv from 203.0.113.9 port 5100 ssh2"
useradd -o -u 0 -M -s /bin/bash tkbackdoor 2>/dev/null
cp /bin/sleep /tmp/kdevtmpfsi && (/tmp/kdevtmpfsi 120 &)
sleep 2
IDS=$("$SA" --no-color alert security 2>&1); echo "$IDS" >>"$LOG"
check "Phát hiện dò mật khẩu SSH từ 203.0.113.9" grep -q 'Dò mật khẩu SSH: 6 lần thất bại từ IP 203.0.113.9' <<<"$IDS"
check "Phát hiện dò tên tài khoản (password spraying)" grep -q 'Dò tên tài khoản' <<<"$IDS"
check "Cảnh báo NGHI BỊ CHIẾM TÀI KHOẢN annv" grep -q 'NGHI BỊ CHIẾM TÀI KHOẢN: annv' <<<"$IDS"
check "Phát hiện /etc/passwd bị thay đổi ngoài toolkit" grep -q 'THAY ĐỔI: /etc/passwd' <<<"$IDS"
check "Phát hiện tài khoản mới có UID 0" grep -q 'tkbackdoor có UID 0' <<<"$IDS"
check "Phát hiện process chạy từ /tmp" grep -q '/tmp/kdevtmpfsi' <<<"$IDS"
check "Gửi cảnh báo [TẤN CÔNG] (ghi vào alerts.log)" bash -c "grep -q 'TẤN CÔNG' $(dirname "$CONF")/../logs/alerts.log"
check "Chống spam: lần kế tiếp không gửi lại" bash -c "'$SA' --no-color alert security 2>&1 | grep -q 'không gửi lại'"
pkill -f /tmp/kdevtmpfsi; rm -f /tmp/kdevtmpfsi
userdel tkbackdoor 2>/dev/null
sa alert baseline
check "logcheck tổng hợp đăng nhập thất bại theo IP" bash -c "'$SA' --no-color monitor logcheck 1 | grep -q '203.0.113.9'"
if iptables -L INPUT -n >/dev/null 2>&1; then
  sa alert ban 198.51.100.7
  check "ban: chặn IP bằng tường lửa" bash -c "iptables -S INPUT | grep -q '198.51.100.7.*sysadmin-toolkit'"
  check "banned: liệt kê IP đang bị chặn" bash -c "'$SA' --no-color alert banned | grep -q 198.51.100.7"
  sa alert unban 198.51.100.7
  check "unban: bỏ chặn IP" bash -c "! iptables -S INPUT | grep -q 198.51.100.7"
else
  echo "  ${D}(bỏ qua ban/unban — thiếu quyền tường lửa, chạy docker với --cap-add NET_ADMIN)${Z}"
fi

# -------------------------------------------------------------- 4. backup
step "4. backup — sao lưu tài sản số"
echo "model v1" >$SHARED/data/model.txt
sa backup run
F=$(ls -1t $BK/backup-*.tar.gz 2>/dev/null | head -n 1)
check "Tạo bản sao lưu tar.gz" test -s "$F"
check "Có file checksum SHA-256 và khớp" bash -c "cd $BK && sha256sum -c \$(basename '$F').sha256"
check "Bản sao lưu chứa dữ liệu dự án srv/technova" bash -c "tar -tzf '$F' | grep -q 'srv/technova/data/model.txt'"
check "backup verify báo toàn vẹn" bash -c "'$SA' --no-color backup verify '$F' | grep -q 'Checksum SHA-256 khớp'"
rm -rf /tmp/restore-test
sa backup restore "$F" /tmp/restore-test
check "Khôi phục đúng nội dung file" bash -c "grep -q 'model v1' /tmp/restore-test/srv/technova/data/model.txt"
sleep 1; sa backup run; sleep 1; sa backup run
sa backup rotate 2
check "Xoay vòng: chỉ giữ 2 bản mới nhất" bash -c "[[ \$(ls -1 $BK/backup-*.tar.gz | wc -l) -eq 2 ]]"

if command -v rclone >/dev/null; then
  # "Google Drive" giả lập bằng remote rclone kiểu local — không gửi dữ liệu ra ngoài
  FD=/tmp/tk-fakedrive OLD_REMOTE=$(grep '^GDRIVE_REMOTE=' "$CONF")
  rm -rf $FD; rclone config create tktest local >/dev/null 2>&1
  sed -i "s|^GDRIVE_REMOTE=.*|GDRIVE_REMOTE=\"tktest:$FD\"|" "$CONF"
  check "cloud-status: remote sẵn sàng" bash -c "'$SA' --no-color backup cloud-status | grep -q 'sẵn sàng'"
  sa backup run
  check "backup run tự tải bản sao lưu + checksum lên Drive" bash -c "cd $FD/\$(hostname)/backups && sha256sum -c backup-*.sha256"
  sa monitor log-upload
  check "monitor log-upload đóng gói log và tải lên Drive" bash -c "ls $FD/\$(hostname)/logs/logs-*.tar.gz && tar -tzf \$(ls $FD/\$(hostname)/logs/logs-*.tar.gz | head -1) | grep -q logcheck"
  check "cloud-list liệt kê file trên Drive" bash -c "'$SA' --no-color backup cloud-list | grep -q 'logs-'"
  sed -i "s|^GDRIVE_REMOTE=.*|$OLD_REMOTE|" "$CONF"; rclone config delete tktest >/dev/null 2>&1; rm -rf $FD
else
  echo "  ${D}(bỏ qua Google Drive — chưa cài rclone)${Z}"
fi

# ----------------------------------------------------------- 5. scheduler
step "5. scheduler — tự động hoá bảo dưỡng"
sa scheduler install
check "Crontab có khối lịch của toolkit" bash -c "crontab -l | grep -q '>>> sysadmin-toolkit >>>'"
check "Đủ 5 job: backup, log-upload, maintenance, alert check, report" bash -c "crontab -l | grep -cE 'backup run|monitor log-upload|scheduler maintenance|alert check|monitor report' | grep -qx 5"
sa scheduler add "*/10 * * * *" "echo 50% done >> /tmp/x.log"
check "Thêm job tuỳ chỉnh (dấu % được thoát thành \\%)" bash -c "crontab -l | grep -q 'echo 50\\\\% done'"
check "Giải thích biểu thức cron bằng tiếng Việt" bash -c "'$SA' --no-color scheduler explain '30 3 * * *' | grep -q 'lúc 03:30 mỗi ngày'"
check "Biểu thức cron sai bị từ chối" bash -c "! '$SA' --no-color scheduler explain 'sai bieu thuc' 2>/dev/null"
touch -d '10 days ago' /tmp/old-cache.bin /var/tmp/old.log
sa scheduler maintenance
check "Bảo dưỡng xoá file tạm cũ hơn 7 ngày" bash -c "[[ ! -e /tmp/old-cache.bin && ! -e /var/tmp/old.log ]]"
sa scheduler remove
check "Gỡ khối lịch, crontab sạch" bash -c "! crontab -l 2>/dev/null | grep -q sysadmin-toolkit"

# ------------------------------------------- 1'. users: nghỉ việc & ngắt phiên
step "1'. users — ngắt phiên & nhân viên nghỉ việc"
(as annv sleep 600 2>/dev/null &)
sleep 1
sa users kick annv
sleep 1
check "kick: annv không còn tiến trình nào" bash -c "! pgrep -u annv >/dev/null"
sa users offboard binhtt
check "offboard: tài khoản binhtt bị khoá" bash -c "passwd -S binhtt | awk '{print \$2}' | grep -qE '^L'"
check "offboard: home binhtt được lưu trữ" bash -c "ls $BK/offboard/binhtt-*.tar.gz >/dev/null 2>&1"
check "Từ chối offboard tài khoản hệ thống (root)" bash -c "! '$SA' --no-color --yes users offboard root >/dev/null 2>&1"

# --------------------------------------------------------------- Dọn dẹp
step "Dọn dẹp"
sa users demo-clean
check "demo-clean xoá hết nhân viên demo" bash -c 'for u in annv binhtt cuonglv dungpt emhd giangvt hungnv; do id $u >/dev/null 2>&1 && exit 1; done; exit 0'
check "demo-clean xoá $SHARED và các nhóm phòng ban" bash -c "[[ ! -d $SHARED ]] && ! getent group dev >/dev/null"
rm -rf /tmp/restore-test

printf '\n%sKẾT QUẢ: %d/%d PASS' "$B" "$PASS" "$N"
((FAIL)) && printf ' · %s%d FAIL%s' "$R" "$FAIL" "$Z$B"
printf '%s\n' "$Z"
echo "Log chi tiết: $LOG"
((FAIL == 0))
