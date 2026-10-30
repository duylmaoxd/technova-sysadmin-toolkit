# KỊCH BẢN DEMO — LinuxAdmin Toolkit trên máy chủ thật (TechNova Solutions)

> **Chủ đề:** *"Một ngày làm việc từ xa của anh Hưng — Tech Lead của TechNova"*
> **Điểm khác biệt:** toolkit chạy trên **một máy Ubuntu thật** đã tự vận hành nhiều ngày trước buổi bảo vệ.
> Thầy thấy user thật đăng nhập từ máy khác, process thật, tấn công SSH thật từ máy khác, cảnh báo tới điện thoại thật,
> bản sao lưu nằm trên Google Drive thật.
> **Thời lượng:** khoảng 15 phút demo, cộng 2 phút trình bày kết quả vận hành.

---

## 0. Bố trí thiết bị và vai trò

| Thiết bị | Vai trò | Ai cầm |
|---|---|---|
| **Máy Ubuntu thật** (PC hoặc laptop cũ, cắm điện + mạng) | `technova-core-srv` — máy chủ công ty | Đặt trên bàn, không ai gõ trực tiếp |
| **Laptop 1** (Kali) nối máy chiếu | **Anh Hưng** — quản trị từ xa, chỉ dùng SSH | Người 1 (trình bày) |
| **Laptop 2** (hoặc điện thoại có Termux) | **Nhân viên** (cuonglv, binhtt) và **kẻ tấn công** | Người 2 |
| **Điện thoại** | Nhận cảnh báo Telegram, mở Google Drive | Người 1 |

Ba máy cùng một mạng Wi-Fi (tốt nhất: phát Wi-Fi từ điện thoại của nhóm để không phụ thuộc mạng phòng học),
hoặc cùng một mạng Tailscale.

**Quan trọng về IP:** `IDS_WHITELIST` chỉ chứa IP của **Laptop 1**; **không** chứa IP của Laptop 2 và **không** chứa cả dải mạng.
Như vậy khi Laptop 2 tấn công thì nó bị chặn, còn anh Hưng vẫn làm việc bình thường.

---

## 1. Một tuần trước buổi bảo vệ — triển khai và để máy tự chạy

Làm một lần:

| # | Việc | Lệnh |
|---|---|---|
| 1 | Tải mã nguồn về máy chủ | `git clone https://github.com/duylmaoxd/technova-sysadmin-toolkit.git && cd technova-sysadmin-toolkit` |
| 2 | Triển khai — chạy **từ Laptop 1 qua SSH** để toolkit tự whitelist IP của Laptop 1 | `sudo ./install.sh --server` |
| 3 | Nhận cảnh báo trên điện thoại | `sudo sysadmin alert setup-telegram` → `sudo sysadmin alert test` |
| 4 | Google Drive | trên Laptop 1: `rclone authorize "drive"` → trên máy chủ: `sudo sysadmin backup cloud-setup` |
| 5 | Tạo nhân viên và thư mục dự án | `sudo sysadmin users create` · `sudo sysadmin users setup-dirs` |
| 6 | Lưu lại mật khẩu tạm của `hungnv`, `cuonglv`, `binhtt` | in ra sau `users create` |
| 7 | Kiểm tra lịch tự động | `systemctl list-timers 'toolkit-*'` → 4 timer |

Sau đó **để máy chạy liên tục 3–7 ngày**; các thành viên thỉnh thoảng SSH vào bằng tài khoản nhân viên để làm việc.
Mỗi đêm toolkit tự sao lưu, tải log lên Drive và bảo dưỡng; mỗi 5 phút tự kiểm tra tài nguyên và phát hiện tấn công.
Đây là số liệu "vận hành thực tế" trình bày ở bước 9.

> Nếu mạng nhà có IP public, có thể (tuỳ chọn) port-forward cổng 22 vào máy chủ vài ngày để ghi nhận các lần dò mật khẩu
> thật từ Internet. Chỉ làm khi đã bật `AUTO_BAN`, mọi tài khoản dùng mật khẩu mạnh, và tắt port-forward khi xong.

### Kiểm tra ngày hôm trước (D-1)

- [ ] `systemctl list-timers 'toolkit-*'`: 4 timer có cột LAST (đã từng chạy)
- [ ] `sudo sysadmin backup cloud-list`: có bản sao lưu và gói log của các đêm trước
- [ ] `sudo sysadmin alert test`: điện thoại nhận được tin
- [ ] Laptop 2 SSH vào được bằng `cuonglv` và `binhtt`; `sudo sysadmin alert banned` không chặn nhầm ai
- [ ] Chạy bộ test trong Docker một lần (bước 10), chụp màn hình 75/75 PASS để dự phòng

