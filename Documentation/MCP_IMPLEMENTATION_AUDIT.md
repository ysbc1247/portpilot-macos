# MCP implementation audit

Date: 2026-07-21 (Asia/Seoul)

## Scope and baseline

This audit covers the Phase 2 application at commit `7ec17bf46ffc0bfffdc8cb3363b211c7228f113e` on `phase-2-differentiation`. Phase 3 work continues on `phase-3-full-mcp-control-plane`.

The repository is private (`ysbc1247/portpilot-macos`) and its default branch is `main`. The product is DevBerth, bundle identifier `com.ysbc.devberth`, with a macOS 14 deployment target. The app has Hardened Runtime enabled and App Sandbox disabled. It installs no privileged helper and has no network service.

Baseline validation before Phase 3 changes:

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DevBerth.xcodeproj -alltargets -destination 'platform=macOS' build` passed for the four existing targets.
- The full test command built all test targets but the UI runner failed to initialize automation mode after 84.9 seconds. This is a host UI-automation failure, not a test assertion: `The test runner failed to initialize for UI testing. Timed out while enabling automation mode.`
- A second baseline run excluding only `DevBerthUITests` was started to measure unit and integration health independently; its final result is recorded in `MCP_ACCEPTANCE_RESULTS.md` after completion.
- The local machine uses Xcode 26.4 and Apple Swift 6.3. The repository remains constrained to its Xcode 16.4 CI baseline and Swift language mode 5 unless a target explicitly requires Swift 6.
- The shell's default active developer directory points to Command Line Tools. All Xcode validation must set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Existing target and source layout

The generated Xcode project currently has one application target and three test bundles:

| Target | Purpose |
| --- | --- |
| `DevBerth` | SwiftUI application, domain composition, persistence, runtime control |
| `DevBerthTests` | Unit, migration, security, lifecycle, discovery, Docker, and soak tests |
| `DevBerthIntegrationTests` | Application-owned process/listener fixtures |
| `DevBerthUITests` | Production-data-isolated navigation and UI checks |

There is no MCP, CLI, XPC, Unix-socket, or other IPC implementation. There is no package dependency.

The source tree already separates transient domain values (`DevBerth/Domain`), SwiftData records (`DevBerth/Persistence`), system adapters and coordinators (`DevBerth/Services`), app composition (`DevBerth/App`), and SwiftUI presentation (`DevBerth/Features`, `DevBerth/SharedUI`). That separation is sufficient to add a contracts target without moving the shipped domain model or duplicating it in the MCP process.

## Single sources of truth

| Concern | Current authority | Phase 3 implication |
| --- | --- | --- |
| Listener/process snapshot | One `PortMonitor` composed by `AppModel` | The host returns this snapshot; MCP never runs `lsof` or `ps`. |
| Resource usage | One bounded `ProcessResourceUsageReading` batch per refresh | MCP reads the app's cached evidence. |
| Runtime ownership | `RuntimeOwnershipResolving` and persisted conclusions | MCP explanations and actions use the same graph and evidence. |
| Process and supervisor actions | `OwnerAwareLifecycleRouting` | MCP never accepts raw PID authority. |
| Managed launch/stop/restart | `LaunchProfileServing`, `ProjectOrchestrator`, restart-trust gate | MCP commands enter the same service path. |
| Validation | `ManagedServiceValidating` and `RestartTrustStoring` | MCP cannot mark a service verified directly. |
| Sessions | `WorkspaceSessionCoordinator` | Preview/restore semantics, preflight, and rollback stay shared. |
| Docker | `DockerServing` and `DockerAssociationProvider` | MCP does not add polling or raw CLI access. |
| Secrets | `SecretStoring` (`KeychainSecretStore` in production) | MCP exposes references and resolution status only. |
| Persistent configuration | The app's single V6 `ModelContainer` | The app-owned control host is the only Phase 3 writer. |
| In-memory logs | `ServiceLogBuffer` | MCP reads bounded, redacted entries through the host. |

`AppModel` is `@MainActor` and currently composes all live services. Discovery, launching, lifecycle tracking, service checks, process control, Docker, logs, sessions, and persistence are actor-isolated. SwiftUI views use `@Query` for live data and some views write through the environment `ModelContext`. Runtime actions already route through `AppModel`. Phase 3 must add an application command/query facade and migrate user-facing writes to it incrementally; MCP calls must never manipulate the store directly.

## Persistence and migration audit

`DevBerthSchemaV1` through `DevBerthSchemaV6` are shipped and immutable.

- V1: projects, launch profiles, dependencies, expected ports, compatibility history, observations, preferences, favorites, log metadata.
- V2: runtime instances, ownership evidence, restart trust, sessions, restore results, discovery metadata, lifecycle events.
- V3: full process fingerprints, managed process policies, process-group snapshots.
- V4: exact managed-service validation result.
- V5: lifecycle context and incident summaries.
- V6: reviewed service-check sidecars.

V7 is required for control-plane revisions and organization entities that did not exist in Phase 2. It must be additive, have an explicit V6-to-V7 migration stage, and be covered by a genuine V6 fixture. Operation and change-set tokens remain ephemeral and must not be durable authority.

## Process identity and ownership audit

`ProcessFingerprint` contains PID, UID, executable path and optional file identity, process start time, command digest, parent PID, and observation time. `SafeProcessController` revalidates the fingerprint and exact listener edge before signaling. Managed groups require a live runtime registration and a revalidated member. The owner-aware router refuses inferred Homebrew/launchd control and preserves exact Compose context.

The MCP boundary must therefore identify runtime targets by stable listener/runtime identifiers from a recent snapshot. `operation_preview` captures the fingerprint and ownership route. `operation_execute` re-resolves the target and uses the existing router; raw PIDs and arbitrary commands are invalid arguments.

## Current GUI and menu-bar capability inventory

### Runtime

- Start, pause, resume, and refresh monitoring.
- Search and filter the shared runtime snapshot; switch table/project grouping and saved presentation.
- Inspect listeners, processes, resources, ownership, restart trust, health, lifecycle evidence, incidents, Docker association, and exact fingerprints.
- Resolve ownership; copy non-secret facts; open a known working directory.
- Graceful stop, confirmed force stop, verified restart, and owner-aware conflict resolution.
- Open managed logs and convert an observed runtime into a reviewed managed-service candidate.

### Projects

- List, inspect, create, and delete projects.
- Associate and disassociate managed services.
- Discover candidates from an explicitly selected root, review candidates, and import selected candidates.
- Export the native manifest.
- Start and stop all project services with dependency and restart-trust checks.
- Open a known project folder, terminal, or Git remote in a native app.

### Managed services

- List, inspect, create, edit, duplicate, and delete definitions.
- Configure launch mechanism, executable/command, discrete arguments, working directory, reviewed shell mode, environment, Keychain references, expected ports, dependencies, timeouts, restart behavior, health/readiness checks, tags, icon, favorite state, and automatic launch.
- Save an unverified draft or test in isolation and save verified only after success.
- Start and stop verified services, inspect failure state, repair, and read/clear/copy/export bounded logs.

### Sessions

- List, inspect, capture, compare, preview restore, execute restore or dry run, inspect restore history, and delete.
- Restore options include explicit issue confirmations, optional rollback of services started by the restore, and separately confirmed expected-stopped handling.

### History, Docker, and settings

- Query/filter compatibility and lifecycle history, inspect incidents, restart a related verified service, clear selected history, and confirm clearing all history.
- Inspect Docker availability, containers and verified Compose ownership; refresh, read bounded logs, stop, restart, and remove through confirmation.
- Configure refresh interval, retention, notifications, launch at login, onboarding state, and diagnostics export.

### Menu bar and command palette

- Start/stop favorite services and projects, capture a workspace session, pause/resume monitoring, open the app, and quit.
- Navigate to product sections, open project folders, start/stop/restart verified services, start/stop projects, and open sessions/logs.

Opening Finder, Terminal, a Git URL, the main app window, or quitting the GUI is intentionally not a control-plane domain mutation. These presentation-only actions are documented exclusions. Every data, runtime, lifecycle, and configuration capability has an MCP mapping in `CONTROL_PLANE_PARITY.md`.

## Signing, sandbox, and local IPC constraints

The app is intentionally unsandboxed because global process enumeration and signaling are core features. Disabling sandboxing is not a Phase 3 change. A current-user Unix domain socket is therefore the narrowest local host boundary:

`~/Library/Application Support/DevBerth/IPC/control.sock`

The parent directory is mode `0700`; the socket is mode `0600`; peer credentials must match the current effective UID. There is no TCP listener. The protocol uses a version handshake, request and correlation IDs, length-prefixed bounded JSON frames, deadlines, cancellation, structured errors, and serialized mutations. The MCP helper may ask Launch Services to open DevBerth without activation if the host is absent.

## Current specification verification

Verified on 2026-07-21 from official sources:

- Codex supports local STDIO and Streamable HTTP MCP servers. User configuration is `~/.codex/config.toml`; trusted project configuration is `.codex/config.toml`. STDIO uses `command`, optional `args`, `env`, `env_vars`, and `cwd`. Tool policy supports a server default and per-tool `approval_mode` values `auto`, `prompt`, `writes`, and `approve`. Source: [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp).
- Codex reads MCP server `instructions`; the first 512 characters should be self-contained. The server uses that field to enforce preview/execute and no-raw-shell workflows.
- Correct MCP annotations affect approvals. Codex always requires approval for a tool advertising the destructive annotation even if another hint says read-only. Source: [Codex approvals and security](https://learn.chatgpt.com/docs/agent-approvals-security#sandbox-and-approvals).
- The stable MCP protocol is `2025-11-25`. A future `2026-07-28` release candidate is not selected before its release date.
- The official Swift SDK is `modelcontextprotocol/swift-sdk` 0.12.1 (released 2026-05-07). Its README implements protocol `2025-11-25`, requires Swift 6.0/Xcode 16 or newer, and provides STDIO, Streamable HTTP, tools, resources, prompts, structured tool results, cancellation, progress, and graceful shutdown. Source: [official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk).

Production uses STDIO only. Streamable HTTP is supported by Codex and the SDK but is excluded because a local network listener widens the attack surface without helping the installed macOS control plane. Resources and prompts are additive conveniences; essential operations remain tools because client support varies.

## Audit conclusions

1. DevBerth already has the safety-critical runtime and persistence behavior Phase 3 needs; handlers must adapt it, not reproduce it.
2. The app process must own the control host and all writes. The MCP process is a protocol adapter and local IPC client.
3. A shared contracts/capability target is needed so schema, annotations, parity metadata, and IPC envelopes cannot drift.
4. V7 must add stable revisions and organization records without editing V1-V6.
5. Every destructive action must be represented by an expiring, single-use preview held by the app host.
6. Development mode must use an in-memory store and application-owned fixtures and must remove development tools from Release discovery.

