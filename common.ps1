# Shared parts of the tools (sleep.ps1, wake.ps1, boot.ps1 and install.ps1 load this file).
# Idea: the target disk is ALWAYS found by its exact serial number, so even if Windows renumbers
# disks or drive letters change, we never touch the wrong disk.
$ErrorActionPreference = 'Stop'

$ConfigFile = Join-Path $PSScriptRoot 'config.psd1'
# install.ps1 sets $NoConfig: it loads these functions BEFORE a config exists and sets $Serial / $Smartctl itself.
if (-not $script:NoConfig) {
    if (-not (Test-Path $ConfigFile)) { throw "config.psd1 not found. Run install.ps1 first." }
    $Config   = Import-PowerShellDataFile $ConfigFile
    $Serial   = "$($Config.Serial)".Trim()
    $Smartctl = $Config.SmartctlPath
    # An empty serial would match nothing safely, refuse it instead of guessing
    if (-not $Serial -or $Serial -eq 'YOUR_SERIAL') { throw 'config.psd1 has no valid Serial. Run install.ps1 to pick the disk.' }
}
$Handle     = Join-Path $PSScriptRoot 'handle64.exe'   # optional, see README
$LogFile    = Join-Path $PSScriptRoot 'log.txt'
$StateFile  = Join-Path $PSScriptRoot 'state.txt'      # "asleep" or "awake" (decides what boot.ps1 does)
$DeviceFile = Join-Path $PSScriptRoot 'device.txt'     # PnP id of the disk, saved before eject (wake.ps1 needs it)

function Write-Log($who, $m) { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') $who $m" | Out-File -Append -Encoding utf8 $LogFile }
function Set-State($s) { $s | Out-File -Encoding ascii $StateFile }
# A missing or empty file (e.g. power lost while writing it) counts as 'awake'.
# "$(...)" turns $null (empty file) into '' so .Trim() can't fail.
function Get-State {
    $s = if (Test-Path $StateFile) { "$(Get-Content $StateFile -Raw)".Trim() }
    if ($s) { $s } else { 'awake' }
}

function Show-Message($text, $title, $icon, $seconds = 0) {
    if ($script:Quiet) { return }   # the boot task runs as SYSTEM and cannot show windows
    (New-Object -ComObject WScript.Shell).Popup($text, $seconds, $title, $icon) | Out-Null
}

# The disk as Windows sees it ($null while ejected). Exact match on the serial, never a substring.
function Get-TargetDisk {
    $found = @(Get-Disk | Where-Object { "$($_.SerialNumber)".Trim() -eq $Serial })
    if ($found.Count -gt 1) { throw "More than one disk has serial '$Serial', stopped for safety." }
    $found | Select-Object -First 1
}

# Drive letters on the disk ('D', 'E' ...). Empty if it has none.
function Get-DiskLetters($disk) {
    @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter)" })
}

# Every volume on the disk that holds a file system: a Name for messages and a Path to test-lock.
# A volume with a drive letter is locked through it ('D'). One without a letter (Recovery, EFI,
# mounted into a folder like C:\Data) is locked through its volume GUID path (\\?\Volume{...}),
# so files open on it are caught too.
# Partitions without a file system (MSR, empty) are skipped: nothing can be open on them.
# Throws if the partitions can't be read: an empty list would mean "nothing to check" and let sleep
# take the disk offline unchecked. (ObjectNotFound = the disk simply has no partitions.)
function Get-DiskVolumes($disk) {
    $parts = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue -ErrorVariable err)
    if ($err | Where-Object { $_.CategoryInfo.Category -ne 'ObjectNotFound' }) { throw "Could not read the disk's partitions: $($err[0])" }
    @($parts | ForEach-Object {
        # A drive letter is enough to lock the volume, so it never depends on Get-Volume (which can fail for a moment)
        if ($_.DriveLetter) { return [pscustomobject]@{ Name = "$($_.DriveLetter):"; Path = "$($_.DriveLetter)" } }
        $v = Get-Volume -Partition $_ -ErrorAction SilentlyContinue
        if (-not ($v -and $v.FileSystem)) { return }
        # An empty Path can't be opened, so the lock test fails and the volume counts as busy (safe side)
        [pscustomobject]@{ Name = ('partition {0} ({1}, {2:N1} GB, no drive letter)' -f $_.PartitionNumber, $_.Type, ($_.Size / 1GB)); Path = "$($v.Path)" }
    })
}

# Runs smartctl. Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop',
# so it runs with 'Continue' here. smartctl's exit code is a bit mask: bits 0-2 mean the command itself
# failed; higher bits only describe the disk's health/logs (a worn disk sets them), so they are ignored.
function Invoke-Smartctl {
    $ErrorActionPreference = 'Continue'
    $out = & $Smartctl @args 2>&1 | Out-String
    if ($LASTEXITCODE -band 0x7) { throw "smartctl $($args -join ' ') failed (exit $LASTEXITCODE):`n$out" }
    $out
}

# smartctl addresses the disk by its Windows disk number (/dev/pdN = PhysicalDriveN).
# Before sending any command we read the serial back and compare it exactly.
function Get-SmartPath($disk) {
    $path = "/dev/pd$($disk.Number)"
    $info = Invoke-Smartctl -i $path
    if ($info -notmatch '(?m)^Serial Number:\s*(\S+)' -or $Matches[1] -ne $Serial) { throw "$path is not the target disk, no command was sent." }
    $path
}

