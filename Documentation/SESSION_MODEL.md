# Workspace session model

Decision date: 2026-07-21 (Asia/Seoul)

## Product boundary

A workspace session is a durable, reviewable expectation for a selected set of projects and managed services. It is not a process snapshot, shell-session image, or authority to control an observed PID. Unmanaged listeners can appear as comparison or conflict evidence, but DevBerth never converts or restores them automatically.

The workflow is implemented by `WorkspaceSessionCoordinator`, exposed by `AppModel`, persisted through `WorkspaceSessionRecording`, and presented in the Sessions feature. The existing V2 session tables were already shipped and remain unchanged.

## Captured state

`WorkspaceSession` stores a name, project IDs, capture time, optional notes, and one `WorkspaceSessionServiceSnapshot` per managed service in the selected projects. Each service snapshot stores:

- the stable managed-service ID;
- expected running or stopped state;
- actual observed managed listeners when the service is running, otherwise its configured expected listeners;
- dependency service IDs;
- the current health state;
- the exact `ManagedServiceConfigurationDigest` at capture time.

Secret values, environment values, log contents, process objects, PIDs, and unmanaged launch suggestions are never captured. The digest permits drift detection without copying launch-critical secrets or configuration into the session.

## Comparison

Comparison is read-only. It reports services added to the selected projects, missing captured services, configuration-digest drift, changed managed ports, changed health, and unmanaged listeners whose verified working directory is inside a selected project root. A comparison does not authorize a lifecycle action.

## Restore preview

Every restore execution begins with a fresh preview, including dry runs. Preview re-discovers current listeners and derives explicit actions: start, already running, stop after successful startup, already stopped, or missing.

Blocking preflight issues include missing services, dependencies, working directories, executables, Keychain values, exact restart validation, occupied expected ports, and dependency cycles. Configuration drift and a currently running service that was saved as stopped require explicit confirmation. Cross-project port ownership is shown as additional evidence. Stable issue IDs bind confirmation to the exact issue evidence; a subsequent preview cannot inherit a confirmation for different evidence.

Only a reviewed managed-service definition with a successful isolated validation for its current digest is startable. Session capture itself never grants restart trust.

## Transactional execution

The dependency planner creates ordered startup layers. Services in one layer launch concurrently; the next layer begins only after every service in the prior layer has completed its normal readiness contract. A failed layer prevents dependent layers from starting.

On startup failure or cancellation, optional rollback stops only services successfully started by this restore, in reverse dependency order. It never stops a service that was already running before restore. If rollback cannot stop a started service, the final result records the partial rollback precisely.

Expected-stopped services are handled only after all required starts are ready and only when the user enables that option. Declining that mutation produces a partial result without rolling back successful starts. A failed requested stop may trigger rollback of newly started services when rollback is enabled.

A dry run records its plan and lifecycle result but performs no launch or stop. Every attempt records structured session lifecycle events plus a durable `SessionRestoreResult` containing outcome, started IDs, rolled-back IDs, timestamps, and safe errors.

## Persistence and deletion

V2 `WorkspaceSessionRecord` stores session metadata, `WorkspaceSessionServiceRecord` stores service snapshots, and `SessionRestoreRecord` stores results. `WorkspaceSessionRecord+Domain` is the explicit conversion boundary and refuses to materialize a partially decoded session if any snapshot is corrupt. Deleting a session deletes its snapshot and restore-result rows; lifecycle events remain as bounded audit history.

The capture name, notes, identifiers, ports, health labels, digests, and safe error summaries are local SwiftData. Keychain values remain in Keychain. No session data is uploaded.

## UI contract

The Sessions screen shows saved sessions, capture time, included projects, expected service state, ports, dependencies, previous health, current drift, and restore history. Restore preview shows estimated mutations, action reasons, dependency layers, all issues and recovery guidance, explicit confirmations, dry-run and rollback choices, and the final result.

Project screens show the same dependency layers used by project start/stop and session restoration. This keeps the visible topology aligned with the execution planner.

## Verification

`WorkspaceSessionTests` covers capture evidence, unsafe preflight conditions, dry-run non-mutation, dependency cycles, independent-service parallelism, dependency blocking, rollback, partial rollback, intentionally skipped stop behavior, comparison, and persistence conversion. Full-suite validation remains required before release.
