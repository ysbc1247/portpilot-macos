# Phase 2 repository audit

Audit date: 2026-07-21 (Asia/Seoul)  
Audited branch: `phase-2-differentiation`  
Baseline commit: `71eab77a0f0cbe8af8f8681b863a3763b68c8150`  
Repository: private `ysbc1247/portpilot-macos`

This document records evidence from the code, a clean derived-data build, every existing test target, static analysis, a live application run, direct accessibility-tree inspection, the local SwiftData store, and command-level performance measurements. README claims were not treated as proof.

## Baseline validation

| Check | Observed result |
| --- | --- |
| Working tree before Phase 2 | Clean on `main`; Phase 2 branch created before edits |
| Local toolchain | Xcode 26.4 (`17E192`), Swift 6.3 toolchain, project compiling in Swift 5 mode |
| Deployment target | macOS 14.0 |
| Targets | `PortPilot`, `PortPilotTests`, `PortPilotIntegrationTests` |
| Scheme | One shared `PortPilot` scheme; both test bundles included |
| Debug build | Passed from a clean derived-data directory with warnings-as-errors |
| Tests | 30 unit tests and 3 harmless real-process integration tests passed; zero failures and zero skips |
| Static analysis | `xcodebuild analyze` passed |
| Compiler/tool warnings | No Swift or Clang warnings. Xcode emitted the informational App Intents metadata warning because the target has no App Intents dependency. Ad-hoc no-sign builds disable Hardened Runtime for that local artifact. |
| Live run | App launched, monitored 54–56 listener rows, remained responsive for the measured 65-second run, and exited without an observed crash |
| Current CI | Builds and tests on `macos-15` with Xcode 16.4, but push triggers are restricted to `main` |
| Signing/entitlements | Hardened Runtime configured for signed builds; App Sandbox disabled; no additional entitlements or privileged helper |

The baseline test result proves the narrow Phase 1 behavior covered by those tests. It does not prove UI workflows, schema migration, process groups, ownership, sessions, restart policies, retention, Compose control, or long-running stability.

## Confirmed working functionality

- TCP `LISTEN` and UDP discovery uses separate absolute-path `lsof` invocations and NUL-delimited tagged fields. Parser fixtures cover IPv4, IPv6, wildcard/loopback endpoints, malformed input, and multiple listeners for one PID.
- Process enrichment runs off the main actor and obtains parent PID, username, start time, command output, current directory, and executable path. Executable paths containing spaces are parsed correctly.
- Discovery uses a 30-second metadata cache with a three-PID refresh budget, evicts disappeared PIDs, produces listener diffs, and buffers only the newest monitoring update.
- Project inference walks at most twelve ancestors from the observed working directory and does not recursively scan the disk.
- Direct process termination rejects root/recognized system processes, requires executable path plus start time, re-queries both fields before signaling, and requires explicit force-stop confirmation.
- Launch profiles persist command, arguments, working directory, shell choice, environment, Keychain references, expected ports, dependencies, timeouts, restart-policy value, tags, and organization flags.
- Secret values are stored through Keychain references and are not encoded in the tested launch-profile JSON. Managed output is bounded in memory and on disk, with exact known Keychain values redacted before persistence.
- Expected-port conflicts require an explicit user choice. Required ports and an optional HTTP status check gate a successful launch.
- Dependency planning detects missing profiles/cycles, runs independent profiles concurrently within a topological layer, and stops layers in reverse order.
- Docker CLI absence, daemon absence, JSON-line parsing, published-port mapping, direct container stop/restart, and bounded recent-log retrieval exist. Listener-to-container correlation is cached for five seconds.
- SwiftData V1 opens and persists history records. Native SwiftUI navigation, customizable listener columns, search/filter/sort, menu bar, settings, command palette, projects, profiles, Docker, and history views render in the live app.
- Diagnostics exclude full command lines, environment values, managed logs, and Keychain content. The repository contains no telemetry, account, cloud-sync, or analytics implementation.

