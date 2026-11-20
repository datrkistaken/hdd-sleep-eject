# One-time setup. Run in an ADMIN PowerShell from this folder:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# 1) Lets you pick the disk and checks that it can work (Hot Plug, controller, smartctl...).
#    If any check fails, nothing is installed.
# 2) Copies the scripts to "C:\Program Files\hdd-sleep-eject". The tasks run them as admin without a
#    UAC prompt, so they must live where only admins can change them. Otherwise any program running as
#    you could edit a script and get admin rights through the task.
# 3) Registers two tasks that run as YOUR account with "highest privileges": you can start your own
#    task without a UAC prompt and it still runs as admin. Desktop shortcuts just start those tasks.
#    A third task (SYSTEM, at startup) restores the last state after a reboot.
# After changing the scripts here, run install.ps1 again to update the installed copy.
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Run this script from an administrator PowerShell.' -ForegroundColor Red; exit 1 }

$src  = $PSScriptRoot                                       # this folder (download / git clone)
$dest = Join-Path $env:ProgramFiles 'hdd-sleep-eject'      # installed copy, admin-only writable
$script:NoConfig = $true
. (Join-Path $src 'common.ps1')
# The checks below run from here, but settings belong to the installed copy
$ConfigFile = Join-Path $dest 'config.psd1'
$DeviceFile = Join-Path $env:TEMP 'hdd-sleep-eject-device.txt'

