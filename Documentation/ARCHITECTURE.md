# DevBerth architecture

## Boundaries

DevBerth is one native app target with explicit source-level boundaries. SwiftUI features consume `AppModel` and injected protocols; no view directly invokes `Process`, `lsof`, `ps`, `kill`, Docker, or a shell.

| Boundary | Responsibility | Production implementation |
| --- | --- | --- |
| Domain | OS observations, durable managed-service intent, process fingerprints, dependency planning, conflicts, history | Value types in `DevBerth/Domain` |
| Command execution | Direct executable URL plus discrete argument arrays | `FoundationCommandRunner` |
| Process discovery | Tagged listener parsing, process enrichment, and transient batched resource evidence | `LocalPortDiscovery`, `ObservedProcessProvider`, `SystemProcessResourceUsageReader` |
| Monitoring | Polling, snapshots, diffs, pause/resume | `PortMonitor` actor |
| Ownership | Bounded lineage, managed-runtime reconciliation, confidence-labeled conclusions, safe controller choice | `SystemProcessLineageProvider`, `RuntimeOwnershipResolver`, `ManagedRuntimeRegistry` |
| Process control | Protection, fingerprint and listener-edge verification, signals, wait state | `SafeProcessController` |
| Lifecycle routing | Dispatch to the verified owner layer or refuse without signaling | `OwnerAwareLifecycleRouter` |
| Launching | Reviewed profile execution, dedicated POSIX groups, descendants, and managed lifetime | `POSIXControlledProcessSpawner`, `ManagedProcessLauncher`, `LaunchCoordinator` |
| Restart trust | Exact configuration digests, isolated validation, launch authorization, safe explanations | `RestartTrustEvaluator`, `ManagedServiceValidationRunner` |
| Runtime lifecycle | Runtime truth, readiness/health transitions, incidents, exit supervision, bounded restarts | `RuntimeLifecycleTracker`, `ManagedProcessExitHub`, `RestartPolicyEvaluator` |
| Service checks | Reviewed TCP, HTTP status/text, command, file, Docker, and dependency criteria | `ServiceCheckRunner`, `LaunchCoordinator` |
| Projects | Dependency-layer orchestration | `ProjectOrchestrator` |
| Workspace sessions | Capture, drift comparison, fresh preflight, dependency-layer restore, scoped rollback | `WorkspaceSessionCoordinator` |
| Project discovery | Bounded, non-recursive, review-only adapters and native manifest interchange | `ProjectDiscoveryCoordinator`, `ProjectDiscoveryAdapting`, `DevBerthManifestCodec` |
| Docker | Batched Engine inspection, listener mapping, verified Compose scope, exact actions, logs | `DockerCLIClient`, `DockerAssociationProvider` |
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
6. Docker associations are refreshed on a five-second cache and joined by host port and protocol. One `docker inspect` batch supplies current state, health, restart policy, exact port bindings, and canonical labels; expensive Compose scope proof is cached for fifteen seconds only while its path evidence is unchanged.
7. One bounded `ps` call per batch of at most 128 unique listener PIDs reads CPU percentage and resident memory. Malformed, disappeared, or inaccessible PIDs remain unavailable; this transient evidence never authorizes control.
8. `AppModel` publishes the correlated snapshot and resource map on the main actor, records added/changed/released listeners as structured lifecycle evidence plus compatibility history, and optionally schedules configured-port notifications.
9. The selected listener is reconciled against the managed-runtime registry, Docker metadata, bounded process lineage, and deterministic external-owner rules. The result is a transient `RuntimeOwnershipGraph`; its primary conclusion is persisted with bounded retention.
10. SwiftUI renders the existing value graph instead of causing OS queries from view bodies.

The listener identity is `PID + protocol + address + port`. A process fingerprint contains PID, UID, executable path, executable device/inode when available, start time, command-line SHA-256 digest, parent PID, and detection time. First/last listener timestamps and fingerprint detection time are evidence timestamps, not authority to control a PID and not persisted live `Process` objects.

## Domain vocabulary

