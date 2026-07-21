# Restart trust and managed-service validation

Decision date: 2026-07-21 (Asia/Seoul)

## Purpose

DevBerth never equates an observed command line with a reliable restart recipe. Restart trust describes what is known, what was reviewed, and what the application has actually proved for one exact managed-service definition.

## States

| State | Meaning | Normal Start action |
| --- | --- | --- |
| Verified restartable | The reviewed current definition completed an isolated managed launch, required-listener or health readiness, and controlled stop | Enabled |
| Conditionally restartable | The definition is reviewed but lacks matching successful validation, readiness criteria, or has launch-critical drift | Replaced by Review & Validate |
| Inferred restart candidate | Observed or reconstructed fields have not all been reviewed | Replaced by Review & Validate |
| Not restartable | Required fields, filesystem context, safety identity, or secret handling are missing or unsafe | Replaced by Repair/Review |

The UI communicates every state with text, an icon, and explanatory reasons. Color is supplemental only.

## Exact-validation contract

`ManagedServiceConfigurationDigest` is a stable, sorted digest of launch-critical intent: mechanism, command, exact arguments, working directory, shell behavior, non-secret environment, Keychain reference mapping, expected listeners, timeouts, restart policy, process-group policy, health check, and dependencies. Presentation metadata such as name, tags, favorite state, and automatic-launch preference does not invalidate an otherwise identical launch recipe.

`ManagedServiceValidationRunner` is the only launch path allowed to bypass the trust gate. It performs preflight validation, launches through the normal controlled-process-group coordinator, waits for required listeners and health, and performs a controlled stop. A successful result stores its exact configuration digest and safe structured evidence. Failed runs do not expose environment or Keychain values.

Every ordinary profile, project, favorite, menu-bar, and automatic launch asks `RestartTrustEvaluator` to compare the latest successful V4 validation record with the current digest. Configuration drift immediately returns the service to conditional. A presentation-only edit reuses the exact validation rather than accidentally downgrading it.

## Observed-process conversion

The Active Ports inspector presents observations as inferred evidence. Conversion is a guided sequence:

1. review the raw command and author exact argument boundaries;
2. confirm the working directory and shell behavior;
3. reconstruct non-secret environment requirements;
4. add secret values to transient secure fields for Keychain staging;
5. configure a required listener and optional HTTP readiness check;
6. explicitly review the reconstructed definition;
7. explicitly approve revalidation and graceful stop of the occupying observed owner;
8. run isolated launch, readiness, and controlled-stop validation;
9. save the managed service and matching validation only after success.

The original process is never stopped silently. If startup fails after the approved stop, DevBerth reports that it remains stopped and does not guess how to recreate it.

## Secret lifecycle

`ManagedEnvironmentParser` rejects duplicate, malformed, and secret-like plaintext names without returning secret values in errors. `SecretLifecycleCoordinator` stages Keychain writes before validation, retains prior values only in transient actor memory for rollback, and restores or deletes staged items if validation or SwiftData persistence fails.

Edits delete a removed Keychain reference only after the profile save succeeds and only when no remaining profile references it. Duplication copies each value into a fresh opaque reference; a duplicate never shares secret lifecycle with its source. Deletion removes only references no surviving profile uses. SwiftData, validation evidence, logs, diagnostics, and errors contain names or UUID references, never values.

## Persistence and migration

`DevBerthSchemaV4` adds one unique `ManagedServiceValidationRecord` per managed service. It stores the latest validation ID, exact configuration digest, success/failure status, safe summary/evidence, and timestamps. `ManagedServiceTrustRecord` remains the current assessment cache. The V3→V4 migration is lightweight and additive.

A genuine V3 fixture proves existing launch profiles survive and begin with no invented validation. Therefore existing profiles are conditional until the user completes a successful validation; the migration never overstates restart reliability.

## Known limits

- HTTP validation currently proves expected status, not response text.
- Externally observed processes cannot expose their complete original environment or shell state.
- Failed unsaved edit candidates are shown in the editor but do not replace the latest persisted validation for the currently saved definition.
