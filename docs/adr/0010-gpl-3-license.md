# ADR-0010: GPL-3.0 licence

Status: accepted (2026-09-28).

**Problem.** The repo was public with no LICENSE file, so it wasn't legally open source: nobody could use, change or
share it.

**Decision.** GPL-3.0-only (`LICENSE`, `license = "GPL-3.0-only"` in every crate). Anyone can use, change and share
Lenny; anything shipped that is built on it must stay open source under the GPL too, so nobody can take it closed and
sell it. OBS, the closest neighbour, is GPL as well.

**Why not MIT / Apache-2.0.** Both allow a closed paid fork, which the user doesn't want.

**Compatibility.** Every dependency is MIT, Apache-2.0, BSD, Zlib, ISC or Unicode-3.0 (checked 2026-09-27), all fine
inside a GPL-3.0 program. NSIS (zlib) only builds the installer. OBS's source stays study-only: we copy nothing, so
this doesn't depend on its licence.
