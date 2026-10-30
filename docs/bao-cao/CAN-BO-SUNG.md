# Những phần BẠN cần bổ sung vào báo cáo

1. **Thông tin nhóm:** sửa mục `THÔNG TIN NHÓM` ở đầu `bao-cao.tex` (trường, giảng viên, lớp, họ tên + MSSV, tháng nộp).
2. **14 ảnh demo:** chụp màn hình PNG, đặt **đúng tên** dưới đây vào `docs/bao-cao/hinh/`.
3. **Số liệu thực tế:** các ô vàng `[điền: …]` (tìm `\dien{` trong `bao-cao.tex`, thay bằng số thật).

Biên dịch lại sau khi thêm ảnh: `cd docs/bao-cao && ./build.sh` — khung vàng "CHÈN ẢNH" tự được thay bằng ảnh.

## Danh sách ảnh

Cột "Bước" ứng với [`docs/KICH-BAN-DEMO.md`](../KICH-BAN-DEMO.md), nên chụp luôn khi tập demo.

| Tên tệp | Bước | Chụp gì |
|---|---|---|
| `01-install-server.png` | 1 | `sudo ./install.sh --server`: câu hỏi + dòng "Máy chủ đã sẵn sàng" |
| `02-list-timers.png` | 7.1 | `systemctl list-timers 'toolkit-*'` sau vài ngày (cột LAST có giá trị) |
| `03-phan-quyen.png` | 3.3–3.4 | Laptop 2 (cuonglv): `ls /srv/technova/dev` bị từ chối; `ls -l /srv/technova/data` |
| `04-offboard.png` | 8.2 | `sudo sysadmin users offboard binhtt` |
| `05-monitor-hogs.png` | 4.3 | `sysadmin monitor usage` và `sysadmin monitor hogs` |
| `06-alert-check.png` | 5.1 | `sudo sysadmin alert check` |
| `07-telegram-canh-bao.png` | 5.1 | Điện thoại: tin cảnh báo |
| `08-alert-security.png` | 8.6 | `sudo sysadmin alert security` sau khi Laptop 2 dò mật khẩu |
| `09-telegram-tan-cong.png` | 8.6 | Điện thoại: tin [TẤN CÔNG] |
| `10-alert-banned.png` | 8.8 | `sudo sysadmin alert banned` + `sudo iptables -S INPUT \| grep toolkit` |
| `11-backup-run.png` | 6.1 | `sudo sysadmin backup run` |
| `12-drive-backups.png` | 6.2 | Google Drive: `TechNova-Server/technova-core-srv/backups` |
| `13-journalctl-backup.png` | 7.3 | `journalctl -u toolkit-backup --since "3 days ago" \| tail -20` |
| `14-test-75-pass.png` | 10 | Bộ test Docker: dòng "KẾT QUẢ: 75/75 PASS" |

Ảnh 02, 12, 13 cần máy chủ đã tự chạy vài ngày.

## Số liệu cần điền (bảng "Kết quả vận hành thực tế", mục 5.2)

| Dòng | Lấy từ (chạy trên máy chủ) |
|---|---|
| Máy chủ | `hostnamectl`, `lscpu \| head`, `free -h` |
| Thời gian vận hành | ngày cài → ngày demo |
| Số bản sao lưu / gói log trên Drive | `sudo sysadmin backup cloud-list` |
| Số cảnh báo đã gửi | `sudo sysadmin alert history` |
| Số lần SSH thất bại / số IP bị chặn | `sudo sysadmin monitor logcheck 168` · `sudo sysadmin alert banned` |