---

## 2. Mở đầu — đây là máy chủ thật (1 phút)

**Lời thoại:** *"Đây là máy chủ của TechNova, đã tự vận hành N ngày. Em ngồi ở laptop này và chỉ quản trị qua SSH."*

| Bước | Laptop 1 (anh Hưng) | Kết quả mong đợi |
|---|---|---|
| 2.1 | `ssh hungnv@<IP máy chủ>` | Đăng nhập vào máy khác qua mạng (đề tài 6: remote administration) |
| 2.2 | `hostnamectl; uptime` | Ubuntu thật, đã chạy nhiều ngày |
| 2.3 | `sudo sysadmin --tui` rồi thoát; `sudo sysadmin help` | Hai chế độ: giao diện menu và dòng lệnh |

---

## 3. users — nhân viên làm việc và phân quyền (2 phút)

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 3.1 | **Laptop 1:** `sudo sysadmin users list` | Danh sách nhân viên theo phòng ban |
| 3.2 | **Laptop 2:** `ssh cuonglv@<IP>` | Nhân viên đăng nhập từ máy khác (lần đầu bị buộc đổi mật khẩu tạm) |
| 3.3 | **Laptop 2 (cuonglv, phòng data):** `ls /srv/technova/dev` | *Permission denied* — phòng ban khác không xem được |
| 3.4 | **Laptop 2:** `echo "model v1" > /srv/technova/data/model.txt; ls -l /srv/technova/data` | File thuộc nhóm `data` nhờ SGID |
| 3.5 | **Laptop 1:** `sudo sysadmin users audit` | Kiểm tra UID 0, tài khoản không mật khẩu, sudoers |

**Liên hệ đề tài 5:** `/etc/passwd`, `/etc/shadow`, sudo, `chmod 2770` / `1777`, `chage`.

---

## 4. monitor — có người treo process (2 phút)

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 4.1 | **Laptop 2 (cuonglv):** `bash -c 'exec -a train_model.py bash -c "while :; do :; done"' &` | Process ngốn 100% một nhân CPU |
| 4.2 | **Laptop 1:** `sysadmin monitor who` | Thấy cuonglv đăng nhập từ IP của Laptop 2 |
| 4.3 | **Laptop 1:** `sysadmin monitor usage` rồi `sysadmin monitor hogs` | cuonglv đứng đầu CPU; bắt được `train_model.py` |
| 4.4 | **Laptop 1:** `sudo sysadmin monitor renice <PID>` | Hạ ưu tiên về nice 19 (đề tài 1: CFS, nice) |

---

## 5. alert — cảnh báo tức thời (1,5 phút)

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 5.1 | `sudo sysadmin alert check` | **[FAIL] Process ngốn tài nguyên … cuonglv**; **điện thoại rung**, có tin Telegram |
| 5.2 | `sudo sysadmin monitor kill <PID>` → **y** | Process kết thúc |
| 5.3 | `sudo sysadmin alert check` | Tin **[ĐÃ ỔN ĐỊNH]** tới điện thoại |

**Lời thoại:** *"Lúc 2 giờ sáng cũng vậy: timer chạy mỗi 5 phút, anh Hưng không cần thức canh máy."*

---

## 6. backup — sao lưu lên Google Drive (1,5 phút)

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 6.1 | `sudo sysadmin backup run` | Tạo `.tar.gz` + SHA-256, xoay vòng giữ 7 bản, **tải lên Google Drive** |
| 6.2 | **Điện thoại:** Google Drive → `TechNova-Server/technova-core-srv/backups` | Bản vừa tạo **và các bản của những đêm trước** |
| 6.3 | `sudo sysadmin backup verify <file>` | Checksum khớp |
| 6.4 | `sudo sysadmin --yes backup restore <file> /tmp/restore && cat /tmp/restore/srv/technova/data/model.txt` | In ra `model v1` — đúng file cuonglv vừa tạo |

---

## 7. scheduler + systemd — máy chủ tự vận hành (1,5 phút)

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 7.1 | `systemctl list-timers 'toolkit-*'` | 4 timer; cột LAST cho thấy đã chạy thật nhiều lần |
| 7.2 | `systemctl cat toolkit-backup.service` | Service do toolkit tạo (đề tài 4: **tạo service riêng**) |
| 7.3 | `journalctl -u toolkit-backup --since "3 days ago" \| tail` | Log các đêm sao lưu (đề tài 4 và 9: journald) |
| 7.4 | `sysadmin scheduler explain "30 3 * * *"` | "lúc 03:30 mỗi ngày" (đề tài 10: cron) |

---

