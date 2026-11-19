# hdd-sleep-eject

Stop an idle internal hard disk's **noise and vibration** on Windows: put it **to sleep and keep it asleep**, then bring it back with one click, no reboot needed.

## Why I made this

After moving my system and everyday files to an M.2 NVMe drive, I barely used my old HDD anymore.
It just sat there holding a few games and archives. But even while idle it kept making a quiet, constant hum,
and lately that started to bother me. Windows' own settings didn't keep it asleep, so I built this:
one click to put the disk to sleep and keep it silent, and one click to bring it back when I need it.

## The problem

You have an internal HDD you only use sometimes (games, archives), and its constant hum is annoying.
The usual fixes don't hold:

- **Windows power plan "turn off hard disk after"** often doesn't spin the disk down at all.
- **Spinning it down yourself** (`smartctl -s standby,now`) works for a while, but Windows wakes it again
  roughly every hour: idle maintenance tasks and WMI hardware-inventory queries
  (`Win32_DiskDrive`, `Win32_PhysicalMedia`) talk to the disk directly.
- **Setting the disk offline** only hides the file system. Those queries still reach the hardware.

(How I tracked this down is in [How I found the cause](#how-i-found-the-cause).)

## The fix

Spin the disk down, then **eject** it like a USB stick. Windows sends nothing to an ejected device, so nothing can wake it.
To bring it back, **restart the SATA controller** it's attached to. That's the software version of
unplugging and replugging the cable, and the disk is usable again within a few seconds.

| Script | What it does |
|---|---|
| `sleep.ps1` | Refuses if any file on the disk is open (it test-locks the volume), then sets it **offline**, spins it down (`standby,now`) and ejects it (`CM_Request_Device_EjectW`). The order matters: going offline writes NTFS metadata, so if it ran after the spin-down it would wake the disk again. |
| `wake.ps1` | Restarts the disk's SATA controller (`pnputil /restart-device`), brings the disk online, sets its idle timer to 10 min. |
| `boot.ps1` | Runs once at startup. If the disk was asleep before shutdown it puts it back to sleep, otherwise it just sets the idle timer. The disk always spins for ~1 min at power-on, which can't be avoided. |
| `install.ps1` | Lets you pick the disk, checks that it can work, copies the scripts to `C:\Program Files\hdd-sleep-eject`, then registers the scheduled tasks and creates the **HDD Sleep / HDD Wake** desktop shortcuts. The shortcuts run elevated tasks, so you get no UAC prompt after setup. |

Every command first checks the disk's **serial number**, so a renumbered disk is never touched by mistake.

## Requirements

- Windows 10/11, Windows PowerShell 5.1, admin rights for the install.
- **Hot Plug enabled in the BIOS/UEFI for the disk's SATA port.** Without it Windows treats the disk
  as non-removable and refuses to eject it. Setup checks this for you. See [Enabling Hot Plug](#enabling-hot-plug).
- **The disk must be the only device on its SATA controller.** `wake.ps1` restarts the whole controller,
  so it refuses to run if anything else is attached. Setup checks this too. Disks on a different controller (e.g. NVMe) are unaffected.
  This was true on the machine this was built on (AMD B450). It may not be true on yours.
- [smartmontools](https://www.smartmontools.org/), e.g. `winget install smartmontools.smartmontools`
- Optional: [Sysinternals Handle](https://learn.microsoft.com/sysinternals/downloads/handle) by Microsoft. With it, a
  blocked sleep tells you *which program* is holding the disk. Setup offers to install it for you via winget
  (`winget install Microsoft.Sysinternals.Handle`), or you can put `handle64.exe` next to `install.ps1`.
  It isn't included here because its license doesn't allow redistribution.

## Enabling Hot Plug

Most desktop motherboards have a **Hot Plug** setting for each SATA port, and it is usually off by default.
Menus differ between vendors and BIOS versions, but it should look something like this:

1. Find out which SATA port the disk is on. The BIOS usually has a SATA information screen that lists each port with
   the disk model connected to it.
2. Enter the BIOS/UEFI setup (usually **Del** or **F2** at power-on) and switch to the advanced mode if there is one.
3. Look for the SATA or storage settings, often called **SATA Configuration** or **Storage Configuration**
   (on some boards under *Integrated Peripherals* or *IO Ports*).
4. Set **Hot Plug** to **Enabled** for that disk's port, then save and exit.

Only enable it for the port of the disk you want to sleep. After the reboot, run setup. The Hot Plug check should now pass.
If you can't find the setting, search for "&lt;your motherboard model&gt; SATA hot plug". Some boards, especially laptops,
don't have it at all, and then this tool can't work on that disk.

## Tested on

| | |
|---|---|
| OS | Windows 11 Pro 25H2 (build 26200), Windows PowerShell 5.1 |
| Motherboard | AMD B450 chipset, disk on the chipset's SATA controller, Hot Plug enabled for that port |
| Disk | Seagate BarraCuda 1 TB HDD (ST1000DM010) |
| Windows disk | NVMe SSD on a separate controller (unaffected by the controller restart) |
| smartmontools | 7.5 |

Other hardware should work if setup's checks pass, but it hasn't been tried yet. Reports are welcome.

## Install

In an **administrator** PowerShell, from this folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Setup lists your disks and lets you pick one. The Windows disk is never offered. Then it checks everything
the tool needs, **before** installing anything:

```
Which disk should be put to sleep?

  [0] ST1000DM010-2EP102              932 GB  HDD   SATA  D:     serial XXXXXXXX
  (Disk 1 Samsung SSD 980 PRO 1TB is the Windows disk - hidden)

Enter disk number (Q to quit): 0

Checking disk 0 (ST1000DM010-2EP102)...
  [OK  ] Serial number - XXXXXXXX
  [OK  ] Hot Plug - disk is removable
  [OK  ] SATA controller - only this disk is attached to it
  [OK  ] smartctl - reaches the disk as /dev/pd0
  [OK  ] Page file - none on this disk

All checks passed. Install for disk 0 (ST1000DM010-2EP102)? (Y/N)
```

If a check fails, it tells you why and installs nothing. Run it again any time to pick another disk.

The scripts are installed to **`C:\Program Files\hdd-sleep-eject`**, and that copy is the one that runs. This is a security
measure: the tasks run the scripts as admin without asking, so the scripts must sit where only admins can change them.
If they ran from your download folder, any program running as you could edit them and get admin rights that way.
After updating or editing the scripts, run `install.ps1` again to update the installed copy.

Your choice is saved in `config.psd1` and every sleep/wake is logged to `log.txt`, both in that folder.

## Known gotchas

- **Task Manager blocks the eject.** Its Performance tab keeps the physical disk open, so close it before using HDD Sleep. If an eject is refused, the disk is put back online and nothing changes.
- Programs using the disk (Steam libraries, an open video, a download) must be closed. `sleep.ps1` checks for open files and refuses otherwise. An Explorer window showing the disk is fine.
- If a controller restart ever fails, Windows may mark it "reboot required". After that, live re-attach
  won't work until you reboot once.
- Polling the disk (e.g. `smartctl -i`) wakes it up. To check without waking it: `smartctl -n standby -i /dev/pdN`
  (exit code 2 means it's in standby).

## Uninstall

```powershell
'HDD sleep','HDD wake','HDD sleep boot' | % { Unregister-ScheduledTask -TaskName $_ -Confirm:$false }
Remove-Item "$([Environment]::GetFolderPath('Desktop'))\HDD Sleep.lnk","$([Environment]::GetFolderPath('Desktop'))\HDD Wake.lnk"
Remove-Item -Recurse "$env:ProgramFiles\hdd-sleep-eject"
```
Run it in an administrator PowerShell. If the disk is asleep at that moment, run HDD Wake first.

## How I found the cause

I didn't want to guess, so I measured it:

1. **When does it wake up?** `smartctl -n standby -i /dev/pdN` reads the disk's power state **without waking it**
   (exit code 2 = in standby). A small loop checking this every 30 s and logging each change showed that the
   disk, even when spun down and set offline, woke up again **roughly every hour**.
2. **Who wakes it?** A kernel file-I/O trace showed who opens the physical disk device right before a wake-up:
   ```powershell
   # admin PowerShell: start the trace, wait for a wake-up, then stop it
   logman start diskwake -p "{EDD08927-9CC4-4E65-B970-C2560FB5C289}" 0x80 -o "$env:TEMP\diskwake.etl" -ets
   logman stop diskwake -ets
   # list who opened a physical disk (event 12 = file create, \Device\HarddiskN\DRN = the raw disk)
   Get-WinEvent -Path "$env:TEMP\diskwake.etl" -Oldest |
     Where-Object { $_.Id -eq 12 -and $_.Properties[6].Value -match 'Harddisk\d+\\DR' } |
     Select-Object TimeCreated, ProcessId, @{ n = 'Device'; e = { $_.Properties[6].Value } }
   ```
   Match `ProcessId` to a name with `Get-Process -Id <id>` while the process is still running.
   The trace logs every file open, so keep it short (minutes, not hours).
   It was `WmiPrvSE.exe`, opening the disk 3 seconds before it spun up. That is WMI answering a
   hardware query like `Win32_DiskDrive`. The `Microsoft-Windows-WMI-Activity/Trace` log then showed
   which queries ran and who sent them: Windows' own **idle maintenance** (servicing/NGEN work,
   SilentCleanup, MemoryDiagnostic tasks) taking a hardware inventory with `Win32_PhysicalMedia` and similar.
3. **Ruled out** along the way: Steam, the search indexer, the Microsoft Store, the SSD vendor's tool.
   The wake-ups continued with each of them stopped.

Conclusion: the wake-ups come from Windows itself and can't be turned off one by one. Setting the disk
offline doesn't help, because these queries go to the hardware, not the file system. The only reliable
fix is to make the disk not exist for Windows while it sleeps. After switching to eject, the same
monitoring loop showed **zero** wake-ups during a 30-minute test (before that, the disk woke several times
in the same amount of time).

## Disclaimer

This sends low-level commands to a disk and restarts a storage controller. It worked on one machine.
Read the scripts, and don't use it on a disk holding your only copy of anything. MIT licensed, no warranty.
