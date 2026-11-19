# Brings the target HDD back.
# Idea: an ejected disk stays in Windows as "waiting to be physically removed".
# Restarting its SATA controller is the software version of unplugging and replugging the cable:
# the controller rescans its port and detects the disk as newly attached.
# Safety: does nothing if the controller has any other device besides the target disk.
param([switch]$Quiet)
$script:Quiet = $Quiet
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $disk = Get-TargetDisk
    if (-not $disk) {
        $controller = Get-SafeController
        # Exit code, not the text: pnputil's messages are translated on non-English Windows (3010 = reboot needed)
        $ErrorActionPreference = 'Continue'
        $out = pnputil /restart-device "$controller" 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) { throw "Could not restart the controller (exit $code, a reboot may be needed):`n$out" }
        for ($i = 0; $i -lt 30 -and -not ($disk = Get-TargetDisk); $i++) { Start-Sleep 1 }
        if (-not $disk) { throw 'Controller restarted but the disk did not appear within 30 s.' }
    }

    if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
    if ((Get-Disk -Number $disk.Number).IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }

    # Wait up to 30 s for the drive letter
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object DriveLetter) { $ok = $true; break }
        Start-Sleep 1
    }
    if (-not $ok) { throw 'Disk is back but its drive letter did not appear within 30 s.' }

    # Drive's own idle timer: sleep after 10 min without I/O (120 x 5 s).
    # It resets when power is lost, so we set it every time.
    Invoke-Smartctl -s 'standby,120' (Get-SmartPath $disk) | Out-Null

    Set-State 'awake'
    Write-Log 'WAKE ' 'OK - disk is back'
    Show-Message 'Disk is ready.' 'HDD sleep' 64 3
}
catch {
    Write-Log 'WAKE ' "ERROR - $($_.Exception.Message)"
    Show-Message "Error: $($_.Exception.Message)" 'Could not wake the disk' 16
    exit 1
}
