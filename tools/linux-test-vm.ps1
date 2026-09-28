<#
.SYNOPSIS
  One-shot Linux test VM for Lenny on a Windows PC: Hyper-V + Ubuntu 24.04 (Xfce) with v4l2loopback, OBS,
  Discord, Chromium and Lenny Desktop built from a branch. External switch, so the phone reaches the VM directly.

.DESCRIPTION
  No OS installer: it boots Ubuntu's ready-made cloud disk (converted to VHDX with qemu-img) and cloud-init does the
  setup on first boot (20-40 min, then it reboots into the desktop, logged in as lenny/lenny). The script returns as
  soon as the VM is started; the rest happens inside the VM, a hidden helper copies its serial console to serial.log.
  Hyper-V, not VirtualBox: with Hyper-V on (WSL2, VBS/Memory Integrity) a VirtualBox guest stalls (docs/testing.md).
  Secure Boot is off in the VM, because the v4l2loopback DKMS module isn't signed.

  Run from an elevated PowerShell:   powershell -ExecutionPolicy Bypass -File tools\linux-test-vm.ps1
  First run on a PC without Hyper-V enables it and asks for a reboot; run it again afterwards.
  Creating the external switch drops the PC's network for a few seconds.
  Start over:                        Remove-VM lenny-linux -Force; Remove-Item -Recurse "$env:PUBLIC\Documents\Hyper-V\lenny-linux"

  Inside the VM (Xfce menu or a terminal):
    lenny-desktop      the app. Stream card should say "Virtual camera: active" (/dev/video10, "Lenny")
    lenny-fake-phone   synthetic phone streaming to this VM, if no phone is at hand
    lenny-update       git pull + rebuild
  Then pick the "Lenny" camera in OBS (Video Capture Device (V4L2)), Discord (Settings > Voice & Video) or Chromium.
  Phone: same network as the PC, scan the QR code in Lenny Desktop.
#>
param(
    [string]$VmName = "lenny-linux",
    [int]$Cpus = 4,
    [long]$MemoryMB = 8192,
    [int]$DiskGB = 40,
    [string]$Branch = "main",
    [string]$RepoUrl = "https://github.com/spizganed/Lenny.git",
    [string]$SwitchName = "Lenny External",
    [string]$NetAdapter = "",   # default: the adapter that has the default route
    [string]$Dir = "$env:PUBLIC\Documents\Hyper-V\$VmName"   # outside the user profile, Hyper-V's worker must read it
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---- 1. Hyper-V ----
if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State -ne "Enabled") {
    Write-Host "Enabling Hyper-V..."
    $r = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
    if ($r.RestartNeeded) { Write-Host "Hyper-V enabled. Reboot, then run this script again."; exit 0 }
}
Import-Module Hyper-V
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { throw "VM '$VmName' exists. Delete it first (see Start over in the header)." }

# ---- 2. Ubuntu cloud disk -> resized VHDX ----
$qemuImg = "$env:ProgramFiles\qemu\qemu-img.exe"
if (-not (Test-Path $qemuImg)) {
    Write-Host "Installing QEMU for qemu-img (winget)..."
    winget install -e --id SoftwareFreedomConservancy.QEMU --silent --accept-package-agreements --accept-source-agreements
    if (-not (Test-Path $qemuImg)) { throw "qemu-img not found at $qemuImg" }
}
New-Item -ItemType Directory -Force $Dir | Out-Null
$img = Join-Path $Dir "noble-cloudimg.img"
$vhdx = Join-Path $Dir "$VmName.vhdx"
if (-not (Test-Path $img)) {
    Write-Host "Downloading Ubuntu 24.04 cloud image (~600 MB)..."
    curl.exe -fL -o $img "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    if ($LASTEXITCODE) { throw "download failed" }
}
& $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $img $vhdx
if ($LASTEXITCODE) { throw "qemu-img convert failed" }
# qemu-img writes a sparse file; Hyper-V refuses to resize one (0xC03A001A).
fsutil sparse setflag $vhdx 0 | Out-Null
Resize-VHD -Path $vhdx -SizeBytes ([long]$DiskGB * 1GB)

# ---- 3. cloud-init seed ISO (NoCloud, volume label "cidata") ----
$userData = @"
#cloud-config
hostname: lenny-vm
users:
  - name: lenny
    gecos: Lenny tester
    groups: [sudo, video, audio]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: lenny
growpart: {mode: auto, devices: ['/']}
package_update: true
packages:
  - xserver-xorg
  - xfce4
  - xfce4-terminal
  - lightdm
  - lightdm-gtk-greeter
  - dbus-x11
  - obs-studio
  - ffmpeg
  - v4l-utils
  - build-essential
  - pkg-config
  - git
  - curl
  - libxkbcommon-x11-0
  - libgl1
  - mesa-utils
