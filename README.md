# LinuxAdmin Toolkit — Quản trị máy chủ TechNova bằng Bash

> Đồ án môn **OSG203 – Hệ điều hành Linux** · Đề tài **#3: Bash Scripting cho System Administration**

## Bối cảnh doanh nghiệp

**TechNova Solutions** là công ty phát triển phần mềm và phân tích dữ liệu. Toàn bộ nhân sự (Lập trình viên,
Data Analyst, Tester) cùng SSH vào một máy chủ Ubuntu Server tập trung **`technova-core-srv`** để làm việc,
commit code và huấn luyện mô hình dữ liệu.

**Anh Hưng** là Tech Lead/Sysadmin và làm việc từ xa. Anh chỉ dùng **terminal qua SSH** để điều hành máy chủ.
Toolkit gom các công việc hằng ngày của anh vào **5 chức năng chính**:

| # | Nhu cầu của anh Hưng | Chức năng | Lệnh tiêu biểu |
|---|---|---|---|
| 1 | Cấp quyền & quản lý nhân viên làm việc | `users` | `users create`, `users setup-dirs`, `users offboard` |
| 2 | Xem ai đang làm gì, ai treo process ngốn CPU/RAM | `monitor` | `monitor who`, `monitor usage`, `monitor hogs`, `monitor kill` |
| 3 | Nhận cảnh báo tức thời khi có sự cố, bất kể ngày đêm | `alert` | `alert check`, `alert setup-telegram`, `alert setup-mail` |
| 4 | Sao lưu an toàn tài sản số của công ty | `backup` | `backup run`, `backup verify`, `backup restore` |
| 5 | Tự động hoá các tác vụ bảo dưỡng hằng ngày | `scheduler` | `scheduler install`, `scheduler maintenance` |

---

## 1. Cài đặt & chạy trên máy Linux khác

📘 **Hướng dẫn chi tiết từng bước (tiếng Việt): [HUONG-DAN-SU-DUNG.md](HUONG-DAN-SU-DUNG.md)**

### Cách A — Docker: dựng sẵn máy chủ `technova-core-srv` (nhanh nhất để demo)
```bash
git clone https://github.com/duylmaoxd/technova-sysadmin-toolkit.git && cd technova-sysadmin-toolkit
docker compose up -d --build          # Ubuntu 24.04 + toolkit + cron/at + SSH server
ssh -p 2222 hung@localhost            # mật khẩu: ADMIN_PASSWORD trong docker-compose.yml (nhớ đổi)
sudo sysadmin --tui
```
Không dùng SSH thì vào thẳng container: `docker exec -it technova-core-srv sysadmin --tui`.
Bản sao lưu, cấu hình, báo cáo và log được giữ trong volume Docker. Dừng bằng `docker compose down`.

### Cách B — Cài trực tiếp lên máy chủ thật / máy ảo Ubuntu Server
```bash
# Mang mã nguồn sang bằng git clone, hoặc dùng file nén tạo bởi ./package.sh:
tar xzf sysadmin-toolkit-1.0.0.tar.gz && cd sysadmin-toolkit
sudo ./install.sh --deps              # cài vào /opt/sysadmin-toolkit, tạo lệnh "sysadmin" + gói phụ thuộc
sudo sysadmin scheduler install       # bật tự động hoá: sao lưu, bảo dưỡng, cảnh báo, báo cáo
```

### Cách C — Chạy tại chỗ, không cài
```bash
chmod +x sysadmin.sh && ./sysadmin.sh
```

**Yêu cầu:** Bash ≥ 4.4 và Ubuntu/Debian/Kali hoặc RHEL/Rocky/Fedora. Để dùng giao diện cần `whiptail` hoặc `dialog`.
Gỡ cài đặt: `sudo ./install.sh --uninstall`; các bản sao lưu vẫn được giữ lại.

