# DevBerth architecture

## Boundaries

DevBerth is one native app target with explicit source-level boundaries. SwiftUI features consume `AppModel` and injected protocols; no view directly invokes `Process`, `lsof`, `ps`, `kill`, Docker, or a shell.

| Boundary | Responsibility | Production implementation |
| --- | --- | --- |
| Domain | OS observations, durable managed-service intent, process fingerprints, dependency planning, conflicts, history | Value types in `DevBerth/Domain` |
| Command execution | Direct executable URL plus discrete argument arrays | `FoundationCommandRunner` |
| Process discovery | Tagged listener parsing and process enrichment | `LocalPortDiscovery`, `ObservedProcessProvider` |
| Monitoring | Polling, snapshots, diffs, pause/resume | `PortMonitor` actor |
| Ownership | Bounded lineage, managed-runtime reconciliation, confidence-labeled conclusions, safe controller choice | `SystemProcessLineageProvider`, `RuntimeOwnershipResolver`, `ManagedRuntimeRegistry` |
| Process control | Protection, fingerprint and listener-edge verification, signals, wait state | `SafeProcessController` |
| Lifecycle routing | Dispatch to the verified owner layer or refuse without signaling | `OwnerAwareLifecycleRouter` |
| Launching | Reviewed profile execution, dedicated POSIX groups, descendants, and managed lifetime | `POSIXControlledProcessSpawner`, `ManagedProcessLauncher`, `LaunchCoordinator` |
| Restart trust | Exact configuration digests, isolated validation, launch authorization, safe explanations | `RestartTrustEvaluator`, `ManagedServiceValidationRunner` |
| Runtime lifecycle | Runtime truth, readiness/health transitions, incidents, exit supervision, bounded restarts | `RuntimeLifecycleTracker`, `ManagedProcessExitHub`, `RestartPolicyEvaluator` |
| Service checks | Reviewed TCP, HTTP status/text, command, file, Docker, and dependency criteria | `ServiceCheckRunner`, `LaunchCoordinator` |
| Projects | Dependency-layer orchestration | `ProjectOrchestrator` |
| Docker | Availability, container JSON, ports, actions, logs | `DockerCLIClient`, `DockerAssociationProvider` |
| Secrets | Opaque references and values | SwiftData references plus `KeychainSecretStore` values |
| Logs | stdout/stderr capture, redaction, bounds, persistence | `ServiceLogBuffer` |
| Persistence | Durable user configuration and audit trail | SwiftData records and `SwiftDataStore` model actor |
| Presentation | Native navigation, tables, inspectors, sheets, settings, menu bar | SwiftUI under `DevBerth/Features` |

## Runtime state flow

1. `PortMonitor` asks `PortDiscovering` for a snapshot outside the main actor.
2. `LocalPortDiscovery` runs separate TCP and UDP `lsof` calls with NUL-delimited tagged fields.
3. Unique listener PIDs are enriched using fixed-shape `ps` fingerprint data and tagged `lsof` `cwd`/`txt` paths.
4. Process metadata is cached for 30 seconds. At most three stale entries are refreshed per poll, preventing synchronized command bursts; disappeared PIDs are evicted immediately.
5. `RuntimeDiffer` derives added, updated, and removed listeners by stable listener ID.
6. Docker associations are refreshed on a five-second cache and joined by host port and protocol.
7. `AppModel` publishes the correlated snapshot on the main actor, records added/changed/released listeners as structured lifecycle evidence plus compatibility history, and optionally schedules configured-port notifications.
8. The selected listener is reconciled against the managed-runtime registry, Docker metadata, bounded process lineage, and deterministic external-owner rules. The result is a transient `RuntimeOwnershipGraph`; its primary conclusion is persisted with bounded retention.
9. SwiftUI renders the existing value graph instead of causing OS queries from view bodies.

The listener identity is `PID + protocol + address + port`. A process fingerprint contains PID, UID, executable path, executable device/inode when available, start time, command-line SHA-256 digest, parent PID, and detection time. First/last listener timestamps and fingerprint detection time are evidence timestamps, not authority to control a PID and not persisted live `Process` objects.

## Domain vocabulary

`ObservedListener` and `ObservedProcess` are transient facts reported by the operating system. An observed listener contains an observed process because the listener-to-process edge is direct evidence from `lsof`; neither type contains launch instructions or restart claims. `ManagedServiceConfiguration` is durable, reviewed user intent: launch mechanism, command, arguments, environment references, expected listeners, health/readiness, shutdown/restart policy, dependencies, and log settings. The existing `LaunchProfileRecord` name remains a V1 persistence compatibility detail and is converted at the boundary by `LaunchProfileRecord+Domain`.

