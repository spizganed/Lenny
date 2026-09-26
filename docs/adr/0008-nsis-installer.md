# ADR-0008: NSIS installer, not WiX (MSI) or MSIX

Status: accepted (2026-09-27). Supersedes ADR-0004.

**Decision.** NSIS (Nullsoft Scriptable Install System), producing one per-machine setup `.exe` that runs as admin. One
`.nsi` script holds both install and uninstall logic; the installer writes `uninstall.exe` at install time.

**Why NSIS.**
- Licence: zlib. Free for any use (personal, commercial, organisations), no revenue threshold, no fees, no EULA
  conditions. Lenny stays free, funded only by optional donations (GitHub Sponsors, Ko-fi), and the installer tool never
  becomes a licensing concern, even if a company is registered later.
- Every requirement below is covered by built-in commands and tools that ship with Windows. No paid plugins.

**Why not WiX.**
- WiX v3/v4/v5 are out of community support.
- WiX v6+ binaries fall under the Open Source Maintenance Fee for organisations with more than $10k/year revenue. Free
  for us today, but it's a licensing condition we want to avoid for good.

**Why not MSIX** (unchanged from ADR-0004).
- The virtual camera DLL must be COM-registered in HKLM for *other* processes (x86 and x64 hives). MSIX's COM
  virtualization only exposes COM servers to the package's own apps and a narrow set of extensions, so third-party apps
  can't enumerate a DShow filter inside an MSIX container.
- We install a broker service (architecture.md §7.3) and a firewall rule. MSIX can't do the firewall rule, and its
  service support is restricted.
- MSIX needs a trusted signing cert even for sideloading.

**How NSIS covers each requirement.**
- Admin, per-machine: `RequestExecutionLevel admin`, install to Program Files (64-bit).
- COM registration: `lenny_vcam_com.dll` holds both classes (DirectShow filter and MF media source), built twice.
  - x64 DLL: 64-bit regsvr32. NSIS is a 32-bit process, so call `$WINDIR\Sysnative\regsvr32.exe` (or wrap in
    `${DisableX64FSRedirection}`), otherwise it silently lands in the 32-bit hive.
  - x86 DLL: `$WINDIR\SysWOW64\regsvr32.exe`.
  - Uninstall runs `regsvr32 /u` on both before deleting them.
- Broker service (§7.3, ADR-0009): `sc.exe create` / `net start` on install, `net stop` / `sc.exe delete` on uninstall.
- Firewall rule: one inbound allow rule for `lenny-desktop.exe`, **all profiles** (`netsh advfirewall firewall add rule
  ... program=... profile=any`), `delete rule` on uninstall. Amended 2026-09-27 from "ports 47474, private profile
  only": Windows 11 marks new Wi-Fi networks Public, so a private-only rule silently blocked the phone on a real home
  network. App-scoped on every profile is what Windows' own "Allow" prompt creates; unknown phones still need the
  user's approval or the QR token.
- MF virtual camera: nothing to install. The app calls `MFCreateVirtualCamera` at runtime (Session lifetime), and Frame
  Server loads the media source on demand. No reboot: DShow filters are picked up on next enumeration.
- Add/Remove Programs: HKLM `...\Uninstall\Lenny` keys (DisplayName, DisplayVersion, Publisher, UninstallString,
  QuietUninstallString, InstallLocation).
- Upgrades: read the existing install from that Uninstall key; if present, stop the service and run the old uninstaller
  silently (`/S _?=$INSTDIR`) before installing.
- Silent install/uninstall: `/S`.

**Trade-offs accepted.**
- An `.exe`, not an MSI: no Group Policy / MSI-based enterprise deployment. Fine for a free consumer app.
- Uninstall and upgrade logic is hand-written (roughly 50-100 more lines than WiX). Every install step needs a matching
  uninstall step: keep each pair next to each other in the script and review them together.
- No automatic rollback on a failed install. Order steps so failures come early (file copy, then registration, service,
  firewall), and make the uninstaller tolerate a partial install (ignore "not found").
- The COM DLL can be loaded in a running Zoom/Teams/Chrome during uninstall or upgrade, so it can't be deleted. Use
  `Delete /REBOOTOK` for it (after unregistering), and install new versions over a locked DLL with the same flag.

**Code signing.** Unsigned installers trigger SmartScreen (MSI too). Fine in dev; before public release look at a free
or low-cost option such as SignPath Foundation for open-source projects.