### Đóng gói để phát hành
```bash
./package.sh                          # → dist/sysadmin-toolkit-<phiên bản>.tar.gz + .sha256
docker build -t technova/sysadmin-toolkit:1.0 .
```

## 2. Hai chế độ làm việc qua SSH (chuyển qua lại được)

| Chế độ | Lệnh | Khi nào dùng |
|---|---|---|
| **Giao diện (TUI)** | `sudo sysadmin --tui` | Menu bằng phím mũi tên, tham số được hỏi qua hộp thoại |
| **Dòng lệnh (CLI)** | `sysadmin --cli` | Menu văn bản, chọn bằng số |
| | `sysadmin <chức năng> <action> [tham số]` | Gõ nhanh, viết script, chạy từ cron |

- **Đổi chế độ:** trong TUI chọn mục **"Chuyển sang chế độ DÒNG LỆNH (CLI)"**; trong CLI nhấn **`t`**. Muốn lần sau mở thẳng một chế độ thì chạy `sysadmin mode tui|cli|ask`.
- **Mỗi thao tác trên giao diện chạy đúng một lệnh CLI** và hiện lệnh đó ở đầu kết quả (`$ sudo sysadmin monitor hogs`).
- **Thao tác thay đổi hệ thống** luôn hỏi trước: *Chạy thật / Chạy thử (dry-run) / Huỷ*. Chức năng cần root sẽ tự hỏi mật khẩu sudo.
- **Phím:** ↑↓ để chọn, Enter để mở, Esc để quay lại. Với whiptail, đóng hộp kết quả bằng **Tab** rồi Enter, hoặc nhấn Esc.

Tuỳ chọn chung: `-n/--dry-run` (chỉ in lệnh), `-y/--yes` (tự đồng ý), `-a/--ascii` (bỏ dấu khi console thiếu font),
`-u dialog|whiptail`, `-N/--no-color`, `-f <file cấu hình>`. Xem thêm: `sysadmin help <chức năng>`.

---

## 3. Năm chức năng chính

### 3.1. `users` — Quản lý nhân viên & phân quyền
Phòng ban tương ứng với nhóm Linux: `dev` (lập trình viên), `data` (data analyst), `qa` (tester).

| Action | Việc anh Hưng làm |
|---|---|
| `create [csv]` | Tạo tài khoản nhân viên mới hàng loạt từ `config/users.csv`. Mật khẩu ngẫu nhiên được lưu vào file quyền 600, nhân viên **bắt buộc đổi** ở lần đăng nhập đầu |
| `setup-dirs` | Tạo `/srv/technova/{dev,data,qa}` (quyền **2770 + SGID**: chỉ người trong phòng ban vào được) và `chung/` (quyền **1777 + sticky**) |
| `add` · `remove` · `lock` · `unlock` · `passwd` | Quản lý từng tài khoản |
| `sudo <user> grant\|revoke` | Cấp hoặc thu hồi quyền quản trị |
| `kick <user>` | Ngắt mọi phiên SSH và tiến trình của một nhân viên |
| **`offboard <user>`** | Nhân viên nghỉ việc: khoá tài khoản (chặn cả SSH key) → ngắt phiên → thu hồi sudo → xoá crontab → **lưu trữ thư mục home** |
| `policy` · `set-policy` | Xem và áp dụng chính sách mật khẩu (`login.defs`, `chage`, `pwquality`) |
| **`audit`** | Kiểm tra bảo mật 10 mục: UID 0, mật khẩu rỗng hoặc không hết hạn, quyền `/etc/shadow`, `sudoers`, NOPASSWD, quyền home, file ai cũng ghi được, SUID, cấu hình SSH |
| `perm <đường dẫn>` | Giải thích quyền rwx, số octal, SUID/SGID/sticky |
| **`demo`** / `demo-clean` | Dựng toàn bộ kịch bản (nhân viên, phòng ban, thư mục) rồi **tự thử quyền truy cập** |