`RuntimeInstance`, `OwnershipConclusion`, `RestartTrustAssessment`, `ManagedServiceValidationResult`, `WorkspaceSession`, `ProjectDiscoveryMetadata`, and `LifecycleEvent` model the remaining Phase 2 concepts independently. Ownership resolution, safe lifecycle routing, restart trust, isolated managed-service validation, continuous runtime lifecycle persistence, health monitoring, and deterministic incident summaries are live. Session restoration and adapter import remain later slices. An empty table is never treated as a completed workflow. See `Documentation/DOMAIN_MODEL.md` for reference and persistence rules.

## Runtime lifecycle and health

`ManagedProcessLauncher` creates the runtime identity and reports spawn, stop, and exit evidence. `LaunchCoordinator` owns preflight, required-listener readiness, reviewed service checks, and ongoing health sampling. Both publish through the same actor-isolated `RuntimeLifecycleTracker`, so presentation state is derived from ordered observations rather than a UI-maintained running flag.

The tracker represents process-running, listener-open, service-ready, and service-healthy separately. Required listeners can make a service ready without making it healthy. HTTP status/text, executable, file, Docker health, and dependency checks carry a reviewed timeout, interval, retry limit, initial delay, and failure message. Executable checks use an absolute executable and discrete arguments; Docker inspection validates the container identity and uses discrete CLI arguments. HTTP bodies and command output are not copied into lifecycle failures.

`ManagedProcessExitHub` removes stale health monitors before policy evaluation. Unexpected exits may restart only when the current definition still has an exact successful validation. Backoff is 1, 2, then 4 seconds inside a rolling maximum of three attempts per minute; intentional stops never restart. Startup failures are retried within the same cap, while a trust refusal stops immediately.

Incident summaries are deterministic projections of the latest eight ordered events plus the terminal event. They cite event IDs, retain a concise cause and rule-selected next action, and do not ingest arbitrary log or response content. See `LIFECYCLE_INTELLIGENCE.md` for the state and evidence contracts.

## Ownership graph and lifecycle routing

`ManagedRuntimeRegistry` is an actor-isolated, in-memory reconciliation index shared by the managed launcher, ownership resolver, and lifecycle router. A launch registers the exact runtime handle, reviewed managed-service configuration, and latest process-group snapshot. Resolution may match an exact strong fingerprint or a member of the registered group, but the later managed stop still revalidates an ownership anchor and group membership inside `ManagedProcessLauncher` before signaling.

`SystemProcessLineageProvider` walks at most twelve ancestors by default, terminates on missing parents or cycles, and preserves the initially observed process as the first node. `RuntimeOwnershipResolver` applies a deterministic priority:

1. live managed-runtime registration;
2. exact Docker published-port/container metadata, including Compose labels;
3. command and lineage rules for Kubernetes port forwards, SSH tunnels, coding agents, supervisors, Homebrew plus launchd, LaunchAgents/Daemons, IDEs, terminals, shells, standalone processes, and unknown owners.

Every `OwnershipConclusion` includes value, confidence, evidence, detection method, and observation time. Managed registration and exact Docker metadata can be verified. Lineage and service-manager resemblance remain explicitly inferred even when several observations agree. The Active Ports inspector exposes the conclusion, evidence provenance, process group, lineage, and safe-action rationale under “Why is this running?”.

`OwnerAwareLifecycleRouter` is the only presentation-level dispatch boundary for an observed listener action. It stops a live DevBerth-managed runtime through its reviewed service policy and may restart that runtime by stopping its revalidated group and launching the exact registered verified configuration. Before that restart, `AppModel` requires the current profile to remain verified and compares its digest with the active runtime registration; an edit cannot silently relaunch an older registered recipe. It stops or restarts an exact Docker container through Docker, and delegates standalone/Kubernetes-forward/SSH process stops to `SafeProcessController`. It never substitutes a host PID signal for a container action. Compose, Homebrew, launchd, and supervisor actions are inspection-only until exact project files/environment, service name/domain, or controlling label are verified; requests are refused with an actionable explanation and no signal. External observations never receive restart because no verified reconstruction recipe exists.

## Discovery strategy

DevBerth invokes `/usr/sbin/lsof` using `-F0` machine fields, numeric hosts/ports, and separate selectors for TCP `LISTEN` and UDP endpoints. The parser tracks process and file records and ignores malformed fields. IPv6 addresses are unwrapped from brackets only after splitting on the final port colon.