## Partially implemented functionality

### Domain and runtime state

- `NetworkListener` and `ProcessMetadata` separate a listener from a process, but there are no deliberate `ObservedProcess`, `ManagedService`, `RuntimeInstance`, `WorkspaceSession`, ownership-evidence, or restart-trust domain types.
- `ProcessMetadata` contains `launchedByPortPilot` and `launchProfileID`, but discovery always sets them to `false`/`nil`; managed launches are never reconciled back to observed listeners.
- Parent PID is captured, but parent name is always `nil`; no parent chain, process group, controlling owner, descendants, or supervisor-respawn detection exists.
- Projects group launch profiles, but do not model observed processes, topology, Docker association, startup failures, or runtime ownership.

### Launching and health

- A discovered process can be copied into a profile after review, but arguments are reconstructed by whitespace splitting, no values carry confidence/evidence, there is no staged conversion workflow, and saving marks the result reviewed without a validation launch.
- `isReviewed` is a review gate, not verification. A profile has no verified/conditional/inferred/not-restartable state and no validation evidence.
- Expected listeners and one HTTP status check provide rudimentary readiness. Process-running, listener-open, readiness, and health are not separate states.
- Restart policy is stored and shown but is never executed. Immediate exits update logs but do not reconcile `runningProfileIDs`, lifecycle state, or restart behavior.
- Launch-profile kinds include Docker and Compose, but the launcher treats them like ordinary commands. No Docker/Compose launch controller is selected from the kind.
- Project startup blocks later dependency layers after a failure, but does not roll back earlier layers and does not report a structured per-service result.

### Persistence and history

- SwiftData V1 declares records for observations, preferences, favorites, and stored-log metadata, but production code never inserts or queries those models.
- History records a small set of port/launch/stop events, but lacks severity, source, user-versus-automatic action, runtime instance, listener identity, structured safe metadata, related event IDs, and incident summaries.
- `deleteHistory(olderThan:)` exists but has no caller. The setting named “Retain history” therefore has no effect.
- Logs are size-bounded, but persisted log metadata and configurable retention are not wired.

### Docker

- Port mappings retain host and container ports, and two Compose labels are shown. Container health, restart policy, Compose working directory, configuration files, environment-file context, and service lifecycle context are discarded.
- Listener correlation correctly displays a container association when host port/protocol match, but lifecycle actions from the listener inspector still target the host PID path instead of Docker or Compose.

### Interface

- The app uses native sidebar/content/inspector structure and accessible table rows, but the information architecture is Phase 1 (`Overview`, `Active Ports`, `Launch Profiles`) and has no Sessions or ownership-oriented Runtime view.
- Table multi-selection exists, but context actions operate on only the first selected listener. Grouped project mode, saved views, resource usage, restart trust, health, ownership, and safe routed actions are absent.
- The command palette navigates and starts profiles, but does not search PID/process/command as entities or provide stop/restart/project/session/log/directory actions.
- Menu bar shows listeners, favorite profiles, and running projects, but not unexpected-listener or unhealthy-service counts and cannot capture a session.

## Missing functionality

- Public naming-conflict review, distinct final product identity, brand decision, and rename/data migration.
- Explicit observed-listener, observed-process, managed-service, runtime-instance, project, and workspace-session models.
- Runtime ownership graph, evidence/confidence model, ownership history, and reusable “Why is this running?” inspector.
- Ownership detection for shell/terminal/IDE/coding agent, Docker Compose, Homebrew services, Kubernetes port forwards, SSH tunnels, LaunchAgents/Daemons, and supervisors.
- Owner-aware lifecycle-controller abstraction and Compose-, Homebrew-, Kubernetes-, SSH-, and launchd-aware actions.
- Complete process fingerprint: numeric UID, file identity, command digest, parent PID verification, process-group ID, and detection timestamp.
- Listener/runtime ownership revalidation immediately before every destructive action.
- Restart-trust states, validation runs, validation evidence, and a complete observed-process conversion workflow.
- Runtime-instance tracking, process-group/descendant control, supervisor-respawn detection, and orphan cleanup.
- Workspace-session capture, comparison, dry-run preview, restore, conflict resolution, dependency execution, rollback, and restore history.
- Adapter-based project discovery/import for the requested ecosystems and manifests.
- Full lifecycle event taxonomy, deterministic incident summaries, configurable retention, and safe pruning.
- Separate readiness/health check types, retry policy, initial delay, response-text checks, command/file/Docker/dependency checks, and the requested service-state machine.
- Onboarding and first-run privacy/safety education.
- UI test target, migration fixtures/tests, soak harness, and the large acceptance-scenario fixture set.
- Experimental `.localhost` alias router. This must remain deferred until ownership, trust, sessions, and security work are stable.

