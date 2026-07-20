# PortPilot architecture

## Boundaries

PortPilot is one native app target with explicit source-level boundaries. SwiftUI features consume `AppModel` and injected protocols; no view directly invokes `Process`, `lsof`, `ps`, `kill`, Docker, or a shell.

| Boundary | Responsibility | Production implementation |
| --- | --- | --- |
| Domain | Runtime values, identity, profiles, dependency planning, conflicts, history | Value types in `PortPilot/Domain` |
| Command execution | Direct executable URL plus discrete argument arrays | `FoundationCommandRunner` |
| Process discovery | Tagged listener parsing and process enrichment | `LocalPortDiscovery`, `ProcessMetadataProvider` |
| Monitoring | Polling, snapshots, diffs, pause/resume | `PortMonitor` actor |
| Process control | Protection, identity verification, signals, wait state | `SafeProcessController` |
| Launching | Reviewed profile execution and managed process lifetime | `ManagedProcessLauncher`, `LaunchCoordinator` |
| Projects | Dependency-layer orchestration | `ProjectOrchestrator` |
| Docker | Availability, container JSON, ports, actions, logs | `DockerCLIClient`, `DockerAssociationProvider` |
| Secrets | Opaque references and values | SwiftData references plus `KeychainSecretStore` values |
| Logs | stdout/stderr capture, redaction, bounds, persistence | `ServiceLogBuffer` |
| Persistence | Durable user configuration and audit trail | SwiftData records and `SwiftDataStore` model actor |
| Presentation | Native navigation, tables, inspectors, sheets, settings, menu bar | SwiftUI under `PortPilot/Features` |

## Runtime state flow

1. `PortMonitor` asks `PortDiscovering` for a snapshot outside the main actor.
2. `LocalPortDiscovery` runs separate TCP and UDP `lsof` calls with NUL-delimited tagged fields.
3. Unique listener PIDs are enriched using fixed-shape `ps` identity data and tagged `lsof` `cwd`/`txt` paths.
4. Process metadata is cached for 30 seconds. At most three stale entries are refreshed per poll, preventing synchronized command bursts; disappeared PIDs are evicted immediately.
5. `RuntimeDiffer` derives added, updated, and removed listeners by stable listener ID.
6. Docker associations are refreshed on a five-second cache and joined by host port and protocol.
7. `AppModel` publishes the correlated snapshot on the main actor, records relevant history, and optionally schedules configured-port notifications.
8. SwiftUI renders the existing value graph instead of causing OS queries from view bodies.

The listener identity is `PID + protocol + address + port`. Process identity is `PID + executable path + start time`. First/last detection timestamps belong to transient listener state and history, not a persisted live `Process` object.

## Discovery strategy

PortPilot invokes `/usr/sbin/lsof` using `-F0` machine fields, numeric hosts/ports, and separate selectors for TCP `LISTEN` and UDP endpoints. The parser tracks process and file records and ignores malformed fields. IPv6 addresses are unwrapped from brackets only after splitting on the final port colon.

`ps` provides parent PID, owner, start time, and command. Tagged `lsof` `cwd` and `txt` file records provide paths without losing spaces. Verified raw executable and command data remain visible even when classification heuristics label a runtime or infer a project.

Project inference walks at most twelve parent directories from the verified CWD and looks for a small marker set. It never performs a recursive filesystem scan.

## Process identity and termination

Termination is intentionally conservative:

1. Reject root-owned, recognized system, `/System`, and `/usr/sbin` processes.
2. Require a strong identity with executable and start time.
3. Immediately re-query start time and tagged executable path.
4. Compare all identity fields before signaling.
5. Invoke `/bin/kill` with `-TERM` or `-KILL` and the PID as separate arguments.
6. Poll the same identity until exit or timeout.
7. Require a UI confirmation before the force mode can be constructed with `confirmed: true`.
8. Persist the request, result, error, and duration.

A changed identity is never treated as the original process. This prevents PID-reuse termination bugs.

## Launch profiles

A discovered process is evidence, not an executable recipe. Saving one opens a review sheet and prefills only best-effort values. `ManagedProcessLauncher` refuses unreviewed profiles.

Direct profiles resolve an executable from a trusted path search and pass every argument as data. Login-shell profiles are explicitly authored. Non-custom-shell commands use POSIX single-quote escaping per token; custom shell text is treated as user-authored shell code and is never derived or run automatically.

Non-secret environment values are stored in SwiftData. Secret environment names map to UUIDs in SwiftData, while values are stored as device-only Keychain generic passwords. Values are injected only for process launch, provided to the redactor, and never logged.

