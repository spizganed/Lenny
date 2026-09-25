# ADR-0002: Riverpod for state management

Status: proposed

**Decision.** Riverpod (with `riverpod_generator`), not Bloc.

**Why.**
- Most state here is service-backed streams (connection state, stats, discovered devices). `StreamProvider`/`Notifier`
  map onto that directly, while Bloc would add an event class and state class per feature for no gain.
- Services become providers, so tests override them (fake `CoreService`) without a DI framework.
- Compile-time safe, no `BuildContext` needed to read state from services.

**Rule.** `lib/ui/**` may import `state/` only, never `services/`, `dart:ffi` or `package:flutter/services.dart`
channels. This is enforced by lint.
