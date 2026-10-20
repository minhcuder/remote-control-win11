# =====================================================================
# PCAgent - Telegram-controlled Windows agent (single-file)
# Usage:
#   Install:   irm <REPO>/pcagent.ps1 | iex -Install [-BotToken X -ChatId Y -PCName Z]
#   Uninstall: irm <REPO>/pcagent.ps1 | iex -Uninstall
#   Agent:     powershell -File pcagent.ps1 -Run   (auto via Scheduled Task)
# =====================================================================
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Run,

    [string]$BotToken,
    [string]$ChatId,
    [string]$PCName
)

# =====================================================================
# CONFIG - CHANGE THIS TO YOUR GITHUB RAW URL (no trailing slash)
# =====================================================================
 $RepoUrl = 'https://raw.githubusercontent.com/minhcuder/remote-control-win11/main'

# =====================================================================
# TLS 1.2 REQUIRED for Windows PowerShell 5.1 (Telegram + GitHub need it)
# =====================================================================
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
}

# =====================================================================
# CONSTANTS
# =====================================================================
 $InstallDir   = 'C:\ProgramData\PCAgent'
 $ConfigPath   = Join-Path $InstallDir 'config.json'
 $OffsetPath   = Join-Path $InstallDir 'offset.txt'
 $ScriptPath   = Join-Path $InstallDir 'pcagent.ps1'
 $TaskName     = 'PCAgent'

# Note: $InstallBlock / $UninstallBlock / $AgentBlock are defined below.
# Dispatch happens at the very end of the script (after block definitions).