## Incorrect or unsafe functionality

1. The listener table marks ordinary listeners as “Healthy.” Only socket presence was observed; no health check ran. The correct baseline state is “Listening” or “Observed,” not healthy.
2. The inspector labels `ps` output as “Verified command.” The command line is observed and may be incomplete; executable/start-time identity verification does not verify command semantics.
3. A stale listener action revalidates PID/executable/start time but does not verify UID, command digest, parent, executable file identity, or continued ownership of the selected listener. PID reuse protection is therefore incomplete.
4. Force stop performs the same limited identity check when invoked, but there is no single escalation transaction that proves the timed-out process and listener are still the original target.
5. Unknown same-PID listeners are terminated by PID even if Docker, launchd, Homebrew, or another supervisor is the actual controller. This can kill the wrong layer or trigger an unexplained respawn.
6. Managed processes are launched without a controlled process group. Stopping the parent can orphan children or leave the actual port owner running.
7. `runningProfileIDs` is presentation memory, not authoritative runtime state. It can say Running after an external exit and Stopped after an app relaunch while the service remains active.
8. `RestartPolicy` is a non-functional production control. Presenting it as configured behavior is misleading.
9. Compose profile kinds and product copy imply reliable Compose launching, but no Compose context is persisted or used. Acting on a reconstructed Compose command would risk the wrong project.
10. The discovered-profile workflow performs naïve whitespace splitting, which corrupts quoted/escaped arguments. Review alone does not make that profile reliably restartable.
11. The ordinary environment editor accepts secret-like values into SwiftData, and log redaction only knows values explicitly stored through Keychain. A secret split across output chunks can also bypass exact per-chunk replacement.
12. Launch failures can persist `localizedDescription` strings containing command output or full health-check URLs; query parameters or tool stderr may contain secrets.
13. `URLSession.data(for:)` accepts an unbounded health-response body and follows the configured URL. There is no response-size limit or explicit trust/exposure policy.
14. Log persistence reads and atomically rewrites the full file on every append. It is bounded in size but creates avoidable I/O and copy cost.
15. Database initialization uses `fatalError`; a corrupt or incompatible store causes an immediate app crash with no safe recovery/export path.
16. Profile deletion does not delete Keychain values. Profile duplication shares secret UUID references, so changing a shared reference can unexpectedly affect both profiles.
17. Persistence operations frequently use `try?`, hiding failed saves/deletes and allowing UI state to diverge from durable state.
18. The history-retention control is inert, and `HistoryView` fetches all events before filtering. This is both misleading and a long-running memory/performance risk.
19. `recordPortChanges` creates one unstructured task and one SwiftData save per event; an app start with many listeners causes a burst of independent writes.
20. `FoundationCommandRunner` does not terminate its subprocess when the task is cancelled and buffers command output without an explicit limit.

## Architecture problems

