````markdown
# PCAgent — Điều khiển PC Windows từ xa qua Telegram

Script PowerShell duy nhất chạy ngầm trên Windows, nhận lệnh từ Telegram bot để tắt/khởi động lại máy, khóa màn hình, chụp màn hình, hiển thị popup, chạy lệnh PowerShell, xem log, và tự update. Chạy dưới tài khoản SYSTEM qua Scheduled Task tại boot, auto-restart nếu bị kill, không cần cấp quyền admin lần 2 sau khi cài.

Hỗ trợ **1 bot điều khiển nhiều PC** — mỗi PC có tên riêng, khi boot tự gửi thông tin (tên máy, IP nội bộ/ngoài, OS, CPU, RAM, uptime) về Telegram để bạn phân biệt.

---

## Mục lục

1. [Tổng quan kiến trúc](#1-tổng-quan-kiến-trúc)
2. [Tạo Telegram Bot & lấy Chat ID](#2-tạo-telegram-bot--lấy-chat-id)
3. [Cấu hình file pcagent.ps1 & push lên GitHub](#3-cấu-hình-file-pcagentps1--push-lên-github)
4. [Cài đặt trên PC](#4-cài-đặt-trên-pc)
5. [Danh sách lệnh](#5-danh-sách-lệnh)
6. [Ví dụ thực tế](#6-ví-dụ-thực-tế)
7. [Cơ chế persistence & tự khôi phục](#7-cơ-chế-persistence--tự-khôi-phục)
8. [Tự update qua `/update`](#8-tự-update-qua-update)
9. [Gỡ cài đặt](#9-gỡ-cài-đặt)
10. [Cấu trúc file sau khi cài](#10-cấu-trúc-file-sau-khi-cài)
11. [Troubleshooting](#11-troubleshooting)
12. [Bảo mật](#12-bảo-mật)
13. [Câu hỏi thường gặp](#13-câu-hỏi-thường-gặp)

---

## 1. Tổng quan kiến trúc

```
+------------------+         +-------------------+         +------------------+
|   Telegram App   | <-----> |  Telegram Server  | <-----> |   PC của bạn    |
|  (điện thoại/PC) |         |  (api.telegram.org)|         |  (PCAgent chạy) |
+------------------+         +-------------------+         +------------------+
                                                              |
                                                              | Scheduled Task
                                                              | "PCAgent"
                                                              | - User: SYSTEM
                                                              | - Trigger: AtStartup
                                                              | - Auto-restart x999
                                                              v
                                                          C:\ProgramData\PCAgent\
                                                          ├── pcagent.ps1
                                                          ├── config.json
                                                          ├── agent.log
                                                          └── offset.txt
```

**Cơ chế hoạt động:**

- Agent dùng **long-polling**: cứ 30 giây gọi `getUpdates` lên Telegram để hỏi "có tin nhắn mới không?". **Không cần mở port, không cần IP public, không cần server riêng**.
- Bot Token là định danh kênh chat 1-1 giữa bạn và bot. Telegram server lo phần server, agent chỉ cần token là đủ gửi/nhận tin.
- Khi PC boot, Scheduled Task tự khởi động agent. Agent đợi có mạng → gửi thông tin PC về Telegram → bắt đầu polling.
- Khi bạn gửi lệnh từ Telegram → Telegram server lưu tin → agent poll lấy được → thực thi → trả kết quả về Telegram.

---

## 2. Tạo Telegram Bot & lấy Chat ID

### Bước 2.1. Tạo bot

1. Mở Telegram, tìm **@BotFather** (có tích xanh xác minh).
2. Gửi `/newbot`.
3. Đặt tên hiển thị (vd: `My PC Agent`).
4. Đặt username cho bot (vd: `my_pc_agent_bot` — phải kết thúc bằng `_bot`).
5. BotFather trả về **Bot Token** dạng:
   ```
   1234567890:ABCdefGhI-JklMnoPQRstuVwxYZ1234567Ab
   ```
   → **Lưu lại**, đây là thứ cần cho bước cài.

### Bước 2.2. Lấy Chat ID (Private chat — khuyến nghị)

**Private chat** = chat 1-1 giữa bạn và bot. Chat ID dạng số dương (vd: `123456789`).

1. Mở chat với bot vừa tạo.
2. Gửi `/start` (bước này bắt buộc để bot có thể reply cho bạn).
3. Gửi bất kỳ tin nhắn nào (vd: `hello`).
4. Mở trình duyệt, truy cập URL sau (thay `<BOT_TOKEN>` bằng token của bạn):
   ```
   https://api.telegram.org/bot<BOT_TOKEN>/getUpdates
   ```
5. Trong JSON trả về, tìm:
   ```json
   "chat": {
       "id": 123456789,        ← Đây là Chat ID
       "first_name": "Your Name",
       "type": "private"
   }
   ```
6. Chat ID của bạn là `123456789` (dạng số, không có dấu `-`).

### Bước 2.3. Lấy Chat ID (Group chat — nếu muốn bot trong group)

**Group chat** = bot được add vào 1 group chat. Chat ID dạng `-1001234567890` (có prefix `-100`, 13 chữ số).

1. Tạo 1 group mới hoặc dùng group có sẵn.
2. Add bot vào group (Settings → Add members → tìm username bot).
3. Trong group, gửi 1 tin nhắn bất kỳ (vd: `hello`).
4. Truy cập `https://api.telegram.org/bot<BOT_TOKEN>/getUpdates`.
5. Tìm trong JSON:
   ```json
   "chat": {
       "id": -1001234567890,   ← Đây là Group Chat ID (có -100 prefix)
       "title": "My Group",
       "type": "supergroup"
   }
   ```
6. Group Chat ID của bạn là `-1001234567890`.

### Bước 2.4. (Chỉ group) Tắt Privacy Mode

Mặc định bot trong group không thấy message người dùng (Privacy Mode = Enabled). Cần tắt:

1. Mở chat với **@BotFather**.
2. Gửi `/setprivacy`.
3. Chọn bot của bạn.
4. Gửi `Disable`.

> **Khuyến nghị**: Dùng **Private chat** cho đơn giản. Group chat chỉ khi cần nhiều người dùng chung 1 bot.

---

## 3. Cấu hình file pcagent.ps1 & push lên GitHub

> **Bắt buộc**: Nếu bỏ qua bước này, lệnh cài sẽ báo lỗi *"CHUA SUA $RepoUrl"* và thoát.

### Bước 3.1. Tạo GitHub repo

1. Đăng nhập GitHub → New repository.
2. Đặt tên (vd: `remote-control-win11`).
3. Chọn **Public** hoặc **Private** đều được (Bot Token nằm trong `config.json` trên máy bạn, không nằm trong repo).
4. Tick "Add a README file" → Create repository.

### Bước 3.2. Upload file pcagent.ps1

1. Tải file `pcagent.ps1` về máy.
2. Mở bằng **Notepad** hoặc **VSCode** (KHÔNG dùng Word).
3. Tìm dòng 22 (ngay sau dòng `# CONFIG - CHANGE THIS TO YOUR GITHUB RAW URL`):
   ```powershell
   $RepoUrl = 'https://raw.githubusercontent.com/USERNAME/REPO/main'
   ```
4. Sửa `USERNAME/REPO` thành GitHub username và repo name của bạn. Ví dụ repo `https://github.com/minhcuder/remote-control-win11`:
   ```powershell
   $RepoUrl = 'https://raw.githubusercontent.com/minhcuder/remote-control-win11/main'
   ```
   > Lưu ý: KHÔNG có dấu `/` ở cuối URL.
5. Lưu file.
6. Upload file lên GitHub repo (drag-drop vào trang repo → Commit changes).

### Bước 3.3. Lấy raw URL

Trên GitHub, mở file `pcagent.ps1` → click nút **Raw** (góc phải trên). URL trên thanh địa chỉ sẽ có dạng:
```
https://raw.githubusercontent.com/<username>/<repo>/main/pcagent.ps1
```
→ Đây là URL dùng cho lệnh cài ở bước 4.

---

## 4. Cài đặt trên PC

### Bước 4.1. Mở PowerShell

Agent cần cài 1 lần với quyền admin. Có 2 cách:

**Cách A (khuyến nghị — script tự xin admin):**

Mở PowerShell bình thường (Start → gõ `powershell` → Enter). Chạy lệnh cài, script sẽ tự hiện UAC prompt, bạn click Yes là xong.

**Cách B (thủ công):**

Right-click PowerShell → Run as Administrator.

### Bước 4.2. Chạy lệnh cài

**Cách 1 — Truyền sẵn tham số (nhanh nhất):**

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/<username>/<repo>/main/pcagent.ps1'))) -Install -BotToken '123:ABC...' -ChatId '123456789' -PCName 'PC-VanPhong'
```

**Cách 2 — Interactive (script hỏi từng tham số):**

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/<username>/<repo>/main/pcagent.ps1'))) -Install
```
Script sẽ hỏi lần lượt: Bot Token → Chat ID → PC Name.

**Cách 3 — Chạy từ file local** (khi chưa push lên GitHub, hoặc GitHub đang cache):

```powershell
& 'C:\duong\den\pcagent.ps1' -Install -BotToken '123:ABC...' -ChatId '123456789' -PCName 'PC-VanPhong'
```

### Bước 4.3. Tham số

| Tham số | Bắt buộc | Mô tả | Ví dụ |
|---|---|---|---|
| `-Install` | Có | Cài đặt agent | `-Install` |
| `-BotToken` | Có | Bot Token từ BotFather | `'1234567890:ABCdef...'` |
| `-ChatId` | Có | Chat ID của bạn (private hoặc group) | `'123456789'` hoặc `'-1001234567890'` |
| `-PCName` | Có | Tên định danh PC, dùng để phân biệt khi có nhiều PC. Chỉ chữ cái, số, `_`, `-`; 2-32 ký tự; bắt đầu bằng chữ cái. | `'PC-VanPhong'`, `'Laptop-NV'`, `'Server-01'` |

### Bước 4.4. Quá trình cài

Script sẽ:

1. Xin quyền admin (nếu chưa có) → hiện UAC prompt → bạn click Yes.
2. Tạo folder `C:\ProgramData\PCAgent\`.
3. Download/copy script `pcagent.ps1` vào folder.
4. Lưu `config.json` với Bot Token, Chat ID, PC Name, Repo URL.
5. Tạo Scheduled Task tên `PCAgent`:
   - User: `SYSTEM` (toàn quyền)
   - Trigger: `AtStartup` (chạy ngay khi máy boot)
   - Auto-restart 999 lần, mỗi 1 phút nếu bị kill
   - ExecutionTimeLimit = 0 (không timeout)
6. Start task ngay lập tức.
7. **Đợi 20 giây**, đọc log để verify agent đã gửi Telegram thành công.
8. Báo kết quả ra console:
   - `[v] Agent da gui thong bao Telegram thanh cong!` → vào Telegram kiểm tra tin nhắn.
   - `[!] Chua xac nhan duoc...` → xem `C:\ProgramData\PCAgent\agent.log` để debug.

### Bước 4.5. Cài trên PC thứ 2, thứ 3...

Chạy đúng lệnh trên, chỉ đổi `-PCName`. Dùng **cùng Bot Token + Chat ID**. Mỗi PC sẽ có tên riêng, khi boot gửi tin về Telegram với prefix `[PC-Name]`.

---

## 5. Danh sách lệnh

Tất cả lệnh gửi qua chat với bot. Có thể thêm `pcname` để chỉ định 1 PC cụ thể, hoặc bỏ để broadcast tới **tất cả PC**.

### Bảng lệnh đầy đủ

| Lệnh | Mô tả | Cú pháp |
|---|---|---|
| `/shutdown` | Tắt máy ngay (sau 3 giây) | `/shutdown [pc]` |
| `/restart` | Khởi động lại máy | `/restart [pc]` |
| `/lock` | Khóa màn hình (LockWorkStation) | `/lock [pc]` |
| `/status` | Gửi thông tin PC (IP, OS, CPU, RAM, uptime) | `/status [pc]` |
| `/screenshot` | Chụp màn hình hiện tại, gửi ảnh về Telegram | `/screenshot [pc]` |
| `/msg` | Hiển thị popup MessageBox trên màn hình PC | `/msg @pc <nội dung>` |
| `/exec` | Chạy lệnh PowerShell, trả output về Telegram | `/exec @pc <lệnh PowerShell>` |
| `/update` | Tự update `pcagent.ps1` từ GitHub, restart agent | `/update [pc]` |
| `/log` | Xem 50 dòng log cuối của agent | `/log [pc]` |
| `/help` | Hiển thị danh sách lệnh | `/help` |

### Quy ước pcname

**Quy tắc quan trọng để tránh nhập nhầm:**

- **Lệnh không có text args** (`/shutdown /restart /lock /status /screenshot /update /log`): pcname để trực tiếp.
  ```
  /screenshot PC-VanPhong      ← đúng
  /shutdown Server-01          ← đúng
  ```

- **Lệnh có text args** (`/exec /msg`): **BẮT BUỘC dùng `@` trước pcname** để phân biệt pcname với nội dung lệnh.
  ```
  /msg @PC-VanPhong Backup ngay!              ← đúng
  /exec @PC-VanPhong Get-Process | Select -First 5   ← đúng
  /msg PC-VanPhong Backup ngay!               ← SAI: script sẽ hiểu "PC-VanPhong Backup ngay!" là nội dung popup
  ```

- **Bỏ qua pcname** → lệnh broadcast tới **TẤT CẢ PC**.
  ```
  /status              ← tất cả PC reply
  /shutdown            ← tất cả PC tắt máy (cẩn thận!)
  ```

### Output mẫu của `/status`

```
PC-VanPhong - PC da online
|- Ten may: DESKTOP-ABC123
|- IP noi bo: 192.168.1.10
|- IP ngoai: 1.2.3.4
|- OS: Microsoft Windows 11 Pro (10.0.22631)
|- CPU: Intel(R) Core(TM) i7-12700K CPU @ 3.60GHz
|- RAM: 32GB (da dung 45%)
|- Uptime: 0 ngay 5h 23phut
|- Thoi gian: 2026-10-20 15:30:45
```

### Output mẫu của `/help`

```
[PC-VanPhong] Lenh available:
/shutdown [pc]      - Tat may
/restart  [pc]      - Khoi dong lai
/lock     [pc]      - Khoa man hinh
/status   [pc]      - Thong tin PC
/screenshot [pc]    - Chup man hinh
/msg   @pc <text>   - Hien thi popup (can @)
/exec  @pc <cmd>    - Chay lenh PowerShell (can @)
/update  [pc]       - Tu update tu GitHub
/log     [pc]       - Xem 50 dong log cuoi
/help               - Hien thi lenh

[pc] = ten PC (vd: PC-VanPhong), bo qua = TAT CA PC.
/exec va /msg can dung @pc de phan biet voi text lenh.
```

---

## 6. Ví dụ thực tế

### Kịch bản 1: Quản lý 1 PC cá nhân

```
/status                       → Xem PC online không, IP gì
/screenshot                   → Xem màn hình PC đang mở gì
/lock                         → Khóa màn hình từ xa
/shutdown                     → Tắt máy khi ra ngoài quên
/restart                      → Restart khi máy đơ
```

### Kịch bản 2: Quản lý nhiều PC (Office + Home + Server)

Cài trên 3 PC với `-PCName` khác nhau: `PC-Office`, `PC-Home`, `Server-01`.

```
/status                       → Cả 3 PC reply, biết PC nào online
/status Server-01             → Chỉ Server-01 reply
/screenshot PC-Office         → Xem màn hình PC-Office
/shutdown PC-Home             → Tắt PC-Home
/restart Server-01            → Restart Server
/msg @PC-Office Đóng cửa sổ lại!   → Hiện popup trên PC-Office
/exec @Server-01 Get-Service | Where-Object {$_.Status -eq 'Running'} | Select -First 10
                              → Xem 10 service đang chạy trên Server-01
```

### Kịch bản 3: Update agent sau khi sửa code

Bạn sửa file `pcagent.ps1` trên máy, push lên GitHub. Muốn tất cả PC tự update:

```
/update                       → Tất cả PC download bản mới + restart agent
```

Hoặc chỉ update 1 PC:
```
/update Server-01             → Chỉ Server-01 update
```

### Kịch bản 4: Debug khi bot không phản hồi

```
/log                          → Xem 50 dòng log cuối của tất cả PC
/log Server-01                → Xem log Server-01
```

Log sẽ hiển thị các event: boot, sendMessage OK/FAIL, command received, polling status, errors.

### Kịch bản 5: Chạy lệnh PowerShell từ xa

```
/exec @PC-Office Get-Process | Sort-Object CPU -Descending | Select-Object -First 5
                              → Xem 5 process ăn CPU nhất trên PC-Office

/exec @Server-01 Get-EventLog -LogName System -Newest 10 | Format-Table
                              → Xem 10 event log system gần nhất trên Server-01

/exec @PC-Home Get-ChildItem C:\Users | Select-Object Name
                              → Liệt kê user accounts trên PC-Home
```

> **Lưu ý**: `/exec` chạy với quyền SYSTEM. Output giới hạn 3900 ký tự, dài hơn sẽ bị cắt với dấu `...[truncated]`.

---

## 7. Cơ chế persistence & tự khôi phục

### Scheduled Task cấu hình

| Setting | Value |
|---|---|
| Task Name | `PCAgent` |
| User | `SYSTEM` |
| Logon Type | `ServiceAccount` (không cần user login) |
| Run Level | `Highest` (toàn quyền admin) |
| Trigger | `AtStartup` (chạy ngay khi máy boot) |
| Restart Count | `999` (số lần restart tối đa) |
| Restart Interval | `1 minute` (nếu bị kill, restart sau 1 phút) |
| Execution Time Limit | `0` (không bao giờ timeout) |
| Allow Start If On Batteries | `Yes` |
| Dont Stop If Going On Batteries | `Yes` |

### Đặc tính

- **Chạy ngay khi máy boot**, trước khi user login.
- **Không cần user login** để chạy. Bot vẫn nhận lệnh ngay cả khi máy ở màn hình login.
- **Không bị kill khi user logoff** (chạy dưới SYSTEM).
- **Auto-restart**: nếu process bị kill (Task Manager, antivirus, crash), Windows tự khởi động lại sau 1 phút, tối đa 999 lần.
- **Khởi động lại agent khi update**: spawn 1 process riêng để `Stop-ScheduledTask` → `Start-ScheduledTask` (không cần admin).

### Kiểm tra task đang chạy

```powershell
# Xem thông tin task
Get-ScheduledTask -TaskName PCAgent | Get-ScheduledTaskInfo

# Xem process agent đang chạy
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*pcagent.ps1* -Run*' }

# Xem cấu hình task đầy đủ
Get-ScheduledTask -TaskName PCAgent | Format-List *
```

### Xem task trong GUI

`Win+R` → `taskschd.msc` → Task Scheduler Library → `PCAgent`.

### Restart task thủ công

```powershell
Stop-ScheduledTask -TaskName PCAgent
Start-ScheduledTask -TaskName PCAgent
```

---

## 8. Tự update qua `/update`

### Cơ chế

Khi gửi `/update` (hoặc `/update <pcname>`), agent sẽ:

1. Đọc `RepoUrl` từ `config.json` (lúc cài đã lưu tự động).
2. Download `pcagent.ps1` mới từ `<RepoUrl>/pcagent.ps1`.
3. Validate: file mới phải > 1000 bytes (chống download file rỗng/lỗi).
4. Ghi đè file hiện tại `C:\ProgramData\PCAgent\pcagent.ps1`.
5. Gửi tin "Da update xong, dang restart agent..." về Telegram.
6. Spawn 1 process riêng (detached) để:
   - `Stop-ScheduledTask PCAgent` (kill agent cũ)
   - `Start-ScheduledTask PCAgent` (chạy agent mới)
7. Agent mới load code mới, tiếp tục polling.

### Không cần gì thêm

- Không cần admin (task chạy dưới SYSTEM, agent có quyền stop/start chính nó).
- Không cần can thiệp thủ công.
- Bot Token, Chat ID, PC Name, Repo URL được giữ nguyên từ `config.json`.

### Khi nào nên update

- Sửa bug trong `agent.ps1` → push lên GitHub → gửi `/update`.
- Thêm lệnh mới → push → `/update`.
- Đổi cơ chế persistence → push → `/update` (lưu ý: nếu đổi cấu hình Scheduled Task, phải uninstall + install lại, vì `/update` chỉ thay đổi script chứ không tạo lại task).

---

## 9. Gỡ cài đặt

### Cách 1 — Lệnh 1 dòng (cần admin hoặc để script tự xin admin)

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/<username>/<repo>/main/pcagent.ps1'))) -Uninstall
```

### Cách 2 — Chạy từ file local

```powershell
& 'C:\duong\den\pcagent.ps1' -Uninstall
```

### Cách 3 — PowerShell thuần

```powershell
# Stop & xóa scheduled task
Stop-ScheduledTask -TaskName PCAgent -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName PCAgent -Confirm:$false

# Kill process agent đang chạy
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*pcagent.ps1* -Run*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# Xóa folder
Remove-Item -Recurse -Force 'C:\ProgramData\PCAgent'
```

Script uninstall sẽ làm sạch:
- Stop scheduled task
- Unregister scheduled task
- Kill process powershell đang chạy agent
- Xóa toàn bộ folder `C:\ProgramData\PCAgent\` (gồm script, config, log, offset)

---

## 10. Cấu trúc file sau khi cài

```
C:\ProgramData\PCAgent\
├── pcagent.ps1          # Script chính (bản copy từ GitHub)
├── config.json          # BotToken, ChatId, PCName, RepoUrl, Version, InstalledAt
├── offset.txt           # Last update_id của Telegram (tránh đọc lại tin nhắn cũ)
├── agent.log            # Log activity (rotate khi > 2MB, lưu file agent.log.1)
├── agent.log.1          # Log backup (nếu có)
└── _shot.ps1, _msg.ps1, _lock.ps1   # Temp script cho user-session actions
```

### config.json mẫu

```json
{
    "BotToken":  "1234567890:ABCdefGhI-JklMnoPQRstuVwxYZ",
    "ChatId":  "123456789",
    "PCName":  "PC-VanPhong",
    "RepoUrl":  "https://raw.githubusercontent.com/minhcuder/remote-control-win11/main",
    "Version":  "2.0.0",
    "InstalledAt":  "2026-10-20T15:30:45.1234567+07:00"
}
```

### agent.log mẫu

```
[2026-10-20 15:30:46] === Agent khoi dong (PCName=PC-VanPhong, ChatId=123456789, RepoUrl=https://...) ===
[2026-10-20 15:30:46] Wait-Network: bat dau cho mang...
[2026-10-20 15:30:47] Wait-Network: OK co mang (sau 0 lan thu)
[2026-10-20 15:30:48] Telegram sendMessage OK (len=245)
[2026-10-20 15:31:18] Polling OK, 1 cycles, offset=123456790
[2026-10-20 15:31:48] Polling OK, 2 cycles, offset=123456790
[2026-10-20 15:32:05] RECV command: /status
[2026-10-20 15:32:06] Telegram sendMessage OK (len=245)
```

---

## 11. Troubleshooting

### Cài xong không nhận được tin nhắn Telegram

**Bước 1: Kiểm tra log**

```powershell
Get-Content C:\ProgramData\PCAgent\agent.log -Tail 30
```

Hoặc gửi `/log` cho bot (nếu bot đã reply được 2 chiều).

**Bước 2: Xác định lỗi từ log**

| Log line | Nguyên nhân | Cách fix |
|---|---|---|
| `Telegram sendMessage FAIL: The remote server returned an error: (401) Unauthorized` | Bot Token sai | Kiểm tra Bot Token trong `config.json`, đối chiếu với BotFather |
| `Telegram sendMessage FAIL: (400) Bad Request: chat not found` | Chat ID sai | Làm lại bước 2.2 hoặc 2.3 để lấy Chat ID chính xác |
| `Telegram sendMessage FAIL: (400) chat not found` (group) | Bot chưa được add vào group, hoặc Chat ID sai format | Add bot vào group, lấy Chat ID dạng `-100...` |
| `Wait-Network: TIMEOUT sau 30 phut` | PC không có mạng hoặc Telegram bị chặn | Kiểm tra mạng, DNS, firewall |
| `EXIT: Missing config` | `config.json` thiếu field | Mở `config.json` xem có đủ BotToken/ChatId/PCName không |
| `POLL ERROR: ...` | Lỗi khi polling | Xem chi tiết lỗi, thường là network hoặc token |

**Bước 3: Test bot thủ công**

Mở trình duyệt, truy cập:
```
https://api.telegram.org/bot<BOT_TOKEN>/sendMessage?chat_id=<CHAT_ID>&text=test
```
Nếu nhận được tin nhắn trên Telegram → token + chatid đúng, vấn đề ở agent.
Nếu văng JSON lỗi → token hoặc chatid sai.

### Bot không phản hồi lệnh

**Nguyên nhân 1: PC offline hoặc agent bị crash**

Gửi `/status` cho bot. Nếu không reply → PC offline hoặc agent chết. Kiểm tra:
```powershell
Get-ScheduledTask -TaskName PCAgent | Get-ScheduledTaskInfo
```
Xem `LastRunTime` và `LastTaskResult`. Nếu `LastTaskResult` khác `0` hoặc `267011` (task đang chạy) → agent bị lỗi. Khởi động lại:
```powershell
Start-ScheduledTask -TaskName PCAgent
```

**Nguyên nhân 2: Group Privacy Mode chưa tắt (nếu dùng group chat)**

→ Làm lại bước 2.4.

**Nguyên nhân 3: PC offline quá lâu (>24h)**

Telegram `getUpdates` purge update sau 24h. Nếu PC offline quá lâu, sẽ miss lệnh trong khoảng đó. Khi online lại, gửi `/status` để xác nhận PC còn sống.

### `/screenshot` báo "Loi chup man hinh"

Agent chạy as SYSTEM ở session 0, không có quyền truy cập desktop của user. Script có cơ chế fallback: spawn 1 scheduled task con trong user session để chụp. Nếu vẫn fail:

- Cần có user đang login ở console session (không phải RDP).
- Nếu PC ở màn hình lock, screenshot vẫn chụp được nhưng chỉ là màn hình lock.
- Test thủ công: login vào PC, gửi `/screenshot`, kiểm tra log.

### `/lock`, `/msg` không hoạt động

Tương tự `/screenshot` — cần user session active. Nếu không ai login, không có session để lock hay hiển thị popup.

### `/update` không chạy

**Kiểm tra:**

1. `config.json` có field `RepoUrl` đúng chưa:
   ```powershell
   Get-Content C:\ProgramData\PCAgent\config.json | ConvertFrom-Json | Select-Object -ExpandProperty RepoUrl
   ```
2. Test URL: mở trình duyệt truy cập `<RepoUrl>/pcagent.ps1` — phải tải về file script.
3. Nếu RepoUrl sai, sửa trực tiếp `config.json`:
   ```powershell
   $cfg = Get-Content C:\ProgramData\PCAgent\config.json | ConvertFrom-Json
   $cfg.RepoUrl = 'https://raw.githubusercontent.com/USERNAME/REPO/main'
   $cfg | ConvertTo-Json | Out-File C:\ProgramData\PCAgent\config.json -Encoding UTF8
   Start-ScheduledTask -TaskName PCAgent
   ```

### Muốn đổi PC Name

```powershell
$cfg = Get-Content C:\ProgramData\PCAgent\config.json | ConvertFrom-Json
$cfg.PCName = 'Ten-Moi'
$cfg | ConvertTo-Json | Out-File C:\ProgramData\PCAgent\config.json -Encoding UTF8
Start-ScheduledTask -TaskName PCAgent
```

### Muốn đổi Bot Token hoặc Chat ID

```powershell
$cfg = Get-Content C:\ProgramData\PCAgent\config.json | ConvertFrom-Json
$cfg.BotToken = 'NEW_TOKEN'
$cfg.ChatId = 'NEW_CHAT_ID'
$cfg | ConvertTo-Json | Out-File C:\ProgramData\PCAgent\config.json -Encoding UTF8
Start-ScheduledTask -TaskName PCAgent
```

### Agent bị antivirus flag

Một số antivirus (đặc biệt Windows Defender) có thể flag PowerShell script chạy ngầm. Whitelist folder:

```powershell
Add-MpPreference -ExclusionPath 'C:\ProgramData\PCAgent'
Add-MpPreference -ExclusionProcess 'powershell.exe'
```

> Chỉ làm nếu tin tưởng script. Tham khảo thêm ở mục [Bảo mật](#12-bảo-mật).

---

## 12. Bảo mật

### Lớp bảo mật hiện có

1. **Whitelist chat_id**: Chỉ Chat ID trong `config.json` mới có quyền gửi lệnh. Bot Telegram private mặc định chỉ bạn chat được, đã 2 lớp.
2. **Bot Token private**: Bot Token nằm trong `config.json` trên máy bạn, không nằm trong repo GitHub (an toàn khi repo public).
3. **Bot Telegram mode**: Mặc định bot private (chỉ bạn chat được). Nếu dùng group, set Privacy Mode = Disabled chỉ cho phép bot thấy message.

### Rủi ro tiềm ẩn

- **`/exec` nguy hiểm**: có thể chạy bất kỳ lệnh PowerShell nào với quyền SYSTEM (toàn quyền trên máy). Cẩn thận với lệnh xóa file, format, download và execute file lạ. **Không chia sẻ Chat ID cho người khác**.
- **Bot Token lộ**: nếu ai đó có Bot Token + Chat ID của bạn, họ có thể gửi lệnh `/exec` để điều khiển PC. Nếu nghi ngờ token bị lộ, dùng BotFather `/revoke` để tạo token mới, rồi update `config.json`.
- **Repo public**: nếu repo GitHub của bạn public, người khác có thể đọc code agent và biết cơ chế hoạt động. Tuy nhiên họ KHÔNG có Bot Token nên không điều khiển được PC của bạn. Nếu muốn thêm lớp bảo mật, set repo private.

### Khuyến nghị

- Dùng **private chat** (không phải group) cho đơn giản và an toàn.
- Đặt PC Name không reveal thông tin nhạy cảm (tránh `PC-HR-Department`, `Server-Payment`...).
- Thường xuyên check `agent.log` để phát hiện lệnh lạ.
- Nếu dùng `/exec` cho lệnh nhạy cảm, set bot ở chế độ private và không add vào group.

---

## 13. Câu hỏi thường gặp

### Q: Có cần mở port trên router không?

**A:** Không. Agent dùng long-polling (chủ động gọi lên Telegram), không cần mở port, không cần IP public, không cần DDNS.

### Q: Có cần server/VPS chạy 24/7 không?

**A:** Không. Telegram server của họ lo phần server. PC của bạn chỉ cần online khi nào bạn muốn điều khiển. Khi PC offline, bot không nhận lệnh cho PC đó (lệnh sẽ bị Telegram purge sau 24h).

### Q: Agent có gửi data đi đâu ngoài Telegram không?

**A:** Không. Agent chỉ giao tiếp với:
- `api.telegram.org` (gửi/nhận tin nhắn)
- `api.ipify.org` (lấy public IP, chỉ khi `/status` hoặc boot)
- `<RepoUrl>` (GitHub raw, chỉ khi cài hoặc `/update`)

Không có telemetry, không có analytics, không gửi data đi đâu khác.

### Q: Có chạy được trên Windows 7/8 không?

**A:** Windows 8.1+ có PowerShell 5.1 nên chạy được. Windows 7 cần cài Windows Management Framework 5.1. Windows 10/11 chạy tốt.

### Q: Có chạy được trên Linux/Mac không?

**A:** Không. Script dùng Scheduled Task, Win32 CIM, `rundll32 user32.dll,LockWorkStation`, `System.Windows.Forms`... chỉ Windows.

### Q: Nhiều người dùng chung 1 bot được không?

**A:** Được, nếu add bot vào group chat. Mọi người trong group thấy lệnh của nhau. **Cảnh báo**: ai cũng có thể gửi `/shutdown` → tắt máy. Chỉ nên dùng group với người tin tưởng.

### Q: Bot reply chậm 30 giây?

**A:** Bình thường. Agent dùng long-polling 30s để giảm tải request (thay vì gọi mỗi giây). Telegram sẽ giữ request 30s, nếu có tin nhắn mới sẽ trả về ngay. Nếu cần phản hồi tức thì, có thể giảm `timeout=30` trong script xuống `timeout=5` (tăng tải request lên 6 lần).

### Q: Agent có ăn RAM/CPU nhiều không?

**A:** Rất ít. PowerShell process ~30-50MB RAM, CPU gần như 0% (chỉ thức dậy 30s/lần để poll). Không ảnh hưởng hiệu năng máy.

### Q: Có thể cài đặt silent (không UAC prompt) không?

**A:** Không. Windows yêu cầu UAC cho mọi thao tác tạo Scheduled Task chạy dưới SYSTEM. Tuy nhiên chỉ cần 1 lần lúc cài. Sau đó agent chạy ngầm không cần UAC nữa.

### Q: Đổi máy tính thì sao?

**A:** Uninstall trên máy cũ, cài trên máy mới với cùng Bot Token + Chat ID + PC Name. Telegram không quan tâm IP/máy, chỉ cần Chat ID đúng.

### Q: Update script xong bot không phản hồi?

**A:** Kiểm tra log `/log`. Nếu thấy "Polling OK" liên tục nhưng không có "RECV command" → lệnh của bạn không đến được agent (chat_id sai, hoặc bot ở group privacy mode). Nếu log có "RECV command: /status" nhưng không có "sendMessage OK" sau đó → lỗi gửi tin về Telegram.

---

## License & Disclaimer

Dùng cho mục đích quản trị PC cá nhân và PC trong tổ chức của bạn. Tác giả không chịu trách nhiệm nếu dùng sai mục đích (theo dõi người khác mà không được đồng ý, malware, tấn công hệ thống không sở hữu...). Tuân thủ pháp luật sở tại.

Repo: thay URL GitHub của bạn vào `$RepoUrl` trong file `pcagent.ps1` trước khi push.
````

Anh copy từ ````markdown ở đầu tới ```` ở cuối, dán vào file `README.md`, push lên cùng repo với `pcagent.ps1` là xong.
