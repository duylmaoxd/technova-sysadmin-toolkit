# KỊCH BẢN DEMO & KIỂM THỬ — LinuxAdmin Toolkit (TechNova Solutions)

> **Chủ đề demo:** *"Một ngày làm việc từ xa của anh Hưng — Tech Lead của TechNova"*
> **Thời lượng:** khoảng 12 phút. Gồm 1 phút chuẩn bị, 10 phút demo trực tiếp và 1 phút chạy kiểm thử tự động.
> **Vai trò:** Người 1 là **anh Hưng**, trình bày và gõ lệnh. Người 2 đóng **nhân viên** (treo process) và theo dõi đồng hồ.

---

## 0. Chuẩn bị (làm trước buổi thuyết trình)

| # | Việc cần làm | Lệnh | Kiểm tra |
|---|---|---|---|
| 1 | Dựng máy chủ giả lập | `docker compose up -d --build` | `docker logs technova-core-srv` có dòng "sẵn sàng" |
| 2 | Mở 2 cửa sổ terminal | **T1**: `ssh -p 2222 hung@localhost` (anh Hưng)<br>**T2**: `docker exec -it technova-core-srv bash` (nhân viên) | Cả hai đều vào được |
| 3 | Phóng to chữ terminal (≥ 16pt), cửa sổ ≥ 100×30 | — | Khán giả ở cuối phòng đọc được |
| 4 | (Tuỳ chọn) Cấu hình Telegram để nhận cảnh báo trên điện thoại | `sudo sysadmin alert setup-telegram` | Điện thoại nhận tin thử |
| 5 | (Tuỳ chọn) Kết nối Google Drive | `rclone authorize "drive"` trên laptop → `sudo sysadmin backup cloud-setup` | `backup cloud-status` báo sẵn sàng |
| 6 | Chụp trạng thái chuẩn cho IDS | `sudo sysadmin alert baseline` | "Đã chụp trạng thái chuẩn" |
| 7 | Chạy thử kiểm thử tự động một lần | xem mục 7 | 73/73 PASS |

> Nếu demo trên VM Ubuntu thay vì Docker: cài bằng `sudo ./install.sh --deps`, phần còn lại giữ nguyên.
> Nếu mạng phòng thuyết trình chặn Docker Hub: build image từ trước và mang theo file `docker save`.

---

## 1. Mở đầu — giới thiệu hai chế độ (1 phút)

**Lời thoại:** *"Anh Hưng làm việc ở nhà, chỉ có terminal SSH vào máy chủ công ty. Anh gõ một lệnh duy nhất là `sysadmin`."*

| Bước | Thao tác (T1) | Kết quả mong đợi |
|---|---|---|
| 1.1 | `sudo sysadmin` → chọn **1** (Giao diện) | Menu chính có 5 chức năng: users, monitor, alert, backup, scheduler |
| 1.2 | Chọn **about** | Bảng: nhu cầu của anh Hưng → 5 chức năng |
| 1.3 | Chọn **cli** (Chuyển sang chế độ DÒNG LỆNH) → nhấn **t** để quay lại | Chuyển qua lại TUI ⇄ CLI không mất trạng thái |

**Nhấn mạnh:** mỗi thao tác trên menu thực chất chạy một lệnh CLI, và lệnh đó được hiện ra ở đầu kết quả.

---

## 2. Chức năng 1 — users: nhân viên mới vào làm (2 phút)

**Lời thoại:** *"Sáng thứ Hai, công ty nhận 7 nhân viên cho 3 phòng ban. Danh sách phòng nhân sự gửi sang dạng CSV."*

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 2.1 | `cat /opt/sysadmin-toolkit/config/users.csv` | 7 dòng: dev / data / qa, hungnv có sudo |
| 2.2 | TUI → **users → demo** → chọn **Chạy thử (dry-run)** | Chỉ in các lệnh `useradd`, `chmod 2770`..., không thay đổi gì |
| 2.3 | Lặp lại, lần này chọn **Chạy thật** | Tạo 7 user, các nhóm và `/srv/technova/{dev,data,qa,chung}` |
| 2.4 | Đọc phần "Bước 3: thử quyền truy cập" | 6 dòng **[OK]**: annv ghi được dev/ nhưng bị từ chối ở data/; cuonglv không xem được dev/; không xoá được file người khác trong chung/ |
| 2.5 | `ls -l /srv/technova` | `drwxrws---` (SGID) và `drwxrwxrwt` (sticky) |
| 2.6 | **users → audit** | Bảng kiểm tra 10 mục, có dòng Tổng kết |