Before launch, `LaunchCoordinator` validates the profile and detects expected-port conflicts. The UI offers cancel, inspect, graceful stop, stop-then-start, or edit-port choices. A race is caught by a second discovery preflight inside the coordinator. Required ports and optional HTTP status are observed before launch succeeds; failed readiness triggers a graceful cleanup attempt.

## Project orchestration

`DependencyPlanner` validates every referenced profile, rejects cycles with the involved UUIDs, and returns topological layers. `ProjectOrchestrator` runs each layer sequentially and profiles within a layer concurrently. A failed layer prevents dependent layers from starting. Stop order reverses the dependency layers.

## Docker

Docker is optional. `DockerCLIClient` first resolves the CLI and asks the server for its version. Missing CLI and unavailable daemon are separate UI states. Running containers are decoded from one JSON object per `docker ps` line. Published host mappings retain address, host port, container port, and protocol; Compose labels are decoded when present.

Stop, restart, and recent logs use discrete Docker CLI arguments. Docker actions never fall back to a shell. Listener correlation is cached and does not block core monitoring when Docker is absent.

## Logs and diagnostics

Managed stdout and stderr are streamed into an actor. Secret values are replaced before entries reach memory or disk. Each profile retains the latest 2,000 in-memory entries and a bounded two-megabyte redacted file under Application Support. The UI can pause rendering, clear, copy, search, and export.

Diagnostics include app/macOS versions, non-secret settings, command availability, non-command listener summaries, and the latest UI error. They intentionally exclude commands, environment values, log contents, and Keychain data.

## Persistence and migrations

SwiftData schema V1 contains `ProjectRecord`, `LaunchProfileRecord`, `ProfileDependencyRecord`, `ExpectedPortRecord`, `ProcessHistoryEventRecord`, `PortObservationRecord`, `UserPreferenceRecord`, `FavoriteItemRecord`, and `StoredLogMetadataRecord`. Domain values are converted explicitly; live listeners and `Process` instances are never modeled.

`PortPilotMigrationPlan` anchors version `1.0.0`. Future schema changes must add a new `VersionedSchema` and explicit migration stage rather than editing a shipped schema identifier.

## Concurrency

- Command execution and discovery run in detached/background work.
- Discovery, monitoring, launching, process control, Docker correlation, logs, and persistence are actor-isolated.
- The main actor owns observable presentation state only.
- Monitoring uses an `AsyncStream` buffered to the newest update, so slow UI work does not build an unbounded queue.
- Project layers use throwing task groups, which cancel sibling/remaining work after a failure.

## Security model

PortPilot is local-only and has no telemetry or upload service. It is not App Sandbox-enabled because process enumeration and signaling outside its container are product requirements. Hardened Runtime remains enabled. No privileged helper is installed, and no silent elevation path exists.

See `SECURITY.md` and `PRIVACY.md` for operator-facing policy.

## Tests

Parser fixtures cover TCP, UDP, IPv4, IPv6, wildcard/loopback, multiple ports per PID, and malformed records. Pure tests cover classification, diffs, validation, graph ordering/cycles, conflict detection, state transitions, Docker parsing/fallback, shell escaping, secret references, log redaction/bounds, health checks, SwiftData history, and migrations.

Integration tests start only repository fixture processes on random high ports. They validate discovery, strong identity, graceful exit, graceful timeout, and confirmed force-stop. Every test owns and cleans up its fixture process.

## Monitoring overhead

On 2026-07-21, on an Apple Silicon development Mac with roughly 70 active listener rows:

- 20 pairs of raw TCP/UDP `lsof` scans averaged 215 ms wall time per pair.
- The compiled benchmark consumed 1.04 seconds user CPU and 0.61 seconds system CPU across 20 pairs, or about 82.5 ms CPU per raw poll pair.
- After adding the rolling metadata cache, steady-state app samples at the two-second default interval were normally 0.0–3.7% CPU. The initial implementation refreshed every PID together and produced a 78% spike; that design was removed.
- Metadata refresh is now limited to three stale PIDs per poll, and disappeared PIDs are evicted immediately.

Reproduce the raw discovery measurement with `swiftc Scripts/measure_discovery.swift -o /tmp/portpilot-discovery-benchmark && /usr/bin/time -lp /tmp/portpilot-discovery-benchmark`. Results vary with listener count, storage state, and system load.

## Trade-offs

- Polling is portable and testable on macOS 14; no public event API exposes all TCP/UDP ownership metadata. The default two-second interval is configurable.
- A 30-second rolling metadata cache can briefly show stale non-destructive labels, but process termination always performs fresh verification.
- App Sandbox is incompatible with core global process operations. The replacement controls are strict arguments, local-only data, protected-process policy, identity verification, no elevation, and Hardened Runtime.
- Runtime heuristics add useful labels but never replace verified raw values.

