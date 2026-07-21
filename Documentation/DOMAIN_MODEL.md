# DevBerth Phase 2 domain model

Decision date: 2026-07-21 (Asia/Seoul)

## Purpose

DevBerth models operating-system evidence, user-authored intent, actual executions, ownership conclusions, and saved workspace state as different concepts. This prevents a discovered command from silently becoming a restart recipe and prevents transient PID state from becoming durable configuration.

## Truth boundaries

| Concept | Meaning | Lifetime | Durable record |
| --- | --- | --- | --- |
| `ObservedListener` | A socket endpoint currently reported by the operating system and its directly associated observed process | Current monitoring snapshot | No; only bounded event/observation history may be retained |
| `ObservedProcess` | Available external-process metadata, which may be incomplete | Current monitoring snapshot | No |
| `ManagedServiceConfiguration` | Reviewed user intent for launching, checking, stopping, restarting, logging, and ordering one service | Until edited or deleted | V1 `LaunchProfileRecord` compatibility storage plus related dependency/expected-port records |
| `RuntimeInstance` | One actual execution of one managed service | Start through exit and retention expiry | V2 `RuntimeInstanceRecord` |
| `ProcessFingerprint` | Safety evidence for one observed PID incarnation, including UID, executable identity, start, command digest, parent, and detection time | One observation/runtime incarnation | V3 `ProcessFingerprintRecord` when durable evidence is required |
| `ManagedServiceProcessPolicy` | Reviewed intent for a dedicated group and root-only versus group shutdown | Until edited or deleted | V3 `ManagedServiceProcessPolicyRecord` |
| `ProcessGroupSnapshot` | Leader, group ID, live/zombie members, listener owners, descendants, and escaped descendants at an evidence time | Runtime evidence retention window | V3 `ProcessGroupSnapshotRecord` |
| `OwnershipConclusion` | A confidence-labeled explanation of what controls a listener, process, or runtime, with evidence and detection method | Evidence retention window | V2 `OwnershipEvidenceRecord` |
| `RestartTrustAssessment` | Whether a managed service is verified, conditional, inferred-only, or not restartable, with reasons and validation time | Until configuration/evidence changes | V2 `ManagedServiceTrustRecord` |
| `ManagedServiceValidationResult` | Evidence that one exact launch-critical configuration completed isolated start, readiness, and controlled stop | Until replaced by a later validation | V4 `ManagedServiceValidationRecord` |
| `WorkspaceSession` | A reviewed snapshot of expected project/service state, listeners, dependencies, health, and configuration digests | Until deleted | V2 session and session-service records |
| `ProjectDiscoveryMetadata` | Adapter-produced discovery evidence before or after reviewed import | Discovery retention window | V2 `ProjectDiscoveryRecord` |
| `LifecycleEvent` | One runtime/service/project/session transition with structured references | Event retention window | V2 `LifecycleEventRecord` |

The existing “Launch Profiles” feature and `LaunchProfileRecord` class retain their V1 names only as compatibility surfaces. New domain and service code uses managed-service terminology. A future data migration may rename storage entities only if SwiftData compatibility is proven against shipped fixtures.

## Reference rules

- An observed listener embeds an observed process only because `lsof` directly reports the listener-to-PID edge. It contains no launch or restart configuration.
- A runtime instance references exactly one managed service and exactly one process fingerprint. A replacement process is a new runtime or a separately reconciled fingerprint, not an in-place PID update.
- Ownership conclusions reference a listener ID, process fingerprint, or runtime ID and always include confidence, evidence, method, and timestamp.
- `RuntimeOwnershipGraph` is transient reconciliation output. It carries the observed listener, process group, bounded lineage, primary/additional conclusions, managed/project/session references, and an owner-layer action recommendation; only its redacted conclusions are durable evidence.
- A workspace session contains only managed-service expectations. An unmanaged observed process must be converted and reviewed before it can be restored.
- Session service snapshots retain a configuration digest so restore preview can report drift rather than assuming the current definition matches the captured definition.
- A restart-trust assessment may be verified only when the latest successful validation digest exactly matches the current managed-service definition. An existing profile without V4 evidence remains conditional after migration.
- Project discovery evidence is inert. Detection never edits project files or creates a launchable service without review.
- A dedicated managed process group is an application-created ownership boundary. An external PGID is observation only and never grants group-signal authority.
- A descendant that leaves the controlled group remains ownership evidence but is excluded from group termination unless a separate reviewed controller claims it.
- An inferred owner category is explanatory evidence, not action authority. Lifecycle requests must route through a controller whose exact context is available; otherwise the action is refused without falling back to a PID signal.

## V2 persistence migration

`DevBerthSchemaV1` is frozen. `DevBerthSchemaV2` reuses every unchanged V1 entity and adds separate tables for runtime instances, ownership evidence, restart trust, workspace sessions, restore results, discovery metadata, and lifecycle events. The V1→V2 stage is lightweight and additive; it does not reinterpret or delete existing projects, profiles, ports, history, preferences, favorites, or logs.

Automated migration validation creates a genuine V1 store, snapshots it through the product-identity migrator, opens it with the V2 schema, and verifies the original project, managed-service compatibility record, expected port, history event, and preference. V2 persistence tests store each new concept in its own table.

The local development store was also opened under V2. All 1,278 event UUIDs from the retained PortPilot recovery store remained present. New V2 tables were empty immediately after migration, which is expected because runtime reconciliation, ownership controllers, session capture, and adapter import are separate implementation slices.

## V3 process-safety migration

`DevBerthSchemaV3` adds full fingerprint, managed process-policy, and process-group snapshot records without changing frozen V1/V2 entities. Automated validation materializes a genuine V2 store with a runtime record, opens it through the V2→V3 stage, proves that runtime unchanged, and proves the new tables begin empty. V3 persistence tests round-trip device/inode identity, UID, digest, parent, leader/group/member evidence, escaped descendants, and process policy.

The local development store opened under V3 with 2,668 current history rows and the three V3 tables present. The genuine V2 fixture provides the before/after preservation proof; the local row count is only an additional smoke check. Ownership conclusions now write through the production model actor with a newest-1,000 retention bound. Continuous runtime-instance and lifecycle-event persistence remain part of the runtime-lifecycle slice.

## V4 restart-validation migration

`DevBerthSchemaV4` adds `ManagedServiceValidationRecord` without changing frozen V1–V3 entities. The V3→V4 transition is lightweight and stores only the latest safe validation result for each managed service. A genuine V3 fixture proves an existing launch profile survives unchanged and the new table begins empty; migration does not manufacture verification from the mere presence of an old command.

The exact validation digest covers launch-critical configuration and deliberately excludes presentation-only fields. A critical edit invalidates verification immediately, while a rename or tag edit preserves matching proof. Secret values remain in Keychain; the validation record contains only identifiers, status, safe evidence, and timestamps.

## Consequences

- UI badges must say whether a value is observed, inferred, reviewed, or verified.
- Lifecycle actions must route through an owner/controller and cannot be enabled merely because an observation has a PID.
- Managed registration and exact Docker metadata may authorize their matching controller. Compose labels, Homebrew paths, launchd ancestry, supervisor ancestry, and other inference do not authorize service-manager actions without exact controller context.
- Restart availability must come from `RestartTrustAssessment`, not from the presence of a command line.
- Normal launch paths must also compare V4 validation evidence with the current configuration digest; a stale cached trust row cannot authorize launch.
- Runtime, ownership, lifecycle, and discovery tables require explicit retention policies before they receive continuous production writes.
- Adding records does not make the corresponding workflow complete. Controllers, reconciliation, retention, and UI remain required and must be verified independently.
