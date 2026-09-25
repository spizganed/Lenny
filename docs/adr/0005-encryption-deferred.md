# ADR-0005: Encryption deferred

Status: accepted (revisit any time; no deadline)

**Decision.** Phase 1 ships without transport encryption. Lenny targets home networks.

**Why deferring is safe.** Encryption can be added later as a contained change because three hooks exist from day one
(architecture.md §9): all I/O goes through `ITransport`, HELLO reserves the `TLS_UPGRADE` feature bit for a
STARTTLS-style upgrade, and QR/`device_id` formats accept extra fields. Old and new builds keep interoperating.

**What would make it expensive.** Code that reads or writes sockets outside `transport/`. Reviews must reject that.

**If we add it.** TLS 1.3 via mbedTLS in core, self-signed cert per install, trust via QR fingerprint (no prompt),
short confirm code on first manual connect, auto-trust over ADB. Runtime cost is negligible; it's mostly a few days of dev work.
