# SuperAgent — Điều khiển PC Windows từ xa qua Telegram

Chạy ngầm trên Windows, nhận lệnh từ Telegram bot để tắt/khởi động lại máy, khóa màn hình, chụp màn hình, hiện popup, chạy lệnh PowerShell, xem log, và tự update. Hỗ trợ 1 bot điều khiển nhiều PC.

---

## Cài đặt (1 lệnh)

Mở PowerShell (không cần Admin — script tự xin quyền), chạy:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/minhcuder/remote-control-win11/main/pcagent.ps1'))) -Install -Silent -BotToken 'TOKEN' -ChatId 'CHAT_ID' -PCName 'PC-Parallels'
```

Thay `TOKEN`, `CHAT_ID`, `PC-Parallels` bằng thông tin của bạn. Sau khi cài xong (chỉ 1 lần hiện UAC prompt), agent chạy ngầm hoàn toàn — user không thấy gì.

**Cài trên PC thứ 2**: chỉ cần đổi `-PCName`, dùng cùng Bot Token + Chat ID.

---

## Lệnh điều khiển (gửi qua chat với bot)

| Lệnh | Ý nghĩa | Ví dụ |
|---|---|---|
| `/shutdown [pc]` | Tắt máy sau 3 giây | `/shutdown` hoặc `/shutdown PC-Office` |
| `/restart [pc]` | Khởi động lại máy | `/restart Server-01` |
| `/lock [pc]` | Khóa màn hình | `/lock` |
| `/status [pc]` | Xem thông tin PC (IP, OS, CPU, RAM, uptime) | `/status` |
| `/screenshot [pc]` | Chụp màn hình full (DPI-aware), gửi ảnh về Telegram | `/screenshot PC-Office` |
| `/msg @pc <text>` | Hiện popup trên **1 PC** (bắt buộc `@pc`) | `/msg @PC-Office Backup ngay!` |
| `/msgall <text>` | Hiện popup trên **tất cả PC** | `/msgall Tất cả mọi người ra họp!` |
| `/exec @pc <cmd>` | Chạy lệnh PowerShell, trả output về Telegram (bắt buộc `@pc`) | `/exec @Server-01 Get-Service \| Select -First 5` |
| `/update [pc]` | Tự update agent từ GitHub + restart | `/update` |
| `/log [pc]` | Xem 50 dòng log cuối | `/log PC-Office` |
| `/help` | Hiển thị danh sách lệnh | `/help` |

### Quy ước `[pc]` vs `@pc`

- **Lệnh không có text args** (`/shutdown /restart /lock /status /screenshot /update /log`): pcname để trực tiếp. Bỏ qua → broadcast tất cả PC.
  ```
  /screenshot PC-Office      ← chỉ PC-Office
  /status                    ← tất cả PC reply
  ```
- **`/msg` và `/exec`**: bắt buộc dùng `@` trước pcname để phân biệt với nội dung lệnh.
  ```
  /msg @PC-Office Hello      ← đúng
  /msg PC-Office Hello       ← SAI: script hiểu "PC-Office Hello" là nội dung popup
  ```

---

## Lấy Bot Token & Chat ID

### 1. Tạo bot
- Mở Telegram → chat với **@BotFather** → `/newbot` → đặt tên → lấy **Bot Token** (dạng `1234567890:ABCdef...`)

### 2. Lấy Chat ID (private chat — khuyến nghị)
- Chat với bot vừa tạo → gửi `/start` → gửi 1 tin bất kỳ
- Mở trình duyệt: `https://api.telegram.org/bot<TOKEN>/getUpdates`
- Tìm `"chat": { "id": 123456789 }` → đây là Chat ID (dạng số dương)

### 3. (Nếu dùng group chat) Lấy Group Chat ID
- Add bot vào group → gửi 1 tin trong group
- Truy cập `getUpdates` như trên → tìm `"id": -1001234567890` (có `-100` prefix)
- Vào @BotFather → `/setprivacy` → chọn bot → `Disable` (bot mới thấy message trong group)

---

## Cơ chế hoạt động

- **Long-polling**: agent gọi `getUpdates` lên Telegram mỗi 30 giây để hỏi "có tin nhắn mới?". Không cần mở port, không cần server, không cần IP public.
- **Persistence**: chạy dưới `SYSTEM` qua Scheduled Task trigger `AtStartup`. Auto-restart 999 lần (mỗi 1 phút) nếu bị kill.
- **Silent**: sau khi cài, agent chạy ẩn hoàn toàn (`-WindowStyle Hidden`). User không thấy console, không thấy process trong tray. Chỉ `/msg` và `/msgall` hiện popup.

### File lưu trên máy

