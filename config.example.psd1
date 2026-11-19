# install.ps1 writes config.psd1 for you into C:\Program Files\hdd-sleep-eject (it lets you pick the disk).
# This file only shows the format, in case you want to write it by hand.
@{
    # Serial number of the HDD to put to sleep (every command checks it first)
    Serial       = 'YOUR_SERIAL'
    # smartmontools install path
    SmartctlPath = 'C:\Program Files\smartmontools\bin\smartctl.exe'
}