`ps` provides parent PID, owner, start time, and command. Tagged `lsof` `cwd` and `txt` file records provide paths without losing spaces. Verified raw executable and command data remain visible even when classification heuristics label a runtime or infer a project.

Project inference walks at most twelve parent directories from the verified CWD and looks for a small marker set. It never performs a recursive filesystem scan.

## Process fingerprints and termination

Termination is intentionally conservative:

1. Reject root-owned, recognized system, `/System`, and `/usr/sbin` processes.
2. Require a strong captured fingerprint with UID, executable, start time, command digest, and parent PID; compare executable device/inode when it was available at detection.
3. Immediately re-query the full process fingerprint and the exact protocol/address/port listener edge.
4. Abort with an actionable explanation if either the fingerprint or listener ownership changed.
5. Invoke `/bin/kill` with `-TERM` or `-KILL` and the PID as separate arguments.
6. Poll the same fingerprint until the original process exits, changes, or times out. A changed fingerprint means the original target is gone; the replacement is never signaled.
7. Require UI confirmation and a fresh fingerprint plus listener-edge validation before a separate force escalation.
8. Persist the request, result, error, and duration.

A changed fingerprint is never treated as the original process. This prevents PID-reuse and stale-listener termination bugs.

## Managed process groups

Application-managed commands use `posix_spawn`, discrete argument/environment arrays, an explicit working-directory file action, and `POSIX_SPAWN_SETPGROUP`. The child becomes leader of a new group; inherited signal masks are cleared and common termination signals are restored to default before `exec`, so XCTest, terminal, or app-host dispositions cannot silently make a managed service ignore shutdown.

The runtime handle retains the group ID, stable leader fingerprint, service policy, and launch time. `SystemProcessGroupInspector` takes a bounded process-table snapshot, follows the leader's descendant graph, enriches relevant PIDs with full fingerprints, labels the expected-port owner, and distinguishes descendants that called `setsid` or otherwise escaped the controlled group. Zombie rows remain evidence but are not treated as live termination targets.

Before a managed stop, DevBerth captures a fresh snapshot and revalidates a live leader or previously captured descendant fingerprint plus its current group membership. The default reviewed policy sends `SIGTERM` to the verified group and waits for live members to disappear; a reviewed root-only policy signals only the leader. Escaped descendants are displayed in evidence and never included in the negative-PGID signal. A group with no revalidated ownership anchor is refused rather than signaled.

## Managed service configuration

A discovered process is evidence, not an executable recipe. Saving one opens a review sheet and prefills only best-effort values. `ManagedProcessLauncher` refuses unreviewed profiles.

Direct profiles resolve an executable from a trusted path search and pass every argument as data. Login-shell profiles are explicitly authored. Non-custom-shell commands use POSIX single-quote escaping per token; custom shell text is treated as user-authored shell code and is never derived or run automatically.

Non-secret environment values are stored in SwiftData. Secret-like plaintext names are rejected. Secret environment names map to UUIDs in SwiftData, while values are stored as device-only Keychain generic passwords. Values are injected only for process launch, provided to the redactor, and never logged. `SecretLifecycleCoordinator` stages edits and validation values, rolls them back on failure, gives duplicates fresh references, and deletes removed items only after persistence succeeds and no other profile uses them.

Before launch, `AppModel` requires a successful V4 validation whose exact configuration digest matches the current profile. This gate covers direct, project, menu-bar, favorite, and automatic launch paths. Only `ManagedServiceValidationRunner` bypasses it to perform isolated start, required-listener/HTTP readiness, and controlled stop. `LaunchCoordinator` then validates the profile and detects expected-port conflicts; a second discovery preflight catches races. Required ports and optional HTTP status are observed before launch succeeds, and failed readiness triggers a graceful cleanup attempt. The editor exposes separate Save Draft and Test & Save Verified actions; observed-process conversion additionally requires explicit approval before the revalidated occupying owner is stopped.

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

`DevBerthMigrationPlan` contains frozen V1 through V6 schemas. V2 adds separate runtime-instance, ownership-evidence, restart-trust, workspace-session, restore-result, project-discovery, and lifecycle-event records. V3 adds field-addressable full process fingerprints, managed-service process policies, and process-group snapshots. V4 adds the latest exact managed-service validation result. V5 adds lifecycle context and incident-summary sidecars without mutating the frozen V2 lifecycle entity. V6 adds reviewed managed-service check sidecars. Every transition is lightweight and additive; genuine V2, V3, V4, and V5 fixtures prove their next transition while the product migration fixture proves V1→current. Future changes must add a new `VersionedSchema` and explicit migration stage rather than editing any shipped schema identifier.