```
C:\ProgramData\SuperAgent\
├── pcagent.ps1       # Script chính
├── config.json       # BotToken, ChatId, PCName, RepoUrl
├── agent.log         # Log activity (rotate khi >2MB)
├── offset.txt        # Last Telegram update_id
└── _shot/_msg/_lock.ps1   # Temp scripts
```

---

## Cấu hình file trước khi push GitHub

> Nếu chưa sửa `$RepoUrl` trong file, lệnh cài sẽ báo lỗi.

1. Tải file `pcagent.ps1`
2. Mở bằng Notepad, tìm dòng `$RepoUrl = '...'` (khoảng dòng 26)
3. Sửa thành URL GitHub raw của bạn:
   ```powershell
   $RepoUrl = 'https://raw.githubusercontent.com/minhcuder/remote-control-win11/main'
   ```
4. Lưu + push lên GitHub

---

## Gỡ cài đặt

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/minhcuder/remote-control-win11/main/pcagent.ps1'))) -Uninstall -Silent
```

Hoặc chạy PowerShell thuần:
```powershell
Stop-ScheduledTask -TaskName SuperAgent -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName SuperAgent -Confirm:$false
Remove-Item -Recurse -Force 'C:\ProgramData\SuperAgent'
```

---

## Troubleshooting

### Cài xong không nhận tin nhắn Telegram

1. Xem log:
   ```powershell
   Get-Content C:\ProgramData\SuperAgent\agent.log -Tail 30
   ```
   Hoặc gửi `/log` cho bot.

2. Tra lỗi theo log line:

   | Log | Nguyên nhân | Fix |
   |---|---|---|
   | `sendMessage FAIL: (401) Unauthorized` | Bot Token sai | Đối chiếu BotFather |
   | `sendMessage FAIL: (400) chat not found` | Chat ID sai | Lấy lại Chat ID |
   | `Wait-Network: TIMEOUT` | Không có mạng / Telegram bị chặn | Kiểm tra mạng, DNS, firewall |
   | `POLL ERROR: ...` | Lỗi network hoặc token | Xem chi tiết trong log |

3. Test bot thủ công — mở trình duyệt:
   ```
   https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=<CHAT_ID>&text=test
   ```
   Nếu nhận được tin → token + chatid đúng, vấn đề ở agent.

### Bot không phản hồi lệnh

- Gửi `/status` cho bot → nếu không reply, PC offline hoặc agent chết
- Khởi động lại agent:
  ```powershell
  Start-ScheduledTask -TaskName SuperAgent
  ```
- Nếu dùng group chat, kiểm tra Privacy Mode đã Disable (Bước 3 ở phần Lấy Chat ID)

### `/screenshot`, `/lock`, `/msg` không hoạt động

Agent chạy as SYSTEM ở session 0. Cần có user đang login ở console session (không phải RDP) để chụp màn hình / lock / hiện popup. Nếu PC ở màn hình lock, screenshot vẫn chụp được nhưng chỉ là màn hình lock.

### Đổi PC Name / Bot Token / Chat ID

```powershell
$cfg = Get-Content C:\ProgramData\SuperAgent\config.json | ConvertFrom-Json
$cfg.PCName   = 'NewName'        # hoặc $cfg.BotToken, $cfg.ChatId
$cfg | ConvertTo-Json | Out-File C:\ProgramData\SuperAgent\config.json -Encoding UTF8
Start-ScheduledTask -TaskName SuperAgent
```

### Agent bị antivirus flag

```powershell
Add-MpPreference -ExclusionPath 'C:\ProgramData\SuperAgent'
```

---

## Bảo mật

- **Whitelist Chat ID**: chỉ Chat ID trong `config.json` mới có quyền gửi lệnh
- **Bot Token lưu trong `config.json`** trên máy bạn, không nằm trong GitHub repo (an toàn khi repo public)
- **`/exec` nguy hiểm**: chạy với quyền SYSTEM, cẩn thận với lệnh xóa file, format. Không chia sẻ Chat ID
- Nếu token bị lộ → BotFather `/revoke` → tạo token mới → update `config.json`

---

## FAQ

**Có cần mở port / server / VPS không?**
Không. Agent dùng long-polling, Telegram server lo phần server.

**Bot reply chậm 30 giây?**
Bình thường — agent poll mỗi 30s. Cần tức thì thì giảm `timeout=30` trong script xuống `timeout=5`.

**Agent ăn RAM/CPU nhiều không?**
Rất ít. ~30-50MB RAM, CPU gần 0%.

**Có chạy được trên Linux/Mac không?**
Không. Chỉ Windows (PowerShell 5.1+).

**Đổi máy tính thì sao?**
Uninstall máy cũ → cài máy mới với cùng Bot Token + Chat ID + PC Name.

---

## License & Disclaimer

Dùng cho mục đích quản trị PC cá nhân và tổ chức của bạn. Không dùng để theo dõi người khác mà không được đồng ý. Tuân thủ pháp luật sở tại.