**Giải thích ngắn:** SGID giúp file mới thuộc nhóm phòng ban; sticky bit ngăn xoá file của người khác. Mật khẩu tạm được lưu ở file quyền 600, nhân viên phải đổi khi đăng nhập lần đầu.

---

## 3. Chức năng 2 — monitor: có người treo process (2 phút)

**Lời thoại:** *"10 giờ sáng, cả công ty than máy chủ chậm. Anh Hưng cần biết ai đang làm gì."*

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 3.1 | **(T2 — nhân viên)** `runuser -u cuonglv -- bash -c 'exec -a train_model.py bash -c "while :; do :; done"' &` | Một tiến trình ngốn 100% CPU |
| 3.2 | **(T1)** `sysadmin monitor who` | Ai đang đăng nhập, từ IP nào, đang chạy gì |
| 3.3 | `sysadmin monitor usage` | **cuonglv** đứng đầu với ~100% CPU |
| 3.4 | `sysadmin monitor hogs` | Hiện PID, user cuonglv, lệnh `train_model.py`, kèm gợi ý xử lý |
| 3.5 | `sudo sysadmin monitor renice <PID> 19` | Cột NI đổi từ 0 sang 19: hạ ưu tiên một cách mềm mỏng |

**Chưa kill vội**: giữ nguyên process này để dùng cho phần cảnh báo ở mục 4.

---

## 4. Chức năng 3 — alert: cảnh báo tức thời (2 phút)

**Lời thoại:** *"Nếu chuyện này xảy ra lúc 2 giờ sáng, anh Hưng vẫn được báo ngay, vì cron chạy kiểm tra mỗi 5 phút."*

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 4.1 | `sudo sysadmin alert check` | **[FAIL] Process ngốn tài nguyên: PID … của cuonglv (train_model.py …)**; gửi email/Telegram nếu đã cấu hình |
| 4.2 | `sudo sysadmin alert check` (chạy lại ngay) | "Đã cảnh báo lúc … — chờ đủ 30 phút" (cooldown chống spam) |
| 4.3 | `sudo sysadmin monitor kill <PID>` → xác nhận **y** | `[OK] PID … đã kết thúc` |
| 4.4 | `sudo sysadmin alert check` | "Mọi chỉ số đều dưới ngưỡng" và gửi tin **[ĐÃ ỔN ĐỊNH]** |
| 4.5 | `sysadmin alert history` | Lịch sử cảnh báo và tin "đã ổn định" |

**Phương án thay thế** nếu không mô phỏng được process treo: `sudo sysadmin alert stress 20`, lệnh này tự tạo tải 100% CPU.

### 4b. Có kẻ tấn công máy chủ (2 phút)

**Lời thoại:** *"Đêm qua có người dò mật khẩu SSH, đoán trúng mật khẩu của một nhân viên rồi cài cửa hậu. Toolkit phát hiện thế nào?"*

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 4b.1 | **T2 (kẻ tấn công)**, trên máy host: gõ sai mật khẩu 6 lần `ssh -p 2222 admin@localhost`, `ssh -p 2222 oracle@localhost`... rồi đăng nhập đúng `ssh -p 2222 annv@localhost` | Mỗi lần sai bị từ chối |
| 4b.2 | **T2**, trong container: `useradd -o -u 0 -M backdoor` · `cp /bin/sleep /tmp/kdevtmpfsi && /tmp/kdevtmpfsi 600 &` | Tạo tài khoản UID 0 và "mã độc" chạy từ /tmp |
| 4b.3 | **T1**: `sudo sysadmin alert security` | Danh sách **[WARN] Dò mật khẩu SSH… · Dò tên tài khoản… · [FAIL] NGHI BỊ CHIẾM TÀI KHOẢN: annv… · File quan trọng bị THAY ĐỔI: /etc/passwd · Tài khoản backdoor có UID 0 · Process chạy từ /tmp/kdevtmpfsi**; điện thoại nhận tin **[TẤN CÔNG]** |
| 4b.4 | `sudo sysadmin monitor logcheck 1` | Báo cáo log 1 giờ qua: top IP dò mật khẩu, user bị thử, phiên đăng nhập thành công, sudo, tài khoản mới |
| 4b.5 | `sudo sysadmin alert ban <IP ở bước 4b.3>` → `sudo sysadmin alert banned` | IP bị chặn bằng iptables. Trong Docker, IP này là gateway của mạng Docker — chính là máy host, nên **T1 cũng mất kết nối**: bỏ chặn ngay bằng `docker exec technova-core-srv sysadmin --yes alert unban <IP>` |
| 4b.6 | Dọn: `pkill -f kdevtmpfsi; userdel backdoor; sudo sysadmin alert baseline` | Lần `alert security` kế tiếp: "Không phát hiện dấu hiệu tấn công" |

