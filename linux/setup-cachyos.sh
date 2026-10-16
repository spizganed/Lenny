#!/bin/sh
# One-time setup for Lenny on Arch/CachyOS (KDE, Wayland or X11). Run with: sudo sh linux/setup-cachyos.sh
set -e
pacman -S --needed --noconfirm v4l2loopback-dkms v4l2loopback-utils linux-cachyos-headers linux-cachyos-lts-headers
echo v4l2loopback > /etc/modules-load.d/v4l2loopback.conf
echo 'options v4l2loopback devices=1 exclusive_caps=1 card_label=Lenny video_nr=10' > /etc/modprobe.d/v4l2loopback.conf
modprobe v4l2loopback
# Phone connects over TCP/UDP 47474; discovery uses mDNS (5353/udp).
if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow 47474 comment Lenny
  ufw allow 5353/udp comment mDNS
fi
echo "ok: /dev/video10 'Lenny'"
