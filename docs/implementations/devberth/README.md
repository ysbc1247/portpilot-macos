# DevBerth implementation state

DevBerth is a native, local-only macOS developer utility. Runtime process data flows through injected discovery, process-control, Docker, launch, persistence, security, and health-check services. Verified metadata is retained separately from inferred labels and restart suggestions.

Implemented vertical slices:

- TCP/UDP IPv4/IPv6 discovery with tagged `lsof`, process enrichment, classification, project inference, rolling metadata cache, live diffs, history, notifications, and Docker correlation.
- Dense customizable Active Ports table, process inspector, guarded graceful/force actions, reviewed profile import, command palette, native sidebar, menu bar, accessibility labels, light/dark appearance, and app icon.
- SwiftData schema/migration plan, Keychain secrets, direct/login-shell launching, expected-port conflict/readiness, HTTP health checks, bounded redacted persistent logs, auto-launch, and dependency-layer project orchestration.
- Docker unavailable/daemon/running states, JSON container parsing, published ports, Compose labels, stop/restart, and recent logs.
- Bounded, cycle-safe process lineage; deterministic confidence-labeled ownership conclusions; live managed-runtime reconciliation; bounded ownership-evidence persistence; and a “Why is this running?” inspector.
- Owner-aware lifecycle dispatch for managed services, Docker containers, guarded host processes, Kubernetes port forwards, and SSH tunnels. Compose, Homebrew, launchd, and supervisor actions deliberately refuse without exact controller context instead of signaling an observed PID.
- Automated parser/domain/persistence/health/security tests plus harmless real-process discovery and termination integration tests.

Validated locally on 2026-07-21 with Xcode 26.4 and Swift 6.3 in Swift 5 language mode: the warnings-as-errors Debug test action passed 79 of 79 tests with zero failures or skips, and static analysis succeeded. The suite includes rename/data migration, V1→V2→V3 migration, corrupt-store rollback, separated Phase 2 records, Keychain compatibility, full fingerprint/process-group safety, ownership classification and routing, newest-1,000 ownership retention, nine harmless real-process integration tests, and verified cleanup of test fixtures. Manual Phase 1 QA detected ports 49151–49156, including a two-port PID; verified correct executable paths containing spaces; and produced `Documentation/Screenshots/active-ports.png`.

The Phase 2 product identity is DevBerth. `ProductIdentity` and `ProductDataMigrator` preserve the legacy store, log, defaults, and Keychain compatibility boundary. The private GitHub repository retains its legacy name until a separate rename is authorized.

Phase 2 domain vocabulary now separates transient `ObservedListener`/`ObservedProcess` evidence from durable `ManagedServiceConfiguration`. V1 `LaunchProfileRecord` naming remains only at the persistence and current-UI compatibility boundary.

The additive V2 schema now has independent records for runtime instances, ownership evidence, restart trust, lifecycle events, discovery metadata, sessions, session services, and restore results. Fixture and local-store migration preserve V1 data; these tables do not imply their later controllers or UI are complete. See `Documentation/DOMAIN_MODEL.md`.

The ownership slice is complete at the current controller boundary. Exact managed registrations and Docker container metadata choose their owner-layer controllers; external PID actions retain the full fingerprint/listener revalidation path. Compose, Homebrew, launchd, and supervisor controllers remain inspection-only pending exact-context discovery. Restart trust and managed-service conversion are the next delivery slice.

See `Documentation/IMPLEMENTATION_PLAN.md` for delivery history and `Documentation/ARCHITECTURE.md` for durable boundaries and measured overhead.
