# Những phần BẠN cần bổ sung vào báo cáo

Báo cáo `bao-cao.tex` → `bao-cao.pdf` đã viết đủ lý thuyết, thiết kế, hiện thực, workflow demo, kiểm thử và hướng dẫn sử dụng.
Còn 3 việc chỉ bạn làm được, vì cần máy chủ thật và thông tin của nhóm:

1. **Thông tin nhóm** — sửa đầu tệp `bao-cao.tex`, mục `THÔNG TIN NHÓM`: tên trường, giảng viên, lớp, họ tên + MSSV, tháng nộp.
2. **31 ảnh demo** — xem bảng bên dưới.
3. **Số liệu vận hành thực tế** — các ô vàng `[điền: …]` trong PDF (tìm `\dien{` trong `bao-cao.tex`).

Sau khi thêm ảnh hoặc sửa nội dung, biên dịch lại:
```bash
cd docs/bao-cao && ./build.sh        # có XeLaTeX thì dùng luôn, không có thì tự chạy bằng Docker
```

---

## 1. Cách thêm ảnh

- Chụp màn hình (PNG), đặt **đúng tên** như cột "Tên tệp" vào thư mục `docs/bao-cao/hinh/`.
- Chạy lại `./build.sh`: khung vàng "CHÈN ẢNH" tự được thay bằng ảnh. Chưa có ảnh nào thì khung vàng vẫn giữ chỗ, báo cáo vẫn biên dịch được.
- Mẹo chụp terminal: phóng chữ ≥ 14pt, cửa sổ khoảng 100×30, nền sáng hoặc tối đều được; cắt bớt phần thừa.
- Ảnh điện thoại (Telegram, Google Drive) chụp dọc là được; báo cáo tự thu nhỏ còn nửa trang.

## 2. Danh sách 31 ảnh

Cột "Bước" là bước tương ứng trong [`docs/KICH-BAN-DEMO.md`](../KICH-BAN-DEMO.md), nên có thể chụp luôn trong lúc tập demo.

