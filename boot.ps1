# Runs once at startup (as SYSTEM), then exits. Nothing keeps running in the background.
# Idea: the disk always spins up when it gets power (hardware, can't be avoided). If it was asleep
# before shutdown we put it back to sleep and eject it; if it was awake we only set its idle timer.
$script:Quiet = $true
try { . (Join-Path $PSScriptRoot 'common.ps1') }
catch {
    # Loading failed, so Write-Log may not exist yet: write the error directly (e.g. a broken config.psd1)
    "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') BOOT  ERROR - $($_.Exception.Message)" | Out-File -Append -Encoding utf8 (Join-Path $PSScriptRoot 'log.txt')
    exit 1
}

try {
    # Wait up to 60 s for Windows to see the disk. Early in startup the storage service may not be
    # ready yet and Get-Disk can fail: that just means "not yet", so try again a second later.
    $disk = $null
    for ($i = 0; $i -lt 60 -and -not $disk; $i++) {
        try { $disk = Get-TargetDisk } catch { $lastError = $_.Exception.Message }
        if (-not $disk) { Start-Sleep 1 }
    }
    if (-not $disk) { Write-Log 'BOOT ' "disk did not appear within 60 s, nothing done $lastError"; exit 0 }

    if ((Get-State) -eq 'asleep') {
        Write-Log 'BOOT ' 'last state: asleep -> putting it to sleep'
        & (Join-Path $PSScriptRoot 'sleep.ps1') -Quiet
    } else {
        Invoke-Smartctl -s 'standby,120' (Get-SmartPath $disk) | Out-Null
        Write-Log 'BOOT ' 'last state: awake -> 10 min idle timer set'
    }
}
catch { Write-Log 'BOOT ' "ERROR - $($_.Exception.Message)" }
