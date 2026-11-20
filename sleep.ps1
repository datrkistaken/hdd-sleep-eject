# Spins the target HDD down and ejects it from Windows (like "Safely Remove Hardware").
# Idea: Windows sends no commands to an ejected device, so maintenance tasks and WMI hardware
# scans can no longer wake the disk up.
# To bring it back: wake.ps1 (restarts the SATA controller).
param([switch]$Quiet)
$script:Quiet = $Quiet
. (Join-Path $PSScriptRoot 'common.ps1')

$wentOffline = $false
try {
    $disk = Get-TargetDisk
    if (-not $disk) {
        # Most likely already ejected. A pulled cable or a driver problem looks the same from here,
        # so the log says "not visible" instead of claiming it is asleep. No command is sent either way.
        Set-State 'asleep'
        Write-Log 'SLEEP' 'disk not visible (already ejected, or disconnected) - nothing done'
        Show-Message 'The disk is not visible: it is already asleep (or disconnected).' 'HDD sleep' 64 3
        exit 0
    }

    # 1) Look everything up while the disk still spins. Between the spin-down and the eject
    #    NOTHING may query the disk (Get-Disk etc. would wake it).
    $letters = Get-DiskLetters $disk
    $path    = Get-SmartPath $disk
    $dev     = Get-TargetDevice
    # Every volume, with or without a drive letter. (An offline disk has no mounted volumes, so nothing can be open on it.)
    $volumes = if ($disk.IsOffline) { @() } else { Get-DiskVolumes $disk }

    # 2) Safety: is anything using the disk? Going offline would force its volumes closed and lose unsaved writes.
    #    a) programs running from it, b) ANY open file on ANY of its volumes (a volume can only be locked when nothing is open)
    $users = Get-CimInstance Win32_Process | Where-Object {
        $p = $_; $letters | Where-Object { ($p.ExecutablePath -like "$($_):\*") -or ($p.CommandLine -like "*$($_):\*") }
    } | Select-Object -ExpandProperty Name -Unique
    $busy = @($volumes | Where-Object { [HddSleepNative]::TryLockVolume($_.Path) -ne 0 } | ForEach-Object Name)
    if ($users -or $busy) {
        $who = @($users) + @(Get-DiskHolders $disk $letters) | Sort-Object -Unique
        $whoText = if ($who) { $who -join "`n" } else { '(unknown program - see README: handle64.exe shows it)' }
        Write-Log 'SLEEP' "CANCELLED - disk in use (open files on: $($busy -join '; ')): $($who -join ', ')"
        $where = if ($busy) { " ($($busy -join '; '))" } else { '' }
        Show-Message "Files on the disk$where are in use by:`n`n$whoText`n`nClose them first, then try again." 'Could not put the disk to sleep' 48
        exit 1
    }

    # 3) Offline FIRST: while closing the volume Windows writes its last NTFS metadata NOW.
    #    If this happened AFTER the spin-down, that write would spin the disk back up, and an
    #    already ejected disk can no longer be told to stop.
    if (-not $disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $true; $wentOffline = $true; Start-Sleep 3 }

    # 4) Stop the motor, eject last
    Invoke-Smartctl -s 'standby,now' $path | Out-Null
    $r = Invoke-Eject $dev
    if (-not $r.Ok) {
        # Undo: bring the disk back online so its drive letter returns (this spins it up again)
        if ($wentOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
        $who = Get-DiskHolders $disk @()
        $whoText = if ($who) { $who -join "`n" } elseif ($r.VetoName) { $r.VetoName } else { '(unknown)' }
        Write-Log 'SLEEP' "CANCELLED - eject vetoed (veto $($r.Veto) $($r.VetoName)), held by: $($who -join ', '); disk set back online"
        Show-Message "Windows could not eject the disk, it is held by:`n`n$whoText`n`nThe disk is back online. Close the program and try again. (An open Task Manager also holds it.)" 'Could not put the disk to sleep' 48
        exit 1
    }

    Set-State 'asleep'
    Write-Log 'SLEEP' 'OK - spun down + ejected'
    Show-Message 'Disk is asleep. (Use "HDD Wake" to bring it back.)' 'HDD sleep' 64 3
}
catch {
    $msg = $_.Exception.Message
    # If we already took the disk offline and it is still here, give its drive letter back
    if ($wentOffline -and $disk -and (Get-TargetDisk)) {
        try { Set-Disk -Number $disk.Number -IsOffline $false; $msg += ' (disk set back online)' } catch { }
    }
    Write-Log 'SLEEP' "ERROR - $msg"
    Show-Message "Error: $msg" 'Could not put the disk to sleep' 16
    exit 1
}
