# HƯỚNG DẪN SỬ DỤNG — LinuxAdmin Toolkit (TechNova Solutions)

Tài liệu này hướng dẫn **từng bước** cách cài đặt và sử dụng toolkit trên một máy Linux bất kỳ.
Có 3 cách chạy, tuỳ hoàn cảnh:

| Cách | Khi nào dùng | Mục |
|---|---|---|
| **A. Docker** | Muốn thử ngay, không đụng tới hệ thống thật. Dựng sẵn máy chủ giả lập `technova-core-srv` có SSH | [Mục 1](#1-cách-a--chạy-bằng-docker-khuyên-dùng-để-demo) |
| **B. Cài trực tiếp** | Máy chủ / máy ảo Ubuntu Server thật (giống đề bài) | [Mục 2](#2-cách-b--cài-trực-tiếp-lên-máy-linux) |
| **C. Chạy tại chỗ** | Chỉ xem thử, không cài | [Mục 3](#3-cách-c--chạy-tại-chỗ-không-cài) |

---

## 1. Cách A — Chạy bằng Docker (khuyên dùng để demo)

### Bước 1: Cài Docker trên máy của bạn
```bash
# Ubuntu / Debian / Kali
sudo apt install -y docker.io docker-compose-v2   # hoặc theo hướng dẫn tại docs.docker.com
sudo usermod -aG docker $USER                      # đăng xuất rồi đăng nhập lại để có hiệu lực
```

### Bước 2: Tải mã nguồn
```bash
git clone https://github.com/<tài-khoản>/<tên-repo>.git
cd <tên-repo>
```

### Bước 3: Đổi mật khẩu quản trị
Mở `docker-compose.yml` và đổi dòng sau:
```yaml
ADMIN_PASSWORD: "TechNova@2026"   # ĐỔI mật khẩu này trước khi dùng
```

### Bước 4: Dựng máy chủ `technova-core-srv`
```bash
docker compose up -d --build
docker logs technova-core-srv      # thấy dòng "technova-core-srv sẵn sàng" là xong
```

### Bước 5: Đăng nhập như anh Hưng (Tech Lead) qua SSH
```bash
ssh -p 2222 hung@localhost         # mật khẩu = ADMIN_PASSWORD
sudo sysadmin --tui                # mở giao diện menu
```
Nếu không muốn dùng SSH, có thể vào thẳng container:
```bash
docker exec -it technova-core-srv sysadmin --tui
```
SSH từ máy khác trong mạng LAN: `ssh -p 2222 hung@<IP-máy-chạy-docker>`.

### Bước 6: Dừng / xoá
```bash
docker compose stop                # tạm dừng (giữ nguyên dữ liệu)
docker compose down                # xoá container, GIỮ các volume (backup, cấu hình, báo cáo, log)
docker compose down -v             # xoá cả dữ liệu
```

> **Lưu ý về Docker:**
> - Tài khoản nhân viên tạo bên trong container sẽ mất khi xoá container. Bản sao lưu, cấu hình, báo cáo và log thì được giữ trong volume.
> - Container không có systemd, nên lệnh `scheduler timers-install` không dùng được; hãy dùng `scheduler install` (cron).
> - Lệnh `monitor logs` và `monitor auth` ít dữ liệu hơn máy thật vì không có journald.

---

## 2. Cách B — Cài trực tiếp lên máy Linux

Hỗ trợ: **Ubuntu / Debian / Kali** (khuyên dùng Ubuntu Server 22.04/24.04) và **RHEL / Rocky / AlmaLinux / Fedora**. Yêu cầu Bash ≥ 4.4.

### Bước 1: Mang mã nguồn sang máy đích
Có hai cách:
```bash
# Cách 1: git
git clone https://github.com/<tài-khoản>/<tên-repo>.git && cd <tên-repo>

# Cách 2: file nén (tạo trên máy có mã nguồn bằng ./package.sh → dist/sysadmin-toolkit-1.0.0.tar.gz)
scp dist/sysadmin-toolkit-1.0.0.tar.gz user@may-dich:~
ssh user@may-dich
tar xzf sysadmin-toolkit-1.0.0.tar.gz && cd sysadmin-toolkit
```

### Bước 2: Cài đặt
```bash
chmod +x sysadmin.sh install.sh
sudo ./install.sh --deps           # chép vào /opt/sysadmin-toolkit, tạo lệnh "sysadmin", cài gói cần thiết
```
Sau khi cài, gõ `sysadmin` ở bất kỳ thư mục nào để chạy toolkit.

### Bước 3: Cấu hình (chỉ cần làm một lần)
```bash
sudo nano /opt/sysadmin-toolkit/config/toolkit.conf   # tên công ty, phòng ban, ngưỡng cảnh báo, thư mục sao lưu...
sudo nano /opt/sysadmin-toolkit/config/users.csv      # danh sách nhân viên
sudo sysadmin alert setup-telegram                    # nhận cảnh báo qua Telegram (khuyên dùng)
sudo sysadmin alert setup-mail                        # và/hoặc qua email (Gmail: dùng "Mật khẩu ứng dụng")
```

### Bước 4: Bật tự động hoá
```bash
sudo sysadmin scheduler install    # sao lưu 02:00, bảo dưỡng 03:30, cảnh báo 5 phút/lần, báo cáo thứ Hai
sudo crontab -l                    # kiểm tra
```
Nếu muốn dùng systemd timer thay cho cron: `sudo sysadmin scheduler timers-install`.

### Gỡ cài đặt
```bash
sudo ./install.sh --uninstall      # các bản sao lưu trong /var/backups/sysadmin-toolkit vẫn được giữ
```

---

## 3. Cách C — Chạy tại chỗ, không cài
```bash
cd sysadmin-toolkit
./sysadmin.sh                      # hỏi chọn chế độ
sudo ./sysadmin.sh --tui           # các chức năng quản trị cần quyền root
```

---

## 4. Sử dụng hằng ngày

### 4.1. Hai chế độ làm việc
| Chế độ | Lệnh | Thao tác |
|---|---|---|
| Giao diện (TUI) | `sudo sysadmin --tui` | ↑↓ chọn · Enter mở · Esc quay lại · whiptail: **Tab rồi Enter** để đóng hộp kết quả |
| Menu dòng lệnh | `sudo sysadmin --cli` | Gõ số để chọn · `t` = chuyển sang giao diện · `q` = thoát |
| Lệnh trực tiếp | `sudo sysadmin <chức năng> <action> [tham số]` | Dùng trong script và cron |

- **Chuyển chế độ:** trong giao diện chọn **"Chuyển sang chế độ DÒNG LỆNH (CLI)"**; trong CLI nhấn **`t`**.
- **Ghi nhớ chế độ:** `sysadmin mode tui` để lần sau gõ `sysadmin` là vào thẳng giao diện.
- **Thao tác làm thay đổi hệ thống** luôn hỏi: **Chạy thật / Chạy thử (dry-run) / Huỷ**. Ở dòng lệnh, thêm `--dry-run` để chỉ xem trước.
- **Xem tất cả lệnh:** `sysadmin help` · `sysadmin help users` · `sysadmin topics`.

### 4.2. Bảng tra cứu nhanh theo tình huống
| Tình huống | Lệnh |
|---|---|
| Có nhân viên mới (sửa `users.csv` trước) | `sudo sysadmin users create` |
| Tạo thư mục dự án cho các phòng ban | `sudo sysadmin users setup-dirs` |
| Cấp / thu quyền sudo | `sudo sysadmin users sudo annv grant` / `revoke` |
| Nhân viên quên mật khẩu | `sudo sysadmin users passwd annv` |
| Nhân viên nghỉ việc | `sudo sysadmin users offboard binhtt` |
| Kiểm tra an ninh tài khoản | `sudo sysadmin users audit` |
| Ai đang đăng nhập, đang làm gì? | `sysadmin monitor who` |
| Ai đang dùng nhiều CPU/RAM? | `sysadmin monitor usage` |
| Có process nào bị treo? | `sysadmin monitor hogs` |
| Hạ ưu tiên / dừng process | `sudo sysadmin monitor renice <PID>` / `sudo sysadmin monitor kill <PID>` |
| Máy chậm, chưa rõ vì sao | `sysadmin monitor troubleshoot` |
| Theo dõi trực tiếp | `sysadmin monitor watch` (nhấn q để thoát) |
| Báo cáo HTML | `sysadmin monitor report` → mở file trong `reports/` |
| Kiểm tra sự cố & gửi cảnh báo ngay | `sudo sysadmin alert check` |
| Thử nhận cảnh báo | `sudo sysadmin alert test` · `sudo sysadmin alert stress 30` |
| Đổi ngưỡng cảnh báo | `sudo sysadmin alert set-threshold CPU 85` |
| Sao lưu ngay / kiểm tra / khôi phục | `sudo sysadmin backup run` · `backup verify <file>` · `backup restore <file> /tmp/restore` |
| Bảo dưỡng ngay | `sudo sysadmin scheduler maintenance` |
| Hiểu một biểu thức cron | `sysadmin scheduler explain "30 3 * * *"` |
| Hẹn chạy một lần | `sudo sysadmin scheduler at "now + 1 hour" "sysadmin monitor report"` |

### 4.3. Định dạng file nhân viên `users.csv`
```
# username,họ tên,phòng ban (nhiều phòng ban cách nhau bằng ;),shell,sudo
annv,Nguyen Van An,dev,/bin/bash,no
cuonglv,Le Van Cuong,data,/bin/bash,no
hungnv,Nguyen Van Hung (Tech Lead),dev;data;qa,/bin/bash,yes
```
Mật khẩu tạm của từng người được lưu ở `reports/users-created-<ngày>.csv` (quyền 600).
Nhân viên phải đổi mật khẩu ở lần đăng nhập đầu tiên.

---

## 5. Demo nhanh 5 phút (sau khi đã SSH vào máy chủ)
```bash
sudo sysadmin --yes users demo                              # 1. nhân viên + phòng ban + tự thử quyền
sudo -u cuonglv bash -c 'while :; do :; done' &              # 2. giả lập Data Analyst treo process
sysadmin monitor usage; sysadmin monitor hogs                #    → phát hiện
sudo sysadmin --yes monitor kill <PID>                       #    → xử lý
sudo sysadmin alert stress 20                                # 3. cảnh báo sự cố
sudo sysadmin backup run && sudo sysadmin backup list        # 4. sao lưu
sudo sysadmin scheduler install && sudo crontab -l           # 5. tự động hoá
sudo sysadmin --yes users demo-clean; sudo sysadmin scheduler remove   # dọn dẹp
```

## 6. Xử lý lỗi thường gặp
| Lỗi | Cách xử lý |
|---|---|
| `Chức năng này cần quyền root` | Thêm `sudo` trước lệnh |
| `Không tìm thấy dialog hoặc whiptail` | `sudo apt install whiptail dialog` |
| Chữ tiếng Việt bị lỗi trên console tty | Thêm `--ascii`, hoặc SSH vào từ terminal có font UTF-8 |
| Không nhận được email | Chạy lại `alert setup-mail`, kiểm tra Mật khẩu ứng dụng Gmail, xem `logs/msmtp.log` |
| Không nhận được Telegram | Phải nhắn bot ít nhất một tin trước, kiểm tra chat id, rồi chạy `alert setup-telegram` |
| Cron không chạy | `sudo systemctl enable --now cron` rồi xem `logs/cron.log` |
| SSH vào Docker bị từ chối | Kiểm tra cổng 2222 và `ADMIN_PASSWORD`. Đổi mật khẩu thì cần `docker compose down` rồi `up -d` lại |