### 3.2. `monitor` — Giám sát tài nguyên & hoạt động nhân viên
| Action | Mô tả |
|---|---|
| **`who`** | Ai đang đăng nhập, từ IP nào, đang chạy lệnh gì (`w`), mỗi người mấy phiên, lịch sử đăng nhập (`last`, `lastb`) |
| **`usage`** | Tổng CPU/RAM **theo từng nhân viên** |
| `top [n] [cpu\|mem]` | Top tiến trình, kèm người chạy |
| **`hogs`** | Tìm process "treo" vượt ngưỡng (mặc định ≥ 90% CPU hoặc ≥ 30% RAM), hiện cả dòng lệnh đầy đủ |
| `renice <pid>` · `kill <pid>` | Hạ độ ưu tiên (mềm mỏng) hoặc dừng tiến trình gây sự cố (có xác nhận, chặn PID 1) |
| `overview` · `memory` · `disk` · `logs` · `auth` | Sức khoẻ máy chủ, log lỗi, các IP dò mật khẩu SSH |
| **`troubleshoot`** | Chẩn đoán sự cố theo 10 bước, kèm gợi ý xử lý |
| `report` · `watch` · `history` | Báo cáo HTML có biểu đồ, bảng theo dõi trực tiếp (nhấn q để thoát), lịch sử số liệu |

### 3.3. `alert` — Cảnh báo sự cố tức thời
`alert check` chạy **mỗi 5 phút** (qua cron hoặc systemd timer) và kiểm tra:
- **CPU, RAM và ổ đĩa** có vượt ngưỡng không;
- **process ngốn tài nguyên**, kèm tên nhân viên và lệnh đang chạy;
- **dịch vụ systemd** có bị chết không;
- **đăng nhập SSH thất bại** ≥ 10 lần trong 10 phút (nghi bị dò mật khẩu).

Cách gửi cảnh báo:
- Gửi qua **email** (msmtp, Gmail App Password) và **Telegram** (nhận ngay trên điện thoại).
- Có **cooldown 30 phút** để không spam lúc nửa đêm.
- Hết sự cố thì tự gửi tin **"đã ổn định"**.

Các lệnh liên quan: `setup-telegram` · `setup-mail` · `test` · `status` · `set-threshold CPU|MEM|DISK|HOG_CPU|HOG_MEM <%>` ·
**`stress [giây]`** (tạo tải giả để demo cảnh báo) · `history`.

### 3.4. `backup` — Sao lưu an toàn tài sản số
Mặc định sao lưu `/srv/technova` (dự án), `/home` (nhân viên) và `/etc` (cấu hình). Một lần `backup run` gồm các bước:
1. `flock` chống chạy trùng;
2. nén `tar.gz`;
3. kiểm tra file nén;
4. tạo **SHA-256**;
5. **xoay vòng, giữ 7 bản** mới nhất;
6. (tuỳ chọn) **rsync bản sao ra máy khác** (`BACKUP_REMOTE`);
7. ghi lịch sử, và **gửi cảnh báo nếu thất bại**.

Các lệnh khác: `list` · `verify <file>` · `restore <file> [thư mục]` · `rotate` · `history`.

### 3.5. `scheduler` — Tự động hoá bảo dưỡng
`scheduler install` ghi một **khối lịch riêng** vào crontab của root. Khối này cài lại hay gỡ đi đều không ảnh hưởng job khác:

| Giờ chạy | Việc tự động |
|---|---|
| 02:00 hằng ngày | `backup run` — sao lưu |
| 03:30 hằng ngày | **`scheduler maintenance`**: dọn file tạm cũ trong /tmp và /var/tmp, giữ log journald 30 ngày, dọn cache gói, xoá core dump, xoay vòng backup, báo nếu máy cần khởi động lại |
| mỗi 5 phút | `alert check` — phát hiện sự cố và cảnh báo |
| 07:00 thứ Hai | `monitor report` — báo cáo tuần |