**Phương án thay thế** nếu không tiện SSH từ ngoài vào: giả lập log dò mật khẩu ngay trong container
`for i in 1 2 3 4 5 6; do logger -p authpriv.notice -t 'sshd[999]' "Failed password for root from 203.0.113.9 port 4$i ssh2"; done`.

---

## 5. Chức năng 4 — backup: sao lưu tài sản số (1,5 phút)

**Lời thoại:** *"Mã nguồn và dữ liệu mô hình là tài sản quý nhất của công ty."*

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 5.1 | `echo "model v1" \| sudo tee /srv/technova/data/model.txt` | Có dữ liệu dự án mẫu |
| 5.2 | `sudo sysadmin backup run` | Tạo file `.tar.gz` và checksum SHA-256, xoay vòng giữ 7 bản |
| 5.3 | `sudo sysadmin backup verify <file>` | Checksum khớp, cấu trúc gzip hợp lệ, đọc được danh sách N mục |
| 5.4 | `sudo sysadmin --yes backup restore <file> /tmp/restore` rồi `cat /tmp/restore/srv/technova/data/model.txt` | In ra `model v1`: khôi phục đúng nội dung |
| 5.5 | (Nếu đã kết nối Drive) `sudo sysadmin backup cloud-list` | Bản sao lưu của bước 5.2 và gói log đã nằm trên Google Drive; mở Drive trên điện thoại cho khán giả xem |

---

## 6. Chức năng 5 — scheduler: máy chủ tự vận hành (1,5 phút)

**Lời thoại:** *"Cuối cùng, anh Hưng bật chế độ tự lái để không phải làm lại mỗi ngày."*

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 6.1 | `sudo sysadmin scheduler install` | Khối lịch gồm 5 job: backup 02:00, upload log 02:30, bảo dưỡng 03:30, cảnh báo + IDS mỗi 5 phút, báo cáo thứ Hai |
| 6.2 | `sudo crontab -l` | Khối nằm giữa `>>> sysadmin-toolkit >>>` và `<<< … <<<` |
| 6.3 | `sysadmin scheduler explain "30 3 * * *"` | "Tóm tắt: lúc 03:30 mỗi ngày" |
| 6.4 | `sudo touch -d '10 days ago' /tmp/old.bin && sudo sysadmin --yes scheduler maintenance` | "Xoá 1 file tạm cũ hơn 7 ngày"; `/tmp/old.bin` không còn |

---

## 7. Kết thúc — nhân viên nghỉ việc & kiểm thử tự động (1,5 phút)

| Bước | Thao tác | Kết quả mong đợi |
|---|---|---|
| 7.1 | `sudo sysadmin users offboard binhtt` | 5 bước: khoá tài khoản, ngắt phiên, thu hồi sudo, xoá crontab, lưu trữ home |
| 7.2 | `sudo sysadmin --yes users demo-clean && sudo sysadmin scheduler remove` | Dọn sạch dữ liệu demo |
| 7.3 | **Kiểm thử tự động** (trên máy host, thư mục mã nguồn):<br>`docker run --rm --cap-add SYS_NICE --cap-add NET_ADMIN -v "$PWD/tests:/tests:ro" technova/sysadmin-toolkit:1.0 bash /tests/demo-test.sh --yes` | Chạy 73 bước, kết thúc bằng **KẾT QUẢ: 73/73 PASS** |