`ObservedListener` and `ObservedProcess` are transient facts reported by the operating system. An observed listener contains an observed process because the listener-to-process edge is direct evidence from `lsof`; neither type contains launch instructions or restart claims. `ManagedServiceConfiguration` is durable, reviewed user intent: launch mechanism, command, arguments, environment references, expected listeners, health/readiness, shutdown/restart policy, dependencies, and log settings. The existing `LaunchProfileRecord` name remains a V1 persistence compatibility detail and is converted at the boundary by `LaunchProfileRecord+Domain`.

`RuntimeInstance`, `OwnershipConclusion`, `RestartTrustAssessment`, `ManagedServiceValidationResult`, `WorkspaceSession`, `ProjectDiscoveryMetadata`, and `LifecycleEvent` model the remaining Phase 2 concepts independently. Ownership resolution, safe lifecycle routing, restart trust, isolated managed-service validation, continuous runtime lifecycle persistence, health monitoring, deterministic incident summaries, review-only project discovery/import, and transactional workspace restoration are live. An empty table is never treated as a completed workflow. See `Documentation/DOMAIN_MODEL.md` for reference and persistence rules.

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

Every `OwnershipConclusion` includes value, confidence, evidence, detection method, and observation time. Managed registration and exact Docker metadata can be verified. Lineage and service-manager resemblance remain explicitly inferred even when several observations agree. The Runtime inspector exposes the conclusion, evidence provenance, process group, lineage, and safe-action rationale under “Why is this running?”.

`OwnerAwareLifecycleRouter` is the only presentation-level dispatch boundary for an observed listener action. It stops a live DevBerth-managed runtime through its reviewed service policy and may restart that runtime by stopping its revalidated group and launching the exact registered verified configuration. Before that restart, `AppModel` requires the current profile to remain verified and compares its digest with the active runtime registration; an edit cannot silently relaunch an older registered recipe. It stops, restarts, or removes an exact Docker container through Docker, and delegates standalone/Kubernetes-forward/SSH process stops to `SafeProcessController`. It never substitutes a host PID signal for a container action. A Compose service receives stop, dependency-free restart, or removal only after exact project/service/files/directory/environment/hash and container membership verification; every action repeats that proof immediately before mutation. Homebrew, launchd, and supervisor actions remain inspection-only until their exact controlling context exists. External observations never receive restart because no verified reconstruction recipe exists.

## Discovery strategy

DevBerth invokes `/usr/sbin/lsof` using `-F0` machine fields, numeric hosts/ports, and separate selectors for TCP `LISTEN` and UDP endpoints. The parser tracks process and file records and ignores malformed fields. IPv6 addresses are unwrapped from brackets only after splitting on the final port colon.

`ps` provides parent PID, owner, start time, and command. Tagged `lsof` `cwd` and `txt` file records provide paths without losing spaces. Verified raw executable and command data remain visible even when classification heuristics label a runtime or infer a project.

Project inference walks at most twelve parent directories from the verified CWD and looks for a small marker set. It never performs a recursive filesystem scan.

Explicit project discovery is a different, user-initiated boundary. `ProjectDiscoveryCoordinator` runs independent adapters only against the selected project root. Readers accept only non-symlink regular files up to 1 MiB; no adapter runs a package manager, Docker, build tool, or discovered command. npm, pnpm, Yarn, Bun, Gradle, Maven, Python, Go, Cargo, Docker Compose, Procfile, Process Compose, workspace markers, and the native DevBerth manifest produce evidence plus unreviewed candidates. The UI persists selected candidates with `isReviewed == false`, so normal launch remains blocked until review and exact validation. `devberth-runtime.json` exports discrete launch data and named secret requirements but never values or Keychain reference UUIDs. See `PROJECT_DISCOVERY.md`.

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

Docker is optional. `DockerCLIClient` first resolves the CLI and asks the server for its version. Missing CLI and unavailable daemon are separate UI states. It lists full running-container IDs, then decodes one batched Engine inspection. The result retains ID, name, image, state, health, restart policy, and every published host address/port to container port/protocol binding.

Canonical Compose labels are context candidates, not mutation authority. DevBerth requires project name, service name, configuration hash, working directory, configuration files, and any environment files. Every path must be absolute, normalized, available, and free of symbolic links; device/inode plus file size and modification time are captured. One-off Compose containers are always inspection-only.

