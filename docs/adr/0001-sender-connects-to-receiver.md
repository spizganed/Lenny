# ADR-0001: Sender connects to receiver

Status: proposed

**Decision.** The phone always opens the TCP connection. The desktop always listens on 47474.

**Why.**
- One code path for every transport: Wi-Fi (phone → PC IP), USB tethering (phone → PC's RNDIS IP),
  ADB (`adb reverse`, phone → localhost).
- The desktop knows its own IPs, so it can show them in a QR code. The phone can't show a QR code to a PC
  that has no camera.
- Only the desktop needs a firewall rule, and the installer adds it (private networks only).

**Cost.** The desktop's "device list" shows phones that are connecting or connected, plus phones it has seen via ADB
or `_lenny-sender._tcp`. It doesn't show phones it could dial.