## 8. Nhân viên nghỉ việc, rồi máy chủ bị tấn công (3 phút) — phần cao trào

### 8a. Nghỉ việc

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 8.1 | **Laptop 2:** `ssh binhtt@<IP>` (giữ phiên mở) | binhtt đang làm việc |
| 8.2 | **Laptop 1:** `sudo sysadmin users offboard binhtt` | 5 bước: khoá, ngắt phiên, thu sudo, xoá crontab, lưu trữ home — **phiên trên Laptop 2 bị ngắt ngay** |
| 8.3 | **Laptop 2:** `ssh binhtt@<IP>` lần nữa | Không vào được |

### 8b. Có người dò mật khẩu SSH

**Lời thoại:** *"Bây giờ Laptop 2 đóng vai kẻ xấu: thử đăng nhập bằng các tên tài khoản phổ biến với mật khẩu đoán bừa."*

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 8.4 | **Laptop 2:** thử các tài khoản không tồn tại, mỗi lần gõ sai mật khẩu:<br>`for u in admin oracle test guest postgres; do ssh -o NumberOfPasswordPrompts=2 $u@<IP>; done` | Lần nào cũng bị từ chối |
| 8.5 | **Laptop 2:** đăng nhập **đúng** `ssh cuonglv@<IP>` rồi `exit` | Giả định kẻ xấu đã đoán trúng mật khẩu của một nhân viên |
| 8.6 | **Laptop 1:** `sudo sysadmin alert security` | **Dò mật khẩu SSH: N lần từ IP Laptop 2 · Dò tên tài khoản · [FAIL] NGHI BỊ CHIẾM TÀI KHOẢN: cuonglv … · Đã TỰ ĐỘNG CHẶN IP**; điện thoại nhận tin **[TẤN CÔNG]** |
| 8.7 | **Laptop 2:** `ssh cuonglv@<IP>` | Treo rồi hết thời gian chờ: **đã bị tường lửa chặn** |
| 8.8 | **Laptop 1:** `sudo sysadmin alert banned` · `sudo iptables -S INPUT \| grep toolkit` | IP Laptop 2 nằm trong danh sách chặn (đề tài 6: firewall) |
| 8.9 | **Laptop 1:** `sudo sysadmin monitor logcheck 1` | Báo cáo log 1 giờ qua: top IP dò mật khẩu, user bị thử, phiên thành công, sudo (đề tài 9) |
| 8.10 | **Laptop 1:** `sudo sysadmin alert unban <IP Laptop 2>` | Laptop 2 vào lại được |

**Lời thoại:** *"Toolkit vẫn bắt được kiểu dò này kể cả khi máy chủ chỉ cho đăng nhập bằng SSH key,
vì nó đọc cả các dòng `Invalid user` và `[preauth]`, không chỉ `Failed password`."*

---

## 9. Kết quả vận hành thực tế (1 phút)

| Bước | Thao tác | Nội dung trình bày |
|---|---|---|
| 9.1 | `sudo sysadmin alert history` | Số cảnh báo đã gửi trong N ngày, loại sự cố |
| 9.2 | `sudo sysadmin alert banned` | Các IP đã bị chặn (nếu có port-forward: IP thật từ Internet) |
| 9.3 | `sudo sysadmin backup cloud-list` | Mỗi đêm một bản sao lưu + một gói log trên Drive |
| 9.4 | `sudo sysadmin monitor report` → mở file HTML | Biểu đồ CPU/RAM/Disk nhiều ngày |

**Đánh giá lợi ích automation (yêu cầu của đề tài 3):** so sánh làm tay với chạy script —
tạo 7 nhân viên kèm phân quyền (≈ 20 phút → vài giây); sao lưu + kiểm tra + đẩy lên Drive mỗi đêm (≈ 10 phút/ngày → 0);
canh máy 24/7 (không thể làm tay → timer 5 phút).

---

## 10. Kiểm thử tự động (trên Laptop 1, dùng Docker)

```bash
docker run --rm --cap-add SYS_NICE --cap-add NET_ADMIN -v "$PWD/tests:/tests:ro" \
  technova/sysadmin-toolkit:1.0 bash /tests/demo-test.sh --yes
```
Kết quả: **KẾT QUẢ: 75/75 PASS** (khoảng 1 phút). Bộ test tạo và xoá user nên **chỉ chạy trong Docker**, không chạy trên máy chủ thật.