write_files:
  - path: /etc/modules-load.d/lenny.conf
    content: "v4l2loopback\n"
  - path: /etc/modprobe.d/lenny.conf
    content: "options v4l2loopback devices=1 video_nr=10 exclusive_caps=1 card_label=Lenny\n"
  - path: /etc/lightdm/lightdm.conf.d/50-lenny.conf
    content: "[Seat:*]\nautologin-user=lenny\nautologin-session=xfce\n"
  - path: /usr/local/bin/lenny-desktop
    permissions: '0755'
    content: "#!/bin/sh\nexec /home/lenny/Lenny/target/release/lenny-desktop \"`$@\"\n"
  - path: /usr/local/bin/lenny-fake-phone
    permissions: '0755'
    content: "#!/bin/sh\nexec /home/lenny/Lenny/target/release/examples/fake_phone 127.0.0.1 47474 \"`$@\"\n"
  - path: /usr/local/bin/lenny-update
    permissions: '0755'
    content: "#!/bin/sh\nset -e\ncd /home/lenny/Lenny && git pull && ~/.cargo/bin/cargo build --release -p lenny_desktop --bins --examples\n"
  - path: /usr/share/applications/lenny-desktop.desktop
    content: "[Desktop Entry]\nType=Application\nName=Lenny Desktop\nExec=lenny-desktop\nIcon=camera-web\nCategories=AudioVideo;\n"
  - path: /usr/share/applications/lenny-fake-phone.desktop
    content: "[Desktop Entry]\nType=Application\nName=Lenny fake phone\nExec=lenny-fake-phone\nTerminal=true\nIcon=phone\nCategories=AudioVideo;\n"
runcmd:
  # the cloud image's kernel leaves videodev (needed by v4l2loopback) in linux-modules-extra
  - apt-get install -y linux-headers-`$(uname -r) linux-modules-extra-`$(uname -r) v4l2loopback-dkms
  - curl -fL -o /tmp/discord.deb 'https://discord.com/api/download?platform=linux&format=deb' && apt-get install -y /tmp/discord.deb
  - snap install chromium
  - su - lenny -c 'curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal'
  - su - lenny -c 'git clone -b $Branch $RepoUrl Lenny && cd Lenny && ~/.cargo/bin/cargo build --release -p lenny_desktop --bins --examples'
power_state: {mode: reboot, message: "Lenny test VM ready, rebooting into the desktop", timeout: 30}
"@
$seedDir = Join-Path $Dir "seed"
New-Item -ItemType Directory -Force $seedDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM: cloud-init needs "#cloud-config" as the first bytes
[IO.File]::WriteAllText((Join-Path $seedDir "user-data"), $userData.Replace("`r`n", "`n"), $utf8)
[IO.File]::WriteAllText((Join-Path $seedDir "meta-data"), "instance-id: $VmName-1`nlocal-hostname: lenny-vm`n", $utf8)

Add-Type -TypeDefinition @"
public static class IsoWriter {
    public static void Save(object stream, string path, int blockSize, int blocks) {
        var s = (System.Runtime.InteropServices.ComTypes.IStream)stream;
        var buf = new byte[blockSize];
        using (var o = System.IO.File.Create(path)) {
            for (int i = 0; i < blocks; i++) { s.Read(buf, blockSize, System.IntPtr.Zero); o.Write(buf, 0, blockSize); }
        }
    }
}
"@
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet (keeps the "user-data" name)
$fsi.VolumeName = "cidata"
$fsi.Root.AddTree($seedDir, $false)
$isoImg = $fsi.CreateResultImage()
$iso = Join-Path $Dir "seed.iso"
[IsoWriter]::Save($isoImg.ImageStream, $iso, $isoImg.BlockSize, $isoImg.TotalBlocks)

# ---- 4. External switch on the PC's LAN adapter, so the phone reaches the VM at its own IP ----
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    if (-not $NetAdapter) {
        $route = Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
        $NetAdapter = (Get-NetAdapter -InterfaceIndex $route.ifIndex).Name
    }
    Write-Host "Creating external switch on '$NetAdapter' (network drops for a few seconds)..."
    New-VMSwitch -Name $SwitchName -NetAdapterName $NetAdapter -AllowManagementOS $true | Out-Null
}

# ---- 5. VM (Gen 2, Secure Boot off) ----
New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($MemoryMB * 1MB) -VHDPath $vhdx -SwitchName $SwitchName -Path (Split-Path $Dir) | Out-Null
Set-VM -Name $VmName -ProcessorCount $Cpus -StaticMemory -CheckpointType Disabled -AutomaticCheckpointsEnabled $false
Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
Add-VMDvdDrive -VMName $VmName -Path $iso
$pipe = "\\.\pipe\$VmName-com1"
Set-VMComPort -VMName $VmName -Number 1 -Path $pipe
Start-VM -Name $VmName

# serial console -> serial.log, in a hidden helper that ends when the VM stops
$log = Join-Path $Dir "serial.log"
$reader = "`$p = New-Object IO.Pipes.NamedPipeClientStream('.', '$VmName-com1', 'In'); `$p.Connect(60000); " +
          "`$f = [IO.File]::Open('$log', 'Append', 'Write', 'ReadWrite'); `$p.CopyTo(`$f); `$f.Close()"
Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile", "-Command", $reader

Write-Host ""
Write-Host "VM started. First boot sets everything up (20-40 min), then reboots into the Xfce desktop as lenny/lenny."
Write-Host "Progress: $log  (look for 'Lenny test VM ready')"
Write-Host "Screen: vmconnect localhost $VmName   (or Hyper-V Manager)"
Write-Host "Then: menu > Lenny Desktop. The phone must be on the same network as this PC."