The candidate is proven by reconstructing an explicit CLI scope with project name, project directory, repeated configuration and environment-file arguments, comparing `docker compose config --hash SERVICE` with the container label, and requiring `docker compose ps --all --no-trunc --format json SERVICE` to contain the exact full container ID/project/service tuple. A fifteen-second cache avoids repeating those two non-mutating calls during every five-second listener refresh, but changed path evidence invalidates the key. Immediately before stop, restart, or remove, all identities and both Compose proofs run again.

Standalone actions address exactly one container ID. Compose actions append exactly one verified service; restart uses `--no-deps`, while remove is separately confirmed and uses scoped `rm --force --stop`. No Docker or Compose action falls back to a shell or host PID. Successful container/Compose changes and refused stale-context attempts write structured lifecycle evidence. See `DOCKER_CONTEXT.md`.

## Workspace sessions

`WorkspaceSessionCoordinator` captures selected projects through their managed-service definitions only. Running services record currently observed application-managed listeners; stopped services retain configured listener expectations. Every snapshot includes dependency IDs, health, and the exact managed-service digest. Secret values, process objects, and unmanaged launch suggestions are excluded.

Comparison is read-only and distinguishes added/missing services, digest drift, managed-port and health changes, and unexpected project-scoped listeners. Restore always performs a fresh discovery/preflight, requires the current exact validation before start, and refuses missing definitions, directories, executables, Keychain values, dependencies, free ports, or acyclic order.

Starts follow `DependencyPlanner` layers, with one layer parallelized and later layers waiting for normal launch readiness. Failure cancels dependent work and optional rollback stops only successfully started session services in reverse layer order. Expected-stopped services are evaluated after successful startup and require explicit user confirmation; they are not part of rollback authority. Dry run persists audit evidence but makes no runtime mutation. See `SESSION_MODEL.md`.

## Logs and diagnostics

Managed stdout and stderr are streamed into an actor. The redactor holds possible secret-prefix suffixes so a known secret split across arbitrary output chunks is replaced before entries reach memory or disk. Partial lines are assembled before storage. Each profile retains the latest 2,000 in-memory entries and a bounded two-megabyte redacted file under Application Support. Normal writes append; overflow rotates to half the maximum so every subsequent line does not trigger another full-file rewrite. The UI can pause rendering, clear, copy, search, and export.

Diagnostics include app/macOS versions, non-secret settings, command availability, non-command listener summaries, and the latest UI error. They intentionally exclude commands, environment values, log contents, and Keychain data.

## Native product surface

The sidebar order is Runtime, Projects, Sessions, Managed Services, History, Docker, and Settings. Runtime absorbs the former summary dashboard so metrics and list state derive from one live snapshot. Its table and project-grouped modes share the same protocol/search/saved-view filtering and persistent contextual inspector. Table columns expose process/PID, ownership, restart trust, health, runtime, uptime, and transient CPU/resident memory; network address and full fingerprint evidence remain in the inspector.

The first-run guide is local and account-free. It states visibility limits, observation versus management, exact destructive revalidation, Keychain-only secrets, and non-upload behavior before routing into Runtime, project import, managed-service creation, or session capture. The menu bar and command palette invoke `AppModel` request/action boundaries; they do not bypass trust checks. Palette restart is offered only for an exact verified definition. See `PRODUCT_SURFACE.md`.

## Persistence and migrations

SwiftData schema V1 contains `ProjectRecord`, `LaunchProfileRecord`, `ProfileDependencyRecord`, `ExpectedPortRecord`, `ProcessHistoryEventRecord`, `PortObservationRecord`, `UserPreferenceRecord`, `FavoriteItemRecord`, and `StoredLogMetadataRecord`. Domain values are converted explicitly; live listeners and `Process` instances are never modeled.

`DevBerthMigrationPlan` contains frozen V1 through V6 schemas. V2 adds separate runtime-instance, ownership-evidence, restart-trust, workspace-session, restore-result, project-discovery, and lifecycle-event records. V3 adds field-addressable full process fingerprints, managed-service process policies, and process-group snapshots. V4 adds the latest exact managed-service validation result. V5 adds lifecycle context and incident-summary sidecars without mutating the frozen V2 lifecycle entity. V6 adds reviewed managed-service check sidecars. Every transition is lightweight and additive; genuine V2, V3, V4, and V5 fixtures prove their next transition while the product migration fixture proves V1→current. Future changes must add a new `VersionedSchema` and explicit migration stage rather than editing any shipped schema identifier.

