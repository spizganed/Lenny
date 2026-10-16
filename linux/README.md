# Linux receiver

The desktop app (`desktop/`) already runs on Linux: egui over winit, native Wayland and X11 (tested on CachyOS, KDE
Plasma, Wayland). Frames go to a v4l2loopback device (`/dev/video10`, "Lenny").

## Setup (Arch / CachyOS)

```sh
sudo sh linux/setup-cachyos.sh        # v4l2loopback-dkms + headers, load at boot, ufw rules (47474, mDNS)
cargo build --release -p lenny_desktop
target/release/lenny-desktop
```

USB: `adb reverse` is done by the app for authorized phones. Wi-Fi: scan the QR code or use *Find PCs*.
Secure Boot on: the DKMS module has to be MOK-signed.

Other distros: install v4l2loopback and load it with `devices=1 exclusive_caps=1 card_label=Lenny video_nr=10`.
A PipeWire camera backend is a later option. See docs/architecture.md §11.
