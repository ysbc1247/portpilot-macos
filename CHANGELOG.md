# Changelog

## 0.3.0 — 2026-07-21

- Fixed expected-port activity presentation and per-service project controls, repaired bounded lifecycle-history retention/rendering, and made Docker discovery reliable from GUI PATHs without blocking passive monitoring on Compose verification.
- Added a complete MCP control plane with 82 production tools, 12 Debug-only development tools, 11 resources/templates, and 10 prompts through the official Swift MCP SDK 0.12.1 and MCP protocol 2025-11-25.
- Added an app-owned `ApplicationControlPlane`, current-user Unix-domain IPC, structured response/error envelopes, stable revisions, bounded audit records, expiring single-use operation/change-set previews, and optimistic concurrency.
- Added additive SwiftData schema V7 for control-plane revisions, organization/settings records, and MCP audit metadata, with a tested V6→V7 migration.
- Added project, managed-service, runtime/ownership, session, port, Docker/Compose, history/log, settings, favorites/tag/filter, destructive-operation, and coordinated-change-set parity.
- Added the protocol-only `devberth-mcp` executable, stable helper installation, atomic Codex TOML configuration, and Settings → Integrations → Codex & MCP.
- Added an isolated Debug development host, application-owned fixture catalog, real nine-scenario acceptance runner, parity/migration/performance diagnostics, and disposable reset. Release builds reject development mode and expose no `dev_*` tools.
- Hardened all hosted tests to use in-memory data, no control socket, and empty or test-owned discovery; scoped development discovery before metadata enrichment and moved blocking Unix-socket I/O off Swift’s cooperative executor.

## 0.2.0 — 2026-07-21

- Renamed the product from PortPilot to DevBerth while preserving legacy stores, defaults, service logs, bundle compatibility, and Keychain references through a tested one-way copy migration.
- Separated observed listeners/processes from reviewed managed-service intent, runtime instances, ownership evidence, restart trust, discovery evidence, workspace sessions, and lifecycle events across immutable SwiftData schemas V2–V6.
- Added strong process fingerprints, listener-edge revalidation, dedicated POSIX process groups, descendant tracking, owner-aware lifecycle routing, protected-process refusal, and fresh checks before every TERM/KILL or force escalation.
- Added exact isolated managed-service validation, configuration-digest restart trust, safe observed-process conversion, transactional Keychain editing, bounded chunk-safe secret redaction, richer readiness/health checks, automatic-restart limits, and incident summaries.
- Added review-only discovery for JavaScript package managers, Gradle, Maven, Python, Go, Cargo, Docker Compose, Procfile, Process Compose, and the versioned redacted DevBerth manifest.
- Added transactional workspace sessions with drift comparison, dry-run preview, fresh preflight, dependency-layer restore, and scoped rollback.
- Added batched Docker Engine inspection and exact, freshly reverified Compose project/service/file/environment/hash/membership scopes for mutations; one-offs and incomplete contexts remain inspection-only.
- Rebuilt the native product around Runtime, Projects, Sessions, Managed Services, History, Docker, and Settings, with saved Runtime views, table/project layouts, resource evidence, multi-selection, complete ownership/trust/lifecycle inspection, onboarding, menu-bar workflows, and an expanded command palette.
- Batched lifecycle/history persistence, bounded lifecycle pruning, append-and-rotate log persistence, transient batched CPU/memory readings, UI-test data isolation, repeatable soak/performance tests, and comprehensive product/security/privacy architecture documentation.

## 0.1.0 — 2026-07-21

- Added native TCP/UDP listener discovery, process metadata, project inference, classification, real-time diff monitoring, search, filtering, sorting, column customization, and inspectors.
- Added protected graceful/force process control with identity revalidation and local history.
- Added reviewed launch profiles, Keychain secrets, expected-port preflight/readiness, health checks, dependency-aware projects, redacted bounded logs, and auto-launch.
- Added Docker availability, published-port mapping, Compose metadata, stop/restart/log actions, and listener association.
- Added Overview, Projects, Launch Profiles, History, Docker, Settings, command palette, menu bar, launch-at-login, notifications, diagnostics, dark/light appearance, accessibility labels, and app icon.
- Added parser fixtures, harmless development services, 33 automated tests, monitoring benchmark, GitHub Actions, and project/security/privacy documentation.