Lifecycle context stores severity, source, trigger, fingerprint, listener, duration, and related-event IDs beside the frozen V2 base event. The store retains at most 5,000 lifecycle events, prunes base and context together every 100 writes, and retains at most 250 incident summaries. Runtime instances are upserted by runtime ID. V4 validation digests remain byte-compatible for profiles with no V6 service checks; adding or changing a reviewed check extends the digest and requires revalidation.

Production ownership inspection records only the redacted `OwnershipConclusion`, not raw environment values. `SwiftDataStore` retains the newest 1,000 ownership-evidence records and deletes the oldest on insertion; an in-memory production-store test proves both persistence and the bound.

`ProductIdentity` is the single compatibility map for the former product name, bundle identifier, store, support directory, defaults domain, and Keychain service. Before constructing the production container, `ProductDataMigrator` uses SQLite's online-backup API to materialize a consistent snapshot of an absent current store, including committed legacy WAL data; it atomically promotes the completed snapshot, copies an absent service-log directory, and copies only whitelisted unset defaults. It never overwrites current data and retains the legacy store/WAL/SHM files as a recovery source. `KeychainSecretStore` reads the current service first, copies a successful legacy read forward, and deletes an intentionally removed reference from both services.

## Concurrency

- Command execution and discovery run in detached/background work.
- Discovery, monitoring, launching, lifecycle tracking, service checks, process control, Docker correlation, logs, and persistence are actor-isolated.
- The main actor owns observable presentation state only.
- Monitoring uses an `AsyncStream` buffered to the newest update, so slow UI work does not build an unbounded queue.
- Project layers use throwing task groups, which cancel sibling/remaining work after a failure.

## Security model

DevBerth is local-only and has no telemetry or upload service. It is not App Sandbox-enabled because process enumeration and signaling outside its container are product requirements. Hardened Runtime remains enabled. No privileged helper is installed, and no silent elevation path exists.

See `SECURITY.md` and `PRIVACY.md` for operator-facing policy.

## Tests

Parser fixtures cover TCP, UDP, IPv4, IPv6, wildcard/loopback, multiple ports per PID, and malformed records. Pure tests cover classification, diffs, exact restart digests including V6 checks, trust gating, isolated validation, secret staging/rollback/clone/delete, graph ordering/cycles, conflict detection, distinct runtime/readiness/health states, deterministic incidents, every service-check kind, retry timing, health degradation/recovery/cancellation, restart policy and crash-loop limits, listener lifecycle metadata, lifecycle retention, migrations through V6, bounded ownership evidence, bounded/cyclic lineage, deterministic owner classification, managed-runtime reconciliation, managed restart, owner-aware dispatch, and explicit controller refusal.

Integration tests start only test-bundle fixture processes on random high ports. Bundling fixtures avoids protected-folder permission prompts under a new application identity. The tests validate discovery, strong fingerprints, listener ownership, graceful exit, graceful timeout, confirmed force-stop, dedicated POSIX groups, child/multi-listener shutdown, `exec` replacement, supervisor restart, ignored `SIGTERM`, and detached-descendant exclusion. Every test owns and cleans up its fixture process.

## Monitoring overhead

On 2026-07-21, on an Apple Silicon development Mac with roughly 70 active listener rows:

- 20 pairs of raw TCP/UDP `lsof` scans averaged 215 ms wall time per pair.
- The compiled benchmark consumed 1.04 seconds user CPU and 0.61 seconds system CPU across 20 pairs, or about 82.5 ms CPU per raw poll pair.
- After adding the rolling metadata cache, steady-state app samples at the two-second default interval were normally 0.0–3.7% CPU. The initial implementation refreshed every PID together and produced a 78% spike; that design was removed.
- Metadata refresh is now limited to three stale PIDs per poll, and disappeared PIDs are evicted immediately.

Reproduce the raw discovery measurement with `swiftc Scripts/measure_discovery.swift -o /tmp/devberth-discovery-benchmark && /usr/bin/time -lp /tmp/devberth-discovery-benchmark`. Results vary with listener count, storage state, and system load.

## Trade-offs

- Polling is portable and testable on macOS 14; no public event API exposes all TCP/UDP ownership metadata. The default two-second interval is configurable.
- A 30-second rolling metadata cache can briefly show stale non-destructive labels, but process termination always performs fresh verification.
- App Sandbox is incompatible with core global process operations. The replacement controls are strict arguments, local-only data, protected-process policy, identity verification, no elevation, and Hardened Runtime.
- Runtime heuristics add useful labels but never replace verified raw values.
