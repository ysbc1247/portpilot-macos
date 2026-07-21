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
| `OwnershipConclusion` | A confidence-labeled explanation of what controls a listener, process, or runtime, with evidence and detection method | Evidence retention window | V2 `OwnershipEvidenceRecord` |
| `RestartTrustAssessment` | Whether a managed service is verified, conditional, inferred-only, or not restartable, with reasons and validation time | Until configuration/evidence changes | V2 `ManagedServiceTrustRecord` |
| `WorkspaceSession` | A reviewed snapshot of expected project/service state, listeners, dependencies, health, and configuration digests | Until deleted | V2 session and session-service records |
| `ProjectDiscoveryMetadata` | Adapter-produced discovery evidence before or after reviewed import | Discovery retention window | V2 `ProjectDiscoveryRecord` |
| `LifecycleEvent` | One runtime/service/project/session transition with structured references | Event retention window | V2 `LifecycleEventRecord` |

The existing “Launch Profiles” feature and `LaunchProfileRecord` class retain their V1 names only as compatibility surfaces. New domain and service code uses managed-service terminology. A future data migration may rename storage entities only if SwiftData compatibility is proven against shipped fixtures.

## Reference rules

- An observed listener embeds an observed process only because `lsof` directly reports the listener-to-PID edge. It contains no launch or restart configuration.
- A runtime instance references exactly one managed service and exactly one process identity. A replacement process is a new runtime or a separately reconciled identity, not an in-place PID update.
- Ownership conclusions reference a listener ID, process identity, or runtime ID and always include confidence, evidence, method, and timestamp.
- A workspace session contains only managed-service expectations. An unmanaged observed process must be converted and reviewed before it can be restored.
- Session service snapshots retain a configuration digest so restore preview can report drift rather than assuming the current definition matches the captured definition.
- Project discovery evidence is inert. Detection never edits project files or creates a launchable service without review.

## V2 persistence migration

`DevBerthSchemaV1` is frozen. `DevBerthSchemaV2` reuses every unchanged V1 entity and adds separate tables for runtime instances, ownership evidence, restart trust, workspace sessions, restore results, discovery metadata, and lifecycle events. The V1→V2 stage is lightweight and additive; it does not reinterpret or delete existing projects, profiles, ports, history, preferences, favorites, or logs.

Automated migration validation creates a genuine V1 store, snapshots it through the product-identity migrator, opens it with the V2 schema, and verifies the original project, managed-service compatibility record, expected port, history event, and preference. V2 persistence tests store each new concept in its own table.

The local development store was also opened under V2. All 1,278 event UUIDs from the retained PortPilot recovery store remained present. New V2 tables were empty immediately after migration, which is expected because runtime reconciliation, ownership controllers, session capture, and adapter import are separate implementation slices.

## Consequences

- UI badges must say whether a value is observed, inferred, reviewed, or verified.
- Lifecycle actions must route through an owner/controller and cannot be enabled merely because an observation has a PID.
- Restart availability must come from `RestartTrustAssessment`, not from the presence of a command line.
- Runtime, ownership, lifecycle, and discovery tables require explicit retention policies before they receive continuous production writes.
- Adding records does not make the corresponding workflow complete. Controllers, reconciliation, retention, and UI remain required and must be verified independently.