function Write-Check($status, $name, $detail) {
    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$status]
    Write-Host ('  [{0,-4}] ' -f $status) -ForegroundColor $color -NoNewline
    Write-Host "$name" -NoNewline
    if ($detail) { Write-Host " - $detail" -ForegroundColor Gray } else { Write-Host '' }
}
function Read-YesNo($question) {
    while ($true) {
        $a = "$(Read-Host "$question (Y/N)")".Trim().ToUpper()
        if ($a -in 'Y', 'YES') { return $true }
        if ($a -in 'N', 'NO')  { return $false }
    }
}
# Sysinternals Handle (optional): shows which program blocks a sleep. It may not be redistributed,
# so it is never in this repo: it is taken from this folder or from a winget install.
function Find-Handle {
    $candidates = @(
        (Join-Path $src 'handle64.exe')
        (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Microsoft.Sysinternals.Handle*\handle64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
        (Get-ChildItem "$env:ProgramFiles\WinGet\Packages\Microsoft.Sysinternals.Handle*\handle64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
        (Get-Command handle64.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    )
    $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
function Get-DiskLabel($d) {
    $media = (Get-PhysicalDisk | Where-Object DeviceId -eq "$($d.Number)").MediaType
    $letters = (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter):" }) -join ' '
    '{0,-28} {1,6:N0} GB  {2,-5} {3,-5} {4,-6} serial {5}' -f $d.FriendlyName, ($d.Size / 1GB), $media, $d.BusType, $letters, "$($d.SerialNumber)".Trim()
}

Write-Host "`n=== hdd-sleep-eject setup ===`n" -ForegroundColor Cyan

# --- smartctl -------------------------------------------------------------------------------
$Smartctl = 'C:\Program Files\smartmontools\bin\smartctl.exe'
if (-not (Test-Path $Smartctl)) {
    $cmd = Get-Command smartctl.exe -ErrorAction SilentlyContinue
    if ($cmd) { $Smartctl = $cmd.Source }
    else {
        Write-Host 'smartctl was not found. Install smartmontools first, e.g.:' -ForegroundColor Red
        Write-Host '  winget install smartmontools.smartmontools'
        exit 1
    }
}
# The tasks run smartctl as admin (and as SYSTEM at boot), so like handle64.exe it must sit where only
# admins can change it. A copy in a user folder could be swapped by any program running as you.
$protected = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' }
if (-not ($protected | Where-Object { $Smartctl.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) {
    Write-Host "smartctl was found at $Smartctl, outside Program Files." -ForegroundColor Red
    Write-Host 'The tasks run it as admin, so it must be installed for all users, e.g.:'
    Write-Host '  winget install smartmontools.smartmontools'
    exit 1
}

# --- Existing config? ----------------------------------------------------------------------
$disk = $null
# An older version kept config.psd1 next to the scripts; use it as the previous choice if there is no other
$oldConfig = @($ConfigFile, (Join-Path $src 'config.psd1')) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($oldConfig) {
    $Serial = "$((Import-PowerShellDataFile $oldConfig).Serial)".Trim()
    $old = $null
    if ($Serial) { try { $old = Get-TargetDisk } catch { } }
    if ($old) {
        Write-Host 'Already configured for:'
        Write-Host "  $(Get-DiskLabel $old)"
        if (Read-YesNo 'Keep this disk?') { $disk = $old }
    } else {
        Write-Host "config.psd1 exists but its disk (serial $Serial) is not visible right now." -ForegroundColor Yellow
        Write-Host 'If it is asleep, run HDD Wake first. Otherwise pick a disk below.'
    }
}

# --- Pick a disk ---------------------------------------------------------------------------
# Logic: the disk Windows runs from (IsSystem/IsBoot) is never offered, so it can't be picked by mistake.
if (-not $disk) {
    $all = @(Get-Disk | Sort-Object Number)
    $candidates = @($all | Where-Object { -not $_.IsSystem -and -not $_.IsBoot })
    Write-Host "`nWhich disk should be put to sleep?`n"
    foreach ($d in $candidates) { Write-Host ('  [{0}] {1}' -f $d.Number, (Get-DiskLabel $d)) }
    foreach ($d in $all | Where-Object { $_.IsSystem -or $_.IsBoot }) {
        Write-Host ("  (Disk {0} {1} is the Windows disk - hidden)" -f $d.Number, $d.FriendlyName) -ForegroundColor DarkGray
    }
    if (-not $candidates) { Write-Host "`nNo disk other than the Windows disk was found." -ForegroundColor Red; exit 1 }

    while (-not $disk) {
        $a = "$(Read-Host "`nEnter disk number (Q to quit)")".Trim()
        if ($a -in 'q', 'Q') { exit 0 }
        $disk = $candidates | Where-Object { "$($_.Number)" -eq $a }
        if (-not $disk) { Write-Host 'Not in the list, try again.' -ForegroundColor Yellow }
    }
}

# --- Checks --------------------------------------------------------------------------------
$Serial = "$($disk.SerialNumber)".Trim()
Write-Host "`nChecking disk $($disk.Number) ($($disk.FriendlyName))..."
$failed = $false

# 1) Serial number: every script finds the disk by it, so it must exist and be unique
if (-not $Serial) {
    Write-Check FAIL 'Serial number' 'the disk reports no serial number, it cannot be identified safely'; $failed = $true
} elseif (@(Get-Disk | Where-Object { "$($_.SerialNumber)".Trim() -eq $Serial }).Count -ne 1) {
    Write-Check FAIL 'Serial number' "'$Serial' matches more than one disk"; $failed = $true
} else { Write-Check OK 'Serial number' $Serial }

if (-not $failed) {
    # 2) Hot Plug: without it Windows treats the disk as fixed and refuses to eject it
    $cap = 0
    try { $cap = (Get-PnpDeviceProperty -InstanceId (Get-TargetDevice).InstanceId -KeyName DEVPKEY_Device_Capabilities).Data } catch { }
    if ($cap -band 0x4) { Write-Check OK 'Hot Plug' 'disk is removable' }
    else {
        Write-Check FAIL 'Hot Plug' 'disk is not removable. Enable Hot Plug for its SATA port in BIOS/UEFI (usually Advanced > SATA Configuration), then run setup again.'
        $failed = $true
    }

    # 3) Controller: wake.ps1 restarts the whole controller, so the disk must be alone on it
    try { Get-SafeController | Out-Null; Write-Check OK 'SATA controller' 'only this disk is attached to it' }
    catch { Write-Check FAIL 'SATA controller' $_.Exception.Message; $failed = $true }

    # 4) smartctl must reach this exact disk (it is the one that spins it down)
    try { $p = Get-SmartPath $disk; Write-Check OK 'smartctl' "reaches the disk as $p" }
    catch { Write-Check FAIL 'smartctl' $_.Exception.Message; $failed = $true }

    # 5) A page file on the disk keeps it open, so Windows would refuse every eject
    $letters = @(Get-DiskLetters $disk | ForEach-Object { "$($_):" })
    $pf = Get-CimInstance Win32_PageFileUsage | Where-Object { $letters -contains $_.Name.Substring(0, 2) }
    if ($pf) { Write-Check FAIL 'Page file' "$($pf.Name -join ', ') is on this disk. Move it to another disk first."; $failed = $true }
    else { Write-Check OK 'Page file' 'none on this disk' }

    # 6) Info only: an SSD makes no noise, sleeping it is pointless (but harmless)
    if ((Get-PhysicalDisk | Where-Object DeviceId -eq "$($disk.Number)").MediaType -eq 'SSD') {
        Write-Check WARN 'Media type' 'this is an SSD - it is silent, this tool is meant for spinning disks'
    }
}

if ($failed) { Write-Host "`nSetup stopped, nothing was installed. Fix the item(s) above and run it again." -ForegroundColor Red; exit 1 }

Write-Host ''
if (-not (Read-YesNo "All checks passed. Install for disk $($disk.Number) ($($disk.FriendlyName))?")) { Write-Host 'Cancelled, nothing was installed.'; exit 0 }

# --- Install -------------------------------------------------------------------------------
# Copy the runtime files. Program Files only lets admins write, and the new folder inherits that.
# log.txt / state.txt / device.txt already there are kept.
New-Item -ItemType Directory -Force $dest | Out-Null
foreach ($f in 'common.ps1', 'sleep.ps1', 'wake.ps1', 'boot.ps1') { Copy-Item (Join-Path $src $f) $dest -Force }
Write-Host "`nInstalled to $dest"

# Handle: offer to get it from Microsoft via winget if it isn't anywhere yet
$handleSrc = Find-Handle
if (-not $handleSrc -and -not (Test-Path (Join-Path $dest 'handle64.exe'))) {
    Write-Host "`nOptional: Sysinternals Handle (by Microsoft) lets the tool tell you WHICH program blocks a sleep." -ForegroundColor Gray
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        if (Read-YesNo 'Install it now from Microsoft via winget?') {
            $ErrorActionPreference = 'Continue'
            winget install --id Microsoft.Sysinternals.Handle -e --source winget --accept-source-agreements
            $ErrorActionPreference = 'Stop'
            $handleSrc = Find-Handle
            if (-not $handleSrc) { Write-Host 'Handle was not found after winget, continuing without it.' -ForegroundColor Yellow }
        }
    } else {
        Write-Host 'winget is not available. You can download it from https://learn.microsoft.com/sysinternals/downloads/handle' -ForegroundColor Gray
    }
}
# Always run a COPY from the protected folder: winget installs it in your user profile, which any
# program running as you can change, and the tasks run it as admin.
if ($handleSrc) { Copy-Item $handleSrc (Join-Path $dest 'handle64.exe') -Force; Write-Host "Copied handle64.exe from $handleSrc" }

@"
# Written by install.ps1. Run install.ps1 again to pick another disk.
@{
    # Serial number of the HDD to put to sleep (every command checks it first)
    Serial       = '$($Serial -replace "'", "''")'
    # smartmontools path
    SmartctlPath = '$($Smartctl -replace "'", "''")'
}
"@ | Out-File -Encoding ascii $ConfigFile
Write-Host "Saved config.psd1"

$user     = "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
function New-PsAction($file) {
    New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\$file`""
}

# Sleep / wake tasks (started manually via the shortcuts)
$userPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
foreach ($t in @(@{N='HDD sleep'; F='sleep.ps1'}, @{N='HDD wake'; F='wake.ps1'})) {
    Register-ScheduledTask -TaskName $t.N -Action (New-PsAction $t.F) -Principal $userPrincipal -Settings $settings -Force | Out-Null
    Write-Host "Registered task: $($t.N)"
}

# Boot task: SYSTEM, once at startup
$sysPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'HDD sleep boot' -Action (New-PsAction 'boot.ps1') -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $sysPrincipal -Settings $settings -Force | Out-Null
Write-Host 'Registered task: HDD sleep boot'

# Desktop shortcuts
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
foreach ($s in @(@{N='HDD Sleep'; T='HDD sleep'}, @{N='HDD Wake'; T='HDD wake'})) {
    $lnk = $shell.CreateShortcut((Join-Path $desktop "$($s.N).lnk"))
    $lnk.TargetPath  = "$env:SystemRoot\System32\schtasks.exe"
    $lnk.Arguments   = "/run /tn `"$($s.T)`""
    $lnk.WindowStyle = 7   # minimized
    $lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,30"
    $lnk.Save()
    Write-Host "Created shortcut: $($s.N)"
}

Write-Host "`nDone. Use the HDD Sleep / HDD Wake shortcuts on your desktop." -ForegroundColor Green
Write-Host "Log: $dest\log.txt" -ForegroundColor Gray
if (-not (Test-Path (Join-Path $dest 'handle64.exe'))) {
    Write-Host 'Without Sysinternals Handle, a blocked sleep can''t name the program. Run setup again any time to add it.' -ForegroundColor Gray
}