| Nhóm | Mã | Nội dung kiểm chứng |
|---|---|---|
| Nền tảng | T01–T05 | Phiên bản; help đủ 5 chức năng; help module tự sinh; từ chối tham số sai; dry-run không tạo user |
| users | T06–T23 | Tạo 7 nhân viên; đúng phòng ban; hungnv có sudo; bắt buộc đổi mật khẩu; file mật khẩu 600; chạy lại không trùng; dev/data/qa = 2770; chung = 1777; quyền giữa các phòng ban; SGID; sticky; cấp/thu sudo; khoá/mở khoá; audit |
| monitor | T24–T29 | Mô phỏng process treo; usage; hogs; top; who/overview/troubleshoot; renice về 19 |
| alert | T30–T36 | Phát hiện process ngốn tài nguyên; alerts.log; cooldown; kill; "ĐÃ ỔN ĐỊNH"; metrics.csv; đổi ngưỡng |
| IDS | T37–T52 | Baseline; hệ thống sạch không báo nhầm; dò mật khẩu theo IP; **dò SSH khi máy chỉ cho đăng nhập bằng key**; password spraying; đăng nhập sau khi dò; /etc/passwd bị sửa; tài khoản UID 0; process chạy từ /tmp; gửi [TẤN CÔNG]; chống spam; **whitelist theo dải mạng**; logcheck; ban / banned / unban |
| backup | T53–T62 | tar.gz; SHA-256; chứa srv/technova; verify; khôi phục; xoay vòng; Drive sẵn sàng; backup + log lên Drive; cloud-list |
| scheduler | T63–T69 | Khối cron; đủ 5 job; job tuỳ chỉnh thoát `%`; explain; từ chối cron sai; bảo dưỡng; gỡ lịch |
| Nghỉ việc | T70–T73 | kick; offboard khoá tài khoản; lưu trữ home; từ chối offboard root |
| Dọn dẹp | T74–T75 | Xoá nhân viên demo; xoá /srv/technova và các nhóm |

Phần Google Drive trong bộ test dùng remote rclone kiểu local nên không gửi dữ liệu ra Internet.

---

## 11. Bước demo nào ứng với đề tài nào

| Đề tài | Thể hiện ở bước |
|---|---|
| 3. Bash scripting cho SysAdmin | Toàn bộ toolkit; backup (6), tạo user hàng loạt (3), monitor disk (9.4), đánh giá automation (9) |
| 1. Process management | 4 (ps, top, nice, kill, CFS) |
| 4. Boot & systemd | 7 (4 service + timer riêng, journald) |
| 5. User & security | 3, 8a (passwd/shadow, sudo, chmod/chown, chính sách mật khẩu) |
| 6. Network & remote admin | 2, 8b (SSH từ máy khác, firewall iptables) |
| 9. Monitoring & troubleshooting | 4, 8.9, 9.4 (logcheck, journald/rsyslog, báo cáo) |
| 10. Cron & shell automation | 5, 7 (cron/timer, at, cảnh báo email/Telegram) |

---

## 12. Sự cố khi demo và cách xử lý nhanh

| Sự cố | Cách xử lý ngay |
|---|---|
| Mạng phòng học chặn các máy thấy nhau | Phát Wi-Fi từ điện thoại của nhóm, hoặc dùng Tailscale (IP `100.x.x.x`) |
| Lỡ chặn nhầm IP của Laptop 1 | Từ Laptop 2 hoặc ngồi tại máy chủ: `sudo sysadmin alert unban <IP>`; thêm IP vào `IDS_WHITELIST` |
| Bước 8.6 không chặn IP Laptop 2 | Kiểm tra `IDS_WHITELIST` không chứa IP/dải mạng của Laptop 2 và `AUTO_BAN=yes`; nếu đã cảnh báo trong 30 phút trước thì xoá `/opt/sysadmin-toolkit/logs/state/ids-seen` |
| Không có Internet nên không có Telegram/Drive | Cảnh báo vẫn ghi vào `alerts.log` và journald: `sudo sysadmin alert history`; bản sao lưu vẫn ở `/var/backups/sysadmin-toolkit` |
| Máy chủ hỏng hẳn | Dự phòng bằng Docker trên Laptop 1: `docker compose up -d --build` rồi `ssh -p 2222 hung@localhost`, demo lại các bước 3–8 |
| Menu whiptail: Enter không đóng hộp kết quả | Nhấn **Tab** rồi Enter, hoặc **Esc** |
| Chữ tiếng Việt lỗi trên console | `sudo sysadmin --ascii --tui` |

### Dọn dẹp sau buổi bảo vệ
```bash
sudo sysadmin --yes users demo-clean     # xoá nhân viên demo và /srv/technova
sudo ./install.sh --uninstall            # gỡ toolkit (bản sao lưu vẫn giữ lại)
sudo rm -f /etc/ssh/sshd_config.d/10-technova.conf /etc/systemd/logind.conf.d/technova-server.conf
```
