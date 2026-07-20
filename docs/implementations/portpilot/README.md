# PortPilot implementation state

PortPilot is a native, local-only macOS developer utility. Runtime process data flows through injected discovery, process-control, Docker, launch, persistence, security, and health-check services. Verified metadata is retained separately from inferred labels and restart suggestions.

Implemented vertical slices:

- TCP/UDP IPv4/IPv6 discovery with tagged `lsof`, process enrichment, classification, project inference, rolling metadata cache, live diffs, history, notifications, and Docker correlation.
- Dense customizable Active Ports table, process inspector, guarded graceful/force actions, reviewed profile import, command palette, native sidebar, menu bar, accessibility labels, light/dark appearance, and app icon.
- SwiftData schema/migration plan, Keychain secrets, direct/login-shell launching, expected-port conflict/readiness, HTTP health checks, bounded redacted persistent logs, auto-launch, and dependency-layer project orchestration.
- Docker unavailable/daemon/running states, JSON container parsing, published ports, Compose labels, stop/restart, and recent logs.
- Automated parser/domain/persistence/health/security tests plus harmless real-process discovery and termination integration tests.

Validated locally on 2026-07-21 with Xcode 26.4: warning-as-error Debug build succeeded, and 33 of 33 tests passed with zero skips. Manual QA detected ports 49151–49156, including a two-port PID; verified correct executable paths containing spaces; and produced `Documentation/Screenshots/active-ports.png`.

See `Documentation/IMPLEMENTATION_PLAN.md` for delivery history and `Documentation/ARCHITECTURE.md` for durable boundaries and measured overhead.