**Lời kết:** *"Toàn bộ các bước vừa demo đều được kiểm thử tự động trong 73 bước, và tất cả đều đạt."*

---

## 8. Danh sách 73 test của `tests/demo-test.sh`

| Nhóm | Mã | Nội dung kiểm chứng |
|---|---|---|
| Nền tảng | T01–T05 | Phiên bản; help đủ 5 chức năng; help module tự sinh; từ chối tham số sai; dry-run không tạo user |
| users | T06–T23 | Tạo 7 nhân viên; đúng phòng ban; hungnv có sudo; bắt buộc đổi mật khẩu; file mật khẩu 600; chạy lại không trùng; dev/data/qa = 2770; chung = 1777; annv ghi được dev/; SGID giữ nhóm dev; annv bị chặn ở data/; cuonglv bị chặn ở dev/; sticky chặn xoá file người khác; cấp/thu sudo; khoá/mở khoá; audit có tổng kết |
| monitor | T24–T29 | Mô phỏng process treo; usage xếp cuonglv đầu tiên; hogs bắt được train_model.py; top có tên người chạy; who/overview/troubleshoot chạy được; renice về 19 |
| alert | T30–T36 | Phát hiện process ngốn tài nguyên; ghi alerts.log; cooldown; kill thành công; gửi tin "ĐÃ ỔN ĐỊNH"; ghi metrics.csv; đổi ngưỡng qua cấu hình |
| IDS | T37–T50 | Chụp baseline; hệ thống sạch không báo nhầm; phát hiện dò mật khẩu theo IP, password spraying, đăng nhập sau khi dò, /etc/passwd bị sửa, tài khoản UID 0, process chạy từ /tmp; gửi tin [TẤN CÔNG]; chống spam; logcheck tổng hợp theo IP; ban / banned / unban bằng iptables |
| backup | T51–T60 | Tạo tar.gz; SHA-256 khớp; chứa srv/technova; verify OK; khôi phục đúng nội dung; xoay vòng còn 2 bản; Drive sẵn sàng; backup + checksum lên Drive; gói log lên Drive; cloud-list |
| scheduler | T61–T67 | Có khối cron; đủ 5 job; job tuỳ chỉnh thoát `%`; explain tiếng Việt; từ chối cron sai; bảo dưỡng xoá file cũ; gỡ lịch |
| Nghỉ việc | T68–T71 | kick ngắt hết tiến trình; offboard khoá tài khoản; lưu trữ home; từ chối offboard root |
| Dọn dẹp | T72–T73 | Xoá nhân viên demo; xoá /srv/technova và các nhóm |

Phần Google Drive dùng một remote rclone kiểu **local** (`/tmp/tk-fakedrive`) nên không gửi dữ liệu ra Internet.

Log chi tiết của mỗi lần chạy nằm ở `/tmp/technova-demo-test.log` (trong container hoặc VM).

---

## 9. Sự cố có thể gặp khi demo & cách xử lý nhanh

| Sự cố | Cách xử lý ngay |
|---|---|
| Menu whiptail: Enter không đóng hộp kết quả | Nhấn **Tab** rồi Enter, hoặc **Esc** |
| `renice: Operation not permitted` (Docker) | Chạy container với `--cap-add SYS_NICE` (docker-compose.yml đã có sẵn) |
| Không có mạng nên không gửi được email/Telegram | Vẫn demo được: cảnh báo vẫn ghi vào `alerts.log`; mở `sysadmin alert history` cho khán giả xem |
| Quên PID của process treo | `pgrep -u cuonglv -f train_model` |
| `alert ban` báo lỗi iptables trong Docker | Container cần `--cap-add NET_ADMIN` (docker-compose.yml đã có sẵn) |
| Lỡ chặn IP của chính mình (T1 mất kết nối) | `docker exec technova-core-srv sysadmin --yes alert unban <IP>` |
| Không có Internet để tải lên Drive | Bỏ bước 5.5; bản sao lưu vẫn nằm ở `/var/backups/sysadmin-toolkit`, lỗi ghi ở `logs/rclone.log` |
| Chữ tiếng Việt lỗi trên console | `sudo sysadmin --ascii --tui` |
| Lỡ tay làm hỏng máy demo | `docker compose down -v && docker compose up -d` (khôi phục trong vòng 30 giây) |