| # | Tên tệp | Bước | Máy | Chụp gì |
|---|---|---|---|---|
| 1 | `01-install-server.png` | 1.2 | Laptop 1 (SSH vào máy chủ) | `sudo ./install.sh --server`: phần câu hỏi và dòng "Máy chủ đã sẵn sàng" |
| 2 | `02-list-timers.png` | 7.1 | Máy chủ | `systemctl list-timers 'toolkit-*'` — **cột LAST phải có giá trị** (chụp sau vài ngày chạy) |
| 3 | `03-telegram-test.png` | 1.3 | Điện thoại | Tin thử sau `sudo sysadmin alert test` |
| 4 | `04-cloud-setup.png` | 1.4 | Máy chủ | `sudo sysadmin backup cloud-status` ("remote gdrive sẵn sàng") |
| 5 | `05-ssh-tu-xa.png` | 2.1–2.2 | Laptop 1 | `ssh hungnv@<IP>` rồi `hostnamectl; uptime` |
| 6 | `06-tui-main.png` | 2.3 | Laptop 1 | `sudo sysadmin --tui`: menu 5 chức năng |
| 7 | `07-users-list.png` | 3.1 | Laptop 1 | `sudo sysadmin users list` |
| 8 | `08-phan-quyen.png` | 3.3–3.4 | Laptop 2 (cuonglv) | `ls /srv/technova/dev` bị từ chối; `ls -l /srv/technova/data` thấy nhóm `data` |
| 9 | `09-users-audit.png` | 3.5 | Laptop 1 | `sudo sysadmin users audit` (phần tổng kết) |
| 10 | `10-monitor-who.png` | 4.2 | Laptop 1 | `sysadmin monitor who` thấy cuonglv và IP Laptop 2 |
| 11 | `11-monitor-hogs.png` | 4.3 | Laptop 1 | `sysadmin monitor hogs` bắt được `train_model.py` |
| 12 | `12-alert-check.png` | 5.1 | Laptop 1 | `sudo sysadmin alert check` báo process ngốn tài nguyên |
| 13 | `13-telegram-canh-bao.png` | 5.1 | Điện thoại | Tin cảnh báo vừa nhận |
| 14 | `14-telegram-on-dinh.png` | 5.3 | Điện thoại | Tin "ĐÃ ỔN ĐỊNH" |
| 15 | `15-backup-run.png` | 6.1 | Laptop 1 | `sudo sysadmin backup run` (có dòng "Đã tải lên Google Drive") |
| 16 | `16-drive-backups.png` | 6.2 | Điện thoại / trình duyệt | Thư mục `TechNova-Server/technova-core-srv/backups` có nhiều bản |
| 17 | `17-backup-restore.png` | 6.3–6.4 | Laptop 1 | `backup verify` + `backup restore` + `cat` ra `model v1` |
| 18 | `18-systemctl-cat.png` | 7.2 | Laptop 1 | `systemctl cat toolkit-backup.service toolkit-backup.timer` |
| 19 | `19-journalctl-backup.png` | 7.3 | Laptop 1 | `journalctl -u toolkit-backup --since "3 days ago" \| tail -20` |
| 20 | `20-offboard.png` | 8.2 | Laptop 1 | `sudo sysadmin users offboard binhtt` (5 bước) |
| 21 | `21-laptop2-bi-ngat.png` | 8.2–8.3 | Laptop 2 | Phiên binhtt bị đóng; `ssh binhtt@<IP>` sau đó thất bại |
| 22 | `22-ssh-do-mat-khau.png` | 8.4 | Laptop 2 | Vòng lặp `ssh` thử nhiều tài khoản, các lần "Permission denied" |
| 23 | `23-alert-security.png` | 8.6 | Laptop 1 | `sudo sysadmin alert security`: dò mật khẩu, dò tên tài khoản, NGHI BỊ CHIẾM TÀI KHOẢN, ĐÃ TỰ ĐỘNG CHẶN IP |
| 24 | `24-telegram-tan-cong.png` | 8.6 | Điện thoại | Tin [TẤN CÔNG] |
| 25 | `25-ssh-bi-chan.png` | 8.7 | Laptop 2 | `ssh cuonglv@<IP>` treo rồi hết thời gian chờ |
| 26 | `26-alert-banned.png` | 8.8 | Laptop 1 | `sudo sysadmin alert banned` + `sudo iptables -S INPUT \| grep toolkit` |
| 27 | `27-logcheck.png` | 8.9 | Laptop 1 | `sudo sysadmin monitor logcheck 1`: mục SSH thất bại và thành công |
| 28 | `28-alert-history.png` | 9.1 | Laptop 1 | `sudo sysadmin alert history` |
| 29 | `29-report-html.png` | 9.4 | Trình duyệt | Báo cáo HTML của `sudo sysadmin monitor report` (có biểu đồ) |
| 30 | `30-drive-logs.png` | 9.3 | Điện thoại / trình duyệt | Thư mục `TechNova-Server/technova-core-srv/logs` |
| 31 | `31-test-75-pass.png` | 10 | Laptop 1 | Bộ test trong Docker, dòng "KẾT QUẢ: 75/75 PASS" |

**Lưu ý thứ tự chụp:** ảnh 2, 16, 19, 28, 29, 30 cần máy chủ đã **tự chạy vài ngày** mới có nhiều dữ liệu. Các ảnh còn lại chụp được ngay trong buổi tập demo.

## 3. Số liệu cần điền (ô vàng `[điền: …]`)

| Chỗ trong báo cáo | Cần điền | Lấy từ đâu (chạy trên máy chủ) |
|---|---|---|
| Bảng 5.1 "Thiết bị triển khai" | Cấu hình máy chủ (Ubuntu, CPU, RAM, ổ); IP Laptop 1 và Laptop 2; loại mạng | `hostnamectl`, `lscpu \| head`, `free -h`, `df -h /`, `hostname -I` |
| Mục 5.2, bước 5 | Số ngày máy tự chạy | Ngày bắt đầu → ngày demo |
| Mục 6.1 | Máy và thời gian vận hành | như trên |
| Bảng 6.2 "Kết quả vận hành thực tế" — thời gian vận hành | Số ngày, từ ngày … đến ngày … | |
| — số lần `alert check` đã chạy | | `journalctl -u toolkit-monitor --since "7 days ago" \| grep -c "Finished"` |
| — số bản sao lưu / gói log trên Drive | | `sudo sysadmin backup cloud-list` |
| — số cảnh báo đã gửi | | `sudo sysadmin alert history` |
| — số lần đăng nhập SSH thất bại | | `sudo sysadmin monitor logcheck 168` (168 giờ = 7 ngày) |
| — số IP bị chặn | | `sudo sysadmin alert banned` |
| — sự cố thật phát hiện được | Mô tả ngắn, nếu có | `sudo sysadmin alert history` |

Điền xong, xoá lệnh `\dien{...}` và gõ số thật vào chỗ đó, ví dụ `\dien{số ngày}` → `7`.