# =====================================================================
# INSTALL BLOCK
# =====================================================================
 $InstallBlock = {
    $ErrorActionPreference = 'Stop'

    # --- Admin check ---
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal] $currentIdentity).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'CAN CHAY VOI QUYEN ADMINISTRATOR. Mo PowerShell -> Right-click -> Run as Administrator, sau do chay lai lenh cai.'
    }

    # --- Interactive prompts for missing params ---
    if (-not $BotToken) {
        $BotToken = Read-Host 'Bot Token (vd: 123456789:ABCdef...)'
    }
    if (-not $ChatId) {
        $ChatId = Read-Host 'Chat ID (vd: 123456789)'
    }
    if (-not $PCName) {
        $PCName = Read-Host "PC Name (vd: PC-VanPhong, Laptop-NV)"
    }

    # --- Validate ---
    if ($PCName -notmatch '^[A-Za-z][A-Za-z0-9_\-]{1,31}$') {
        throw "PCName khong hop le: '$PCName'. Chi duoc chu cai, so, gach duoi, gach ngang (2-32 ky tu, bat dau bang chu cai)."
    }
    if (-not $BotToken) {
        throw 'Thieu Bot Token. Khong the cai dat.'
    }
    if ($BotToken -notmatch '^\d+:[A-Za-z0-9_\-]{30,}$') {
        Write-Host "! Bot Token co ve khong dung dinh dang (vd: 123456789:ABCdef...). Tiep tuc nhung co the khong hoat dong." -ForegroundColor Yellow
    }
    if ($RepoUrl -match 'USERNAME/REPO') {
        throw @'
!!! CHUA SUA $RepoUrl TRONG FILE pcagent.ps1 !!!

Ban can:
  1. Tai file pcagent.ps1 ve may
  2. Mo bang notepad/VSCode
  3. Tim dong: $RepoUrl = 'https://raw.githubusercontent.com/USERNAME/REPO/main'
  4. Sua USERNAME/REPO thanh GitHub username + repo name cua ban
  5. Push file len GitHub
  6. Chay lai lenh cai
'@
    }

    Write-Host ''
    Write-Host '=== PCAgent Installer ===' -ForegroundColor Cyan
    Write-Host "  PC Name  : $PCName"
    Write-Host "  Chat ID  : $ChatId"
    Write-Host "  Repo URL : $RepoUrl"
    Write-Host ''

    # --- Create folder ---
    if (-not (Test-Path $InstallDir)) {
        New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    }

    # --- Save script locally (copy current file, or download from $RepoUrl) ---
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Copy-Item $PSCommandPath $ScriptPath -Force
        Write-Host '[+] Da copy script tu local.' -ForegroundColor Green
    } else {
        $scriptUrl = "$RepoUrl/pcagent.ps1"
        Write-Host "[*] Downloading pcagent.ps1 tu $scriptUrl ..."
        try {
            Invoke-WebRequest -Uri $scriptUrl -OutFile $ScriptPath -TimeoutSec 30 -UseBasicParsing
            Write-Host '[+] Da download script.' -ForegroundColor Green
        } catch {
            throw "Khong download duoc pcagent.ps1 tu $scriptUrl : $($_.Exception.Message). Kiem tra lai RepoUrl trong file config hoac network."
        }
    }

    # --- Save config ---
    $Config = [ordered]@{
        BotToken    = $BotToken
        ChatId      = $ChatId
        PCName      = $PCName
        RepoUrl     = $RepoUrl.TrimEnd('/')
        Version     = '2.0.0'
        InstalledAt = (Get-Date -Format 'o')
    }
    $Config | ConvertTo-Json | Out-File $ConfigPath -Encoding UTF8
    Write-Host '[+] Da luu config.json' -ForegroundColor Green

    # --- Remove existing scheduled task ---
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Host '[*] Cap nhat scheduled task cu...'
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        } catch { }
    }

    # --- Create scheduled task: SYSTEM, AtStartup, auto-restart ---
    Write-Host '[*] Tao scheduled task (SYSTEM, AtStartup, auto-restart)...'
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Run"
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet `
                    -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable `
                    -RestartCount 999 `
                    -RestartInterval (New-TimeSpan -Minutes 1) `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) `
                    -DontStopOnIdleEnd

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'PCAgent - Telegram remote control agent' | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Write-Host '[+] Scheduled task da tao va chay.' -ForegroundColor Green

    Write-Host ''
    Write-Host '====================================================' -ForegroundColor Green
    Write-Host ' CAI DAT HOAN TAT' -ForegroundColor Green
    Write-Host '====================================================' -ForegroundColor Green
    Write-Host " Folder          : $InstallDir"
    Write-Host " Config          : $ConfigPath"
    Write-Host " Script          : $ScriptPath"
    Write-Host " Scheduled Task  : $TaskName (SYSTEM, AtStartup)"
    Write-Host ""
    Write-Host " Telegram se nhan thong bao tu [$PCName] trong vai giay."
    Write-Host ""
    Write-Host " De go cai:"
    Write-Host "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Uninstall"
    Write-Host ""
}

# =====================================================================
# UNINSTALL BLOCK
# =====================================================================
 $UninstallBlock = {
    $ErrorActionPreference = 'Stop'

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal] $currentIdentity).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'CAN CHAY VOI QUYEN ADMINISTRATOR. Mo PowerShell as Admin roi chay lai.'
    }

    $ErrorActionPreference = 'Continue'
    Write-Host '[*] Dang go cai PCAgent...' -ForegroundColor Cyan

    try {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host '[+] Da xoa scheduled task.' -ForegroundColor Green
    } catch {
        Write-Host '[.] Khong co scheduled task de xoa.' -ForegroundColor Yellow
    }

    # Kill any running agent processes
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*pcagent.ps1* -Run*' } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }

    if (Test-Path $InstallDir) {
        Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
        Write-Host '[+] Da xoa folder.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '[+] GO CAI XONG.' -ForegroundColor Green
}

# =====================================================================
# AGENT BLOCK (run mode)
# =====================================================================
 $AgentBlock = {
    # --- Load config ---
    if (-not (Test-Path $ConfigPath)) { exit 1 }
    try {
        $Config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { exit 1 }

    $script:BotToken = $Config.BotToken
    $script:ChatId   = [string]$Config.ChatId
    $script:PCName   = $Config.PCName
    $script:RepoUrl  = $Config.RepoUrl

    if (-not $BotToken -or -not $ChatId -or -not $PCName) { exit 1 }

    # --- Load last offset ---
    $script:Offset = 0
    if (Test-Path $OffsetPath) {
        try { $script:Offset = [int](Get-Content $OffsetPath -First 1) } catch { $script:Offset = 0 }
    }

    # --- Helper functions ---
    function Send-Telegram {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return }
        $body = @{ chat_id = $ChatId; text = $Text; parse_mode = 'Markdown' }
        try {
            Invoke-RestMethod -Uri "https://api.telegram.org/bot$BotToken/sendMessage" `
                -Method Post -Body $body -TimeoutSec 15 | Out-Null
        } catch { }
    }

    function Send-TelegramPhoto {
        param([string]$FilePath, [string]$Caption = '')
        if (-not (Test-Path $FilePath)) { Send-Telegram "[$PCName] File anh khong ton tai"; return }
        $url = "https://api.telegram.org/bot$BotToken/sendPhoto"
        $capArg = if ($Caption) { "-F `"caption=$Caption`"" } else { '' }
        $cmd = "curl.exe -s -m 60 -X POST `"$url`" -F `"chat_id=$ChatId`" $capArg -F `"photo=@$FilePath`""
        try { Invoke-Expression $cmd | Out-Null }
        catch { Send-Telegram "[$PCName] Loi gui anh: $($_.Exception.Message)" }
    }

    function Wait-Network {
        $maxAttempts = 0
        while ($true) {
            try {
                $null = Invoke-RestMethod -Uri 'https://api.telegram.org' -TimeoutSec 5
                return $true
            } catch {
                Start-Sleep -Seconds 3
                $maxAttempts++
                if ($maxAttempts -gt 600) { return $false }
            }
        }
    }

    function Get-PCInfo {
        try {
            $os   = Get-CimInstance Win32_OperatingSystem
            $cs   = Get-CimInstance Win32_ComputerSystem
            $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
            $boot = $os.LastBootUpTime
            $up   = (Get-Date) - $boot

            $totalRAM = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            $freeRAM  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
            $usedRAM  = [math]::Round($totalRAM - $freeRAM, 1)
            $ramPct   = if ($totalRAM -gt 0) { [math]::Round(($totalRAM - $freeRAM) / $totalRAM * 100, 0) } else { 0 }

            $localIP = 'N/A'
            try {
                $nic = Get-NetIPConfiguration -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
                if ($nic) { $localIP = $nic.IPv4Address.IPAddress }
            } catch { }

            $externIP = 'N/A'
            try { $externIP = (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 5) } catch { }

            $cpuName = if ($cpu) { $cpu.Name } else { 'N/A' }

            return @"
*$PCName* - PC da online
|- Ten may: $($cs.Name)
|- IP noi bo: $localIP
|- IP ngoai: $externIP
|- OS: $($os.Caption) ($($os.Version))
|- CPU: $cpuName
|- RAM: ${totalRAM}GB (da dung ${ramPct}%)
|- Uptime: $($up.Days) ngay $($up.Hours)h $($up.Minutes)phut
|- Thoi gian: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
        } catch {
            return "[$PCName] Loi lay thong tin PC: $($_.Exception.Message)"
        }
    }

    function Invoke-InUserSession {
        param([string]$TempScriptPath)

        $username = $null
        try {
            $explorer = Get-Process -IncludeUserName explorer -ErrorAction SilentlyContinue |
                        Sort-Object SessionId | Select-Object -First 1
            if ($explorer) { $username = $explorer.UserName }
        } catch { }
        if (-not $username) {
            try {
                $u = (Get-CimInstance Win32_ComputerSystem).UserName
                if ($u) { $username = $u }
            } catch { }
        }
        if (-not $username) { return $false }

        $taskName = "PCAgent_User_$(Get-Random)"
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TempScriptPath`""
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)
        $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        try {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
        } catch { return $false }

        $cleanup = "`$tn='$taskName'; Start-Sleep 90; try { Unregister-ScheduledTask -TaskName `$tn -Confirm:`$false } catch {}"
        Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$cleanup`"" -WindowStyle Hidden | Out-Null
        return $true
    }

    function Invoke-Screenshot {
        $outFile  = Join-Path $InstallDir "shot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        $tmpScript = Join-Path $InstallDir '_shot.ps1'
        @"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
`$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
`$bmp = New-Object System.Drawing.Bitmap(`$screen.Width, `$screen.Height)
`$g = [System.Drawing.Graphics]::FromImage(`$bmp)
`$g.CopyFromScreen(`$screen.Location, [System.Drawing.Point]::Empty, `$screen.Size)
`$bmp.Save('$outFile', [System.Drawing.Imaging.ImageFormat]::Png)
`$g.Dispose(); `$bmp.Dispose()
"@ | Out-File $tmpScript -Encoding UTF8

        $ok = Invoke-InUserSession -TempScriptPath $tmpScript
        if (-not $ok) {
            try {
                Add-Type -AssemblyName System.Windows.Forms,System.Drawing
                $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                $bmp = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
                $bmp.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
                $g.Dispose(); $bmp.Dispose()
                $ok = $true
            } catch { return $null }
        } else {
            for ($i = 0; $i -lt 20; $i++) {
                if (Test-Path $outFile) { break }
                Start-Sleep -Milliseconds 300
            }
        }
        if (Test-Path $outFile) { return $outFile }
        return $null
    }

    function Invoke-Lock {
        $tmpScript = Join-Path $InstallDir '_lock.ps1'
        'rundll32.exe user32.dll,LockWorkStation' | Out-File $tmpScript -Encoding UTF8
        return Invoke-InUserSession -TempScriptPath $tmpScript
    }

    function Invoke-Msg {
        param([string]$Text)
        $safe = $Text -replace "'", "''"
        $tmpScript = Join-Path $InstallDir '_msg.ps1'
        @"
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show('$safe', 'PCAgent Message', 'OK', 'Information') | Out-Null
"@ | Out-File $tmpScript -Encoding UTF8
        return Invoke-InUserSession -TempScriptPath $tmpScript
    }

    function Invoke-Exec {
        param([string]$Command)
        if (-not $Command) { return 'Khong co lenh.' }
        try {
            $result = Invoke-Expression $Command 2>&1 | Out-String
            if (-not $result) { $result = '(khong co output)' }
            if ($result.Length -gt 3900) { $result = $result.Substring(0, 3900) + "`n...[truncated]" }
            return $result
        } catch {
            return "Loi: $($_.Exception.Message)"
        }
    }

    function Invoke-Update {
        $newUrl = "$RepoUrl/pcagent.ps1"
        $tempFile = Join-Path $InstallDir 'pcagent.ps1.new'
        try {
            Invoke-WebRequest -Uri $newUrl -OutFile $tempFile -TimeoutSec 30 -UseBasicParsing
            $size = (Get-Item $tempFile).Length
            if ($size -lt 1000) { throw "File moi qua nho ($size bytes)" }
            Move-Item $tempFile $ScriptPath -Force
            Send-Telegram "[$PCName] Da update xong, dang restart agent..."

            $restartCmd = "Start-Sleep -Seconds 3; try { Stop-ScheduledTask -TaskName '$TaskName' -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Seconds 2; try { Start-ScheduledTask -TaskName '$TaskName' } catch {}"
            Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$restartCmd`"" -WindowStyle Hidden | Out-Null
        } catch {
            Send-Telegram "[$PCName] Loi update: $($_.Exception.Message)"
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }

    # --- Boot notification ---
    Wait-Network
    Send-Telegram (Get-PCInfo)

    # --- Main polling loop ---
    while ($true) {
        try {
            $url = "https://api.telegram.org/bot$BotToken/getUpdates?offset=$Offset&timeout=30"
            $response = Invoke-RestMethod -Uri $url -TimeoutSec 35

            if ($response.result) {
                foreach ($update in $response.result) {
                    $script:Offset = [int]$update.update_id + 1
                    try { $Offset | Out-File $OffsetPath -Encoding ASCII -ErrorAction SilentlyContinue } catch { }

                    if (-not $update.message) { continue }
                    if (-not $update.message.text) { continue }

                    $fromChatId = [string]$update.message.chat.id
                    if ($fromChatId -ne $ChatId) { continue }

                    $text = $update.message.text.Trim()
                    if (-not $text.StartsWith('/')) { continue }

                    # --- Parse: /cmd [@pcname] [args...] ---
                    $parts = $text -split '\s+'
                    $cmd   = $parts[0].ToLower()

                    $pcname   = $null
                    $restArgs = @()

                    if ($parts.Length -le 1) {
                        # Just /cmd, no args
                    }
                    elseif ($parts[1].StartsWith('@')) {
                        $pcname = $parts[1].Substring(1)
                        if ($parts.Length -gt 2) {
                            $restArgs = $parts[2..($parts.Length - 1)]
                        }
                    }
                    else {
                        $arg1 = $parts[1]
                        $looksLikePC = $arg1 -match '^[A-Za-z][A-Za-z0-9_\-]{0,31}$'

                        if ($looksLikePC -and $cmd -notin @('/exec', '/msg')) {
                            $pcname = $arg1
                            if ($parts.Length -gt 2) {
                                $restArgs = $parts[2..($parts.Length - 1)]
                            }
                        }
                        else {
                            $restArgs = $parts[1..($parts.Length - 1)]
                        }
                    }

                    if ($pcname -and $pcname -ne $PCName) { continue }

                    $restText = ($restArgs -join ' ').Trim()

                    switch ($cmd) {
                        '/shutdown' {
                            Send-Telegram "[$PCName] Dang shutdown..."
                            shutdown /s /t 3 /f /c 'PCAgent: Remote shutdown'
                        }
                        '/restart' {
                            Send-Telegram "[$PCName] Dang restart..."
                            shutdown /r /t 3 /f /c 'PCAgent: Remote restart'
                        }
                        '/lock' {
                            $ok = Invoke-Lock
                            if ($ok) { Send-Telegram "[$PCName] Da khoa man hinh" }
                            else     { Send-Telegram "[$PCName] Khong co user session active de lock" }
                        }
                        '/status' {
                            Send-Telegram (Get-PCInfo)
                        }
                        '/screenshot' {
                            $file = Invoke-Screenshot
                            if ($file) {
                                Send-TelegramPhoto -FilePath $file -Caption "[$PCName] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                                Remove-Item $file -Force -ErrorAction SilentlyContinue
                            } else {
                                Send-Telegram "[$PCName] Loi chup man hinh (khong co user session?)"
                            }
                        }
                        '/msg' {
                            if ($restText) {
                                $ok = Invoke-Msg -Text $restText
                                if ($ok) { Send-Telegram "[$PCName] Da hien thi: $restText" }
                                else     { Send-Telegram "[$PCName] Khong the hien thi (khong co user session)" }
                            } else {
                                Send-Telegram "[$PCName] Cu phap: /msg @pc <noi dung>"
                            }
                        }
                        '/exec' {
                            if ($restText) {
                                $result = Invoke-Exec -Command $restText
                                Send-Telegram "[$PCName] > $restText`:`n$result"
                            } else {
                                Send-Telegram "[$PCName] Cu phap: /exec @pc <lenh PowerShell>"
                            }
                        }
                        '/update' {
                            Invoke-Update
                        }
                        '/help' {
                            $help = @"
[$PCName] *Lenh available:*
/shutdown [pc]      - Tat may
/restart  [pc]      - Khoi dong lai
/lock     [pc]      - Khoa man hinh
/status   [pc]      - Thong tin PC
/screenshot [pc]    - Chup man hinh
/msg   @pc <text>   - Hien thi popup (can @)
/exec  @pc <cmd>    - Chay lenh PowerShell (can @)
/update  [pc]       - Tu update tu GitHub
/help               - Hien thi lenh

[pc] = ten PC (vd: PC-VanPhong), bo qua = TAT CA PC.
/exec va /msg can dung @pc de phan biet voi text lenh.
"@
                            Send-Telegram $help
                        }
                        default { }
                    }
                }
            }
        }
        catch {
            Start-Sleep -Seconds 5
        }
    }
}

# =====================================================================
# DISPATCH (must be AFTER all block definitions above)
# =====================================================================
function Pause-Exit {
    param([string]$Msg = 'Nhan Enter de thoat...')
    Write-Host ''
    try { Read-Host $Msg | Out-Null } catch { }
}

if ($Install) {
    try {
        & $InstallBlock
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        Pause-Exit
        exit $code
    } catch {
        Write-Host ''
        Write-Host '===================================================' -ForegroundColor Red
        Write-Host ' LOI KHI CAI DAT:' -ForegroundColor Red
        Write-Host '===================================================' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Stack trace:' -ForegroundColor DarkGray
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        Pause-Exit 'Nhan Enter de thoat...'
        exit 1
    }
}

if ($Uninstall) {
    try {
        & $UninstallBlock
        Pause-Exit
        exit 0
    } catch {
        Write-Host ''
        Write-Host '===================================================' -ForegroundColor Red
        Write-Host ' LOI KHI GO CAI:' -ForegroundColor Red
        Write-Host '===================================================' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        Pause-Exit 'Nhan Enter de thoat...'
        exit 1
    }
}

if ($Run) {
    try {
        & $AgentBlock
    } catch {
        # Agent loop should never exit cleanly; if we get here, log and restart
        Start-Sleep -Seconds 10
        exit 1
    }
    exit 0
}

# Default: show help
Write-Host ''
Write-Host '=== PCAgent - Usage ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Cai dat (1 lenh, chay as Admin):'
Write-Host "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Install -BotToken '123:ABC' -ChatId '123456' -PCName 'PC-VanPhong'"
Write-Host ''
Write-Host 'Hoac interactive (se hoi token/chatid/pcname):'
Write-Host "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Install"
Write-Host ''
Write-Host 'Go cai:'
Write-Host "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Uninstall"
Write-Host ''
exit 0