- `AppModel` coordinates discovery, Docker correlation, launching, termination, notifications, history, project orchestration, conflicts, and UI navigation. Phase 2 needs smaller runtime, lifecycle, session, and presentation stores with explicit event flow.
- The protocol surface routes every process action through a single PID controller and every profile through a single command launcher. It cannot express owner-aware lifecycle semantics.
- Managed-process truth exists only inside `ManagedProcessLauncher`, while observed-process truth exists inside `LocalPortDiscovery`; no runtime registry joins them.
- Persistence models use encoded blobs for several evolving contracts. This is expedient but weak for migrations, drift comparison, filtering, and safe field-level evolution.
- High-volume lifecycle writes share the SwiftData store used for configuration and are committed one event at a time.
- Display strings and business semantics are intertwined in enums and error construction; user-facing text is not backed by a string catalog.
- `project.yml` declares `SWIFT_VERSION: 5.10`, but the generated project contains `SWIFT_VERSION = 5.1` and compiles with `-swift-version 5`. Documentation currently overstates the exact language mode.
- CI validates Xcode 16.4 while the current local baseline uses Xcode 26.4. Supporting both is useful, but the compatibility matrix and branch workflow are undocumented.

## Persistence and migration risks

- There is only `PortPilotSchemaV1`; the migration plan contains no stages and no previous-store fixture test.
- The current store is `/Users/theokim/Library/Application Support/PortPilot.store`; logs are under `Application Support/PortPilot/ServiceLogs`; Keychain uses `com.ysbc.portpilot.secrets`; preferences use the old bundle domain; and login-item registration is tied to the old app identity. Every one requires an explicit rename migration.
- The live audit store contained 1,217 history rows, zero persisted projects/profiles/observations/preferences/favorites/log-metadata records, a 484 KiB main store, and a 3.8 MiB WAL. No retention pass ran despite the 30-day UI default.
- Models named as persistent features are currently unused. A new schema must either make them truthful or migrate away from them; silently editing V1 is prohibited.
- Corrupt-data recovery, partial migration, missing Keychain references, shared/orphaned secret references, and application-directory moves have no tests.

## Process-management risks

- Identity strength is binary and based on only three fields. It lacks the requested UID, executable file identity, command digest, parent, and detection timestamp.
- Owner is a username string rather than a verified numeric UID. Other-user targets are not explicitly blocked by current-user comparison.
- No port-owner re-query occurs between identity validation and signal delivery.
- There is no process group or descendant registry, no port-owning-child capture, and no safe treatment of reloaders/supervisors.
- Docker-associated listeners remain actionable through direct SIGTERM/SIGKILL UI, even when the correct action is `docker stop` or Compose control.
- A blanket PID signal cannot represent a managed shutdown policy, tunnel stop, port-forward stop, launchd unload, or service-manager request.

## UX problems

- Listener presence, runtime classification, project inference, Docker mapping, management, restartability, readiness, and health are visually conflated.
- “Healthy,” “Verified command,” and “PortPilot managed” communicate more certainty than the model supports.
- Inference evidence exists only for project markers. Runtime classification and Docker association do not expose confidence/detection method/timestamp.
- No view answers what launched a process, what controls it, why a conclusion was made, or whether it can be restarted reliably.
- No first-run explanation establishes local-only behavior, permission limits, management boundaries, Keychain handling, or destructive-action safety.
- Error alerts are generic and do not provide incident timelines, dependency blockers, or structured recovery choices.
- Navigation terminology centers ports and launch profiles rather than runtime ownership, managed services, and sessions.
- Some destructive persistence actions swallow errors, so a sheet can dismiss even when durable state did not change.

## Test coverage gaps

The existing 33 tests are useful but omit most Phase 2 risk. Missing coverage includes:

- UID/file-identity/command-digest/parent/listener mismatches, PID reuse simulation, ownership change, escalation revalidation, and supervisor respawn.
- Permission-denied enrichment, Unicode names, process exit during enrichment, multiple participating processes, detached/replaced/restarting children, and process groups.
- Ownership categories, conflicting evidence, confidence scoring, and every owner-aware controller.
- Actual executables/ecosystems represented by profile kinds, missing files/secrets, restart policy, health degradation, process-tree shutdown, Docker/Compose launch context, and rollback.
- Session capture/compare/dry-run/restore/rollback/parallelism/conflicts/cycles.
- Previous-schema/product-name/Keychain-reference migration, corrupt recovery, and retention pruning.
- UI filtering/actions, inspector truth labels, trust states, force confirmation, onboarding, sessions, keyboard navigation, command palette, empty states, appearance, and accessibility announcements.
- Keychain round-trip behavior, shared/orphan secret cleanup, chunk-boundary redaction, diagnostics URL/stderr sanitization, and malicious imported project data.
- Long-running memory, log rotation under load, Docker availability transitions, and cancellation cleanup.

