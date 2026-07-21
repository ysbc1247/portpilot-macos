# DevBerth implementation state

DevBerth is a native, local-only macOS developer utility. Runtime process data flows through injected discovery, process-control, Docker, launch, persistence, security, and health-check services. Verified metadata is retained separately from inferred labels and restart suggestions.

Implemented vertical slices:

- TCP/UDP IPv4/IPv6 discovery with tagged `lsof`, process enrichment, classification, project inference, rolling metadata cache, live diffs, history, notifications, and Docker correlation.
- Dense customizable Active Ports table, process inspector, guarded graceful/force actions, reviewed profile import, command palette, native sidebar, menu bar, accessibility labels, light/dark appearance, and app icon.
- SwiftData schema/migration plan, Keychain secrets, direct/login-shell launching, expected-port conflict/readiness, HTTP health checks, bounded redacted persistent logs, auto-launch, and dependency-layer project orchestration.
- Docker unavailable/daemon/running states, JSON container parsing, published ports, Compose labels, stop/restart, and recent logs.
- Bounded, cycle-safe process lineage; deterministic confidence-labeled ownership conclusions; live managed-runtime reconciliation; bounded ownership-evidence persistence; and a “Why is this running?” inspector.
- Owner-aware lifecycle dispatch for managed services, Docker containers, guarded host processes, Kubernetes port forwards, and SSH tunnels. Compose, Homebrew, launchd, and supervisor actions deliberately refuse without exact controller context instead of signaling an observed PID.
- Four explicit restart-trust states, exact configuration digests, V4 validation persistence, ordinary-launch gating, isolated start/readiness/controlled-stop validation, guided observed-process conversion, and reliable restart of registered verified managed runtimes.
- Keychain-only secret-like environment fields with staged rollback, independent references on duplication, and reference-aware cleanup on edit or deletion.
- Automated parser/domain/persistence/health/security tests plus harmless real-process discovery and termination integration tests.

Validated locally on 2026-07-21 with Xcode 26.4 and Swift 6.3 in Swift 5 language mode: the warnings-as-errors Debug action passed 95 of 95 tests with zero failures or skips, and static analysis succeeded. The suite includes nine harmless real-process integrations, product and genuine V1→V2→V3→V4 migrations, exact trust drift, validation bypass boundaries, normal-launch refusal, stale active-definition restart refusal, Keychain rollback/clone/cleanup, process identity/group safety, deterministic ownership, and exact managed restart. Live dark-appearance QA rendered the trust-aware profile editor and populated 37 active listeners; the accessibility bridge timed out while serializing the selected-listener inspector and therefore does not count as completed inspector accessibility evidence.

The Phase 2 product identity is DevBerth. `ProductIdentity` and `ProductDataMigrator` preserve the legacy store, log, defaults, and Keychain compatibility boundary. The private GitHub repository retains its legacy name until a separate rename is authorized.

Phase 2 domain vocabulary now separates transient `ObservedListener`/`ObservedProcess` evidence from durable `ManagedServiceConfiguration`. V1 `LaunchProfileRecord` naming remains only at the persistence and current-UI compatibility boundary.

The additive V2 schema has independent records for runtime instances, ownership evidence, restart trust, lifecycle events, discovery metadata, sessions, session services, and restore results. V3 adds full fingerprints and controlled-group evidence; V4 adds exact managed-service validation results. Genuine previous-schema fixtures preserve existing data without inventing verification. See `Documentation/DOMAIN_MODEL.md` and `Documentation/RESTART_TRUST_MODEL.md`.

The ownership and restart-reliability slices are complete at their current boundaries. Exact managed registrations and Docker container metadata choose their owner-layer controllers; external PID actions retain the full fingerprint/listener revalidation path. Existing profiles require an exact successful validation before ordinary launch, and inferred processes use the guided conversion workflow. Compose, Homebrew, launchd, and supervisor controllers remain inspection-only pending exact-context discovery. Runtime lifecycle, health, and incident intelligence are the next delivery slice.

See `Documentation/IMPLEMENTATION_PLAN.md` for delivery history and `Documentation/ARCHITECTURE.md` for durable boundaries and measured overhead.