Các lệnh khác: `list` · `remove` · `add "<lịch>" "<lệnh>"` · **`explain "<biểu thức cron>"`** (giải thích bằng tiếng Việt) ·
`at` / `at-list` / `at-remove` (hẹn chạy một lần) · `log` · `timers-install` / `timers-remove` (dùng systemd timer thay cho cron).

---

## 4. Kịch bản demo (~10 phút): "Một ngày làm việc từ xa của anh Hưng"

| # | Tình huống | Thao tác (SSH vào technova-core-srv) |
|---|---|---|
| 1 | Sáng: 7 nhân viên mới vào làm | `sudo sysadmin --tui` → **users → demo**: tạo tài khoản, phòng ban dev/data/qa, thư mục `/srv/technova`, tự thử quyền |
| 2 | Kiểm tra an ninh tài khoản | **users → audit** |
| 3 | Data Analyst chạy mô hình bị treo, máy chậm | Mô phỏng: `sudo -u cuonglv bash -c 'while :; do :; done' &` → **monitor → usage** (thấy cuonglv chiếm 100% CPU) → **monitor → hogs** → **renice** hoặc **kill** |
| 4 | Nửa đêm có sự cố | `sudo sysadmin alert stress 30` → điện thoại nhận tin Telegram / email cảnh báo, sau đó nhận tin "đã ổn định" |
| 5 | Bảo vệ tài sản số | `sudo sysadmin backup run` → `backup verify` → `backup restore ... /tmp/restore` |
| 6 | Bật chế độ "tự lái" | `sudo sysadmin scheduler install` → `crontab -l` → `sysadmin scheduler explain "30 3 * * *"` → `scheduler maintenance` |
| 7 | Một nhân viên nghỉ việc | **users → offboard binhtt** (khoá, ngắt phiên, thu hồi quyền, lưu trữ home) |
| 8 | Chuyển sang CLI để làm nhanh | Mục "Chuyển sang chế độ CLI" → `monitor who`, `monitor report` (mở file HTML trong `reports/`) |
| 9 | Dọn dẹp sau demo | `sudo sysadmin users demo-clean` · `sudo sysadmin scheduler remove` |

---

## 5. Cấu trúc mã nguồn

```
sysadmin-toolkit/
├── sysadmin.sh          # điểm vào: tuỳ chọn (getopts), chọn chế độ, bẫy lỗi (trap)
├── install.sh           # cài/gỡ vào /opt, lệnh "sysadmin", bash-completion, gói phụ thuộc
├── lib/
│   ├── common.sh        # màu, log (file + journald), dry-run, xác nhận, distro, cấu hình, registry
│   ├── cli.sh           # chế độ dòng lệnh: help tự sinh, chạy lệnh trực tiếp, menu văn bản
│   └── tui.sh           # chế độ giao diện: dialog/whiptail
├── modules/
│   ├── users.sh         # 1. Nhân viên & phân quyền
│   ├── monitor.sh       # 2. Giám sát
│   ├── alert.sh         # 3. Cảnh báo
│   ├── backup.sh        # 4. Sao lưu
│   └── scheduler.sh     # 5. Tự động hoá
├── config/
│   ├── toolkit.conf     # tên công ty, phòng ban, ngưỡng, lịch cron, email/Telegram...
│   └── users.csv        # danh sách nhân viên TechNova
├── systemd/             # mẫu .service/.timer (cảnh báo 5 phút, sao lưu 02:00)
├── Dockerfile · docker-compose.yml · docker/entrypoint.sh   # đóng gói thành máy chủ technova-core-srv
├── package.sh           # đóng gói file .tar.gz để mang sang máy khác
├── HUONG-DAN-SU-DUNG.md # hướng dẫn sử dụng chi tiết
└── logs/  reports/      # log hoạt động, báo cáo HTML, metrics.csv, lịch sử backup
```

Mỗi chức năng **tự khai báo** các action của nó (`register_module`, `register_action`), nên trang help, menu CLI và giao diện TUI
đều được sinh tự động. Muốn thêm chức năng mới, chỉ cần tạo thêm một file trong `modules/`.

