# ADR-0004: WiX (MSI) installer, not MSIX

Status: proposed

**Decision.** WiX Toolset v5, producing a per-machine MSI (wrapped in a Burn bundle only if a prerequisite like the VC++ runtime
can't be linked statically).

**Why MSIX doesn't fit.**
- The DirectShow filter must be COM-registered in HKLM for *other* processes (x86 and x64 hives). MSIX's COM
  virtualization only exposes COM servers to the package's own apps and a narrow set of extensions, and
  third-party apps can't enumerate a DShow filter inside an MSIX container.
- We install a broker service (architecture.md §7.3) and a firewall rule. MSIX can't do the firewall rule, and its
  service support is restricted.
- MSIX needs a trusted signing cert even for sideloading. MSI can be unsigned in dev.

**What WiX gives.** Silent `regsvr32`-equivalent via `SelfReg`-free registry tables (cleaner uninstall), both
x86 and x64 filter DLLs in one MSI, service install/remove, firewall exception (private profile), clean
major upgrades. No reboot needed: DShow filters are picked up on next enumeration, and Frame Server loads the MF source
on demand.