# The disk's PnP device id, read from its Path:
#   \\?\scsi#disk&ven_&prod_x#5&12ab34cd&0&000000#{guid}  ->  scsi\disk&ven_&prod_x\5&12ab34cd&0&000000
# So the device is tied to the serial number too, never guessed from the model name.
function Get-DeviceIdFromDisk($disk) {
    if ($disk.Path -notmatch '^\\\\\?\\(.+)#\{[0-9a-fA-F-]+\}$') { throw "Unexpected disk path: $($disk.Path)" }
    $Matches[1] -replace '#', '\'
}

# The disk's PnP device. While the disk is present: from its path (and remembered in device.txt).
# While ejected: Get-Disk no longer lists it, so we use the id remembered before the eject.
function Get-TargetDevice {
    $disk = Get-TargetDisk
    if ($disk) {
        $id = Get-DeviceIdFromDisk $disk
        $id | Out-File -Encoding ascii $DeviceFile
    } else {
        $id = if (Test-Path $DeviceFile) { "$(Get-Content $DeviceFile -Raw)".Trim() }
        if (-not $id) { throw 'Disk is not visible and no saved device id (device.txt missing or empty). Reboot once to bring it back.' }
    }
    # The path is lowercase but Get-PnpDevice -InstanceId is case-sensitive, so compare with -eq (case-insensitive)
    $dev = Get-PnpDevice -Class DiskDrive | Where-Object { $_.InstanceId -eq $id } | Select-Object -First 1
    if (-not $dev) { throw "PnP device not found: $id" }
    $dev
}

# The SATA controller the disk hangs off. Safety: the controller must have NO other child device,
# because restarting it would also disconnect those.
function Get-SafeController {
    $dev = Get-TargetDevice
    $parent   = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName DEVPKEY_Device_Parent).Data
    $children = @((Get-PnpDeviceProperty -InstanceId $parent -KeyName DEVPKEY_Device_Children).Data)
    $others   = $children | Where-Object { $_ -ne $dev.InstanceId }
    if ($others) { throw "The SATA controller has other devices besides the target disk, stopped for safety:`n$($others -join "`n")" }
    $parent
}

if (-not ('HddSleepNative' -as [type])) { Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text; using Microsoft.Win32.SafeHandles;
public static class HddSleepNative {
  [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)] public static extern int CM_Locate_DevNodeW(out uint dn, string id, uint f);
  [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)] public static extern int CM_Request_Device_EjectW(uint dn, out int veto, StringBuilder name, int len, uint f);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern SafeFileHandle CreateFileW(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr i, uint il, IntPtr o, uint ol, out uint r, IntPtr ov);
  // Tries to lock the volume and unlocks it right away. Windows only grants the lock when NO file
  // on the volume is open, so this is an exact "is anything using it?" test. 0 = free, else Win32 error.
  // path: a drive letter ("D") or a volume GUID path ("\\?\Volume{...}\", the trailing \ is removed:
  // with it CreateFile would open the root folder instead of the volume).
  public static int TryLockVolume(string path) {
    string dev = path.Length == 1 ? @"\\.\" + path + ":" : path.TrimEnd('\\');
    if (dev.Length == 0) return 87; // ERROR_INVALID_PARAMETER
    using (var h = CreateFileW(dev, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
      if (h.IsInvalid) return Marshal.GetLastWin32Error();
      uint r;
      if (!DeviceIoControl(h, 0x00090018 /*FSCTL_LOCK_VOLUME*/, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero)) return Marshal.GetLastWin32Error();
      DeviceIoControl(h, 0x0009001C /*FSCTL_UNLOCK_VOLUME*/, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
      return 0;
    }
  }
}
'@ }

# Programs holding the physical disk or one of its volumes open (needs handle64.exe, else empty).
function Get-DiskHolders($disk, $letters) {
    if (-not (Test-Path $Handle)) { return @() }
    $ErrorActionPreference = 'Continue'
    $targets = @("\Device\Harddisk$($disk.Number)\") + @($letters | ForEach-Object { "$($_):\" })
    $holders = foreach ($l in (& $Handle -a -v -accepteula -nobanner 2>$null)) {
        foreach ($t in $targets) { if ($l -like "*,$t*") { ($l -split ',')[0] } }
    }
    @($holders | Sort-Object -Unique)
}

# Ejects the disk like "Safely Remove Hardware". On failure returns Ok=$false plus the veto reason.
# $dev must be looked up BEFORE the spin-down: Get-TargetDevice calls Get-Disk, which talks to every disk
# and would spin a sleeping disk back up right before we eject it (then it can't be stopped anymore).
function Invoke-Eject($dev) {
    $dn = 0
    if ([HddSleepNative]::CM_Locate_DevNodeW([ref]$dn, $dev.InstanceId, 0) -ne 0) { throw 'Device node of the target disk not found.' }
    $sb = New-Object Text.StringBuilder 512; $veto = 0
    $r = [HddSleepNative]::CM_Request_Device_EjectW($dn, [ref]$veto, $sb, 512, 0)
    if ($r -eq 0) { return @{ Ok = $true } }
    @{ Ok = $false; Veto = $veto; VetoName = $sb.ToString() }
}