### Kỹ thuật Bash được sử dụng (cho phần lý thuyết của báo cáo)
| Kỹ thuật | Ví dụ trong code |
|---|---|
| `set -Eeuo pipefail`, `trap ERR/EXIT/INT` | `sysadmin.sh`: dừng khi có lỗi, báo dòng lỗi, dọn file tạm, Ctrl+C an toàn |
| `getopts` + tuỳ chọn dài | `sysadmin.sh main()` |
| Hàm, `local`, mã thoát, `return` và `exit` | toàn bộ |
| Mảng & mảng kết hợp (`declare -A`) | registry chức năng trong `lib/common.sh` |
| Mở rộng tham số, regex `[[ =~ ]]` | kiểm tra username, cron, PID |
| Here-doc, `< <(...)`, `mapfile`, `read -a` | đọc CSV nhân viên, crontab |
| `awk` tổng hợp dữ liệu | `monitor usage` (cộng dồn CPU/RAM theo user) |
| Tiến trình nền, `wait`, `timeout` | `alert stress` |
| `flock` chống chạy trùng | `backup run` |
| Dry-run: hàm `run` bọc mọi lệnh thay đổi hệ thống | `lib/common.sh` |
| `logger` → journald/syslog | `journalctl -t sysadmin-toolkit` |

## 6. An toàn & lưu ý
- **Demo trên máy ảo Ubuntu Server.** Mọi thao tác thay đổi hệ thống đều hỏi xác nhận và có thể **chạy thử bằng `--dry-run`**.
- **Toolkit tự giới hạn phạm vi:** chỉ xoá, khoá, kick hoặc offboard tài khoản nhân viên (UID ≥ 1000), và không bao giờ kill PID 1.
- **Khi cài vào `/opt`**, mã nguồn thuộc root vì cron chạy nó với quyền root.
- **Mật khẩu email và token Telegram** nằm trong `config/`. Nên `chmod 640 config/toolkit.conf` và không đưa lên git (xem `.gitignore`).

| Vấn đề | Cách xử lý |
|---|---|
| Console tty hiện chữ tiếng Việt bị lỗi | Thêm `--ascii`, hoặc SSH vào từ terminal có font UTF-8 |
| Không gửi được email | Chạy `sysadmin alert setup-mail`. Với Gmail cần bật xác minh 2 bước và dùng **Mật khẩu ứng dụng**; xem `logs/msmtp.log` |
| Telegram | Tạo bot với @BotFather, nhắn bot một tin, lấy chat id tại `https://api.telegram.org/bot<TOKEN>/getUpdates`, rồi chạy `sysadmin alert setup-telegram` |
| `at` hoặc cron không chạy | `sudo systemctl enable --now atd cron` |

## 7. Đã kiểm thử
- **Kali Linux** (user thường): 50/50 lệnh chạy không lỗi (chế độ đọc và dry-run). Giao diện whiptail hoạt động, chuyển TUI ⇄ CLI được.
- **Container Ubuntu 24.04** (hostname `technova-core-srv`, root): 50/50 lệnh không lỗi. Các luồng sau chạy thật thành công:
  - demo phòng ban (6/6 phép thử quyền đúng);
  - phát hiện và kill process treo của nhân viên;
  - kick, offboard;
  - cảnh báo kèm cooldown;
  - backup có `/srv/technova`;
  - cài cron và chạy bảo dưỡng (đã xoá đúng file tạm cũ);
  - dọn demo.
- **Docker**: build image, `docker compose up`, SSH vào cổng 2222 bằng tài khoản `hung`, rồi chạy `users create`, `monitor who`, `backup run` đều thành công.
- **shellcheck**: không còn cảnh báo.
- Riêng `monitor renice` trong container báo *Operation not permitted*, vì Docker không cấp quyền CAP_SYS_NICE. Trên máy chủ thật, chạy bằng sudo sẽ hoạt động.