## Performance baseline

Measurements were taken on the current Apple Silicon development Mac while 54–56 listeners and six Docker containers were active.

| Measurement | Baseline |
| --- | --- |
| 20 raw TCP+UDP `lsof` poll pairs | 4.468 s total; 223.39 ms wall per pair |
| Raw-poll CPU | 0.99 s user + 0.76 s system over 20 pairs |
| Raw benchmark maximum RSS | 7,274,496 bytes |
| Debug app warm RSS | approximately 139,568–142,080 KiB during the sampled interval |
| Debug app CPU samples | initial 4.4% and 12.2%; subsequent samples mostly 0.0–2.2% during the short run |
| Docker server-version query | approximately 0.01 s wall |
| Docker six-container scan | approximately 0.03 s wall |
| Current SwiftData footprint | 484 KiB store + 3.8 MiB WAL, including 1,217 history rows |

The 65-second app sample is not a soak test and does not prove stable memory. Process-enrichment duration, SwiftData event-write cost, log-streaming throughput, UI diff cost, and multi-hour behavior are not independently instrumented. Phase 2 must add repeatable instrumentation rather than extrapolate from this short baseline.

## Recommended changes and dependency order

1. Complete the naming review, choose a distinct name, and add a migration coordinator before changing product identifiers.
2. Introduce explicit observed/managed/runtime/session domain types and a V2 schema while preserving V1 fixtures.
3. Build a runtime registry that reconciles observed listeners/processes with managed runtime instances.
4. Expand the process fingerprint and require identity plus listener/runtime ownership verification for every destructive action.
5. Add controlled process groups and descendant/actual-port-owner tracking for application-managed services.
6. Introduce ownership evidence/confidence and controller selection before adding new stop/restart UI.
7. Replace `isReviewed` as the restart promise with explicit trust states and validation evidence.
8. Replace the narrow history record with bounded lifecycle events and deterministic incident summaries.
9. Add health/readiness state machines, then build session capture/preview/restore/rollback on top of trustworthy runtime state.
10. Implement adapter-based project discovery with review-only imports; never execute discovered commands automatically.
11. Preserve complete Compose context and route Docker/Compose actions through dedicated controllers.
12. Redesign navigation and inspector after the model can truthfully supply ownership, trust, health, and evidence.
13. Add migration, controller, session, UI, security, and soak coverage before enabling optional aliases.

## Features to remove or hide rather than expand prematurely

- Replace the green “Healthy” listener status with neutral observed/listening state until a health check proves health.
- Rename “Verified command” to “Observed command line” and show limitations.
- Hide restart-policy controls until the policy engine is implemented and tested.
- Hide Docker/Compose launch-profile kinds until they route through context-safe controllers.
- Remove the always-false “PortPilot managed” claim and replace it with reconciled ownership evidence.
- Fold or remove the static Overview if the new Runtime screen provides the same metrics with truthful state.
- Do not advertise unused observation/preference/favorite/log-metadata records as implemented persistence; either wire them into V2 or migrate them out.
- Defer the local alias router until ownership, restart trust, session restore, and threat-model gates pass.

## Audit conclusion

Phase 1 is a functioning native listener monitor with conservative basic PID verification and reviewed command launching. It is not yet a runtime ownership control center. The most important Phase 2 work is not feature count: it is correcting certainty labels, separating domain concepts, preserving data through rename/migration, routing lifecycle actions to real owners, and proving restarts and session restores with evidence.