Lifecycle context stores severity, source, trigger, fingerprint, listener, duration, and related-event IDs beside the frozen V2 base event. Listener-change bursts are recorded as one lifecycle batch and one compatibility-history batch, with one save per batch. The store retains at most 5,000 lifecycle events by pruning base/context pairs with 100-row headroom whenever its write countdown crosses zero; a large batch reserves at least its own size. Incident summaries retain at most 250 rows. Runtime instances are upserted by runtime ID. V4 validation digests remain byte-compatible for profiles with no V6 service checks; adding or changing a reviewed check extends the digest and requires revalidation.

Production ownership inspection records only the redacted `OwnershipConclusion`, not raw environment values. `SwiftDataStore` retains the newest 1,000 ownership-evidence records and deletes the oldest on insertion; an in-memory production-store test proves both persistence and the bound.

`ProductIdentity` is the single compatibility map for the former product name, bundle identifier, store, support directory, defaults domain, and Keychain service. Before constructing the production container, `ProductDataMigrator` uses SQLite's online-backup API to materialize a consistent snapshot of an absent current store, including committed legacy WAL data; it atomically promotes the completed snapshot, copies an absent service-log directory, and copies only whitelisted unset defaults. It never overwrites current data and retains the legacy store/WAL/SHM files as a recovery source. `KeychainSecretStore` reads the current service first, copies a successful legacy read forward, and deletes an intentionally removed reference from both services.

## Concurrency

- Command execution and discovery run in detached/background work.
- Discovery, monitoring, launching, lifecycle tracking, service checks, process control, Docker correlation, logs, and persistence are actor-isolated.
- The main actor owns observable presentation state only.
- Monitoring uses an `AsyncStream` buffered to the newest update, so slow UI work does not build an unbounded queue.
- Project layers use throwing task groups, which cancel sibling/remaining work after a failure.
- Project-file parsing and manifest writes run behind actor-isolated service protocols; SwiftUI owns selection and presentation, not file evaluation.
- Session capture, comparison, fresh preflight, layered launch, and rollback run in an actor; independent services use task groups while SwiftUI holds only preview and confirmation state.

## Security model

DevBerth is local-only and has no telemetry or upload service. It is not App Sandbox-enabled because process enumeration and signaling outside its container are product requirements. Hardened Runtime remains enabled. No privileged helper is installed, and no silent elevation path exists.

See `SECURITY.md` and `PRIVACY.md` for operator-facing policy.

## Tests

Parser fixtures cover TCP, UDP, IPv4, IPv6, wildcard/loopback, multiple ports per PID, malformed records, Docker Engine inspection, and Compose JSON/hash output. Pure tests cover classification, diffs, exact restart digests including V6 checks, trust gating, isolated validation, secret staging/rollback/clone/delete, graph ordering/cycles, conflict detection, distinct runtime/readiness/health states, deterministic incidents, every service-check kind, retry timing, health degradation/recovery/cancellation, restart policy and crash-loop limits, listener lifecycle metadata, lifecycle retention, migrations through V6, bounded ownership evidence, bounded/cyclic lineage, deterministic owner classification, managed-runtime reconciliation, managed restart, owner-aware dispatch, explicit controller refusal, every required discovery ecosystem, Compose dependency/port extraction, exact Compose scope reconstruction, one-off/stale/hash-mismatch refusal, shell-review flags, native manifest redaction, unreviewed import persistence, session capture/comparison/preflight/dry-run, dependency parallelism, failed-layer blocking, and scoped rollback.

Integration tests start only test-bundle fixture processes on random high ports. Bundling fixtures avoids protected-folder permission prompts under a new application identity. The tests validate discovery, strong fingerprints, listener ownership, graceful exit, graceful timeout, confirmed force-stop, dedicated POSIX groups, child/multi-listener shutdown, `exec` replacement, supervisor restart, ignored `SIGTERM`, and detached-descendant exclusion. Every test owns and cleans up its fixture process.

The UI-test target launches with `DEVBERTH_UI_TESTING=1`, uses an in-memory V6 container, skips product migration, and injects a static loopback listener plus resource snapshot owned entirely by the test configuration. It covers onboarding disclosure, primary navigation, and keyboard command-palette routing without inspecting or controlling the host runtime.

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
