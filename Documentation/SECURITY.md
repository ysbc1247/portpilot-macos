# Security model and threat analysis

## Protected assets

DevBerth protects the user’s running processes and containers, project files, launch definitions, Keychain secrets, local history/logs, and trust in displayed ownership. Its main adversarial conditions are stale observations, PID reuse, misleading lineage or Docker labels, hostile project files, secret disclosure, shell injection, and unintended control of unrelated runtime.

## Trust boundaries

- Operating-system and Docker output is untrusted input that must parse into bounded value types.
- Observation and inference never grant lifecycle authority.
- User-authored managed-service definitions become startable only after exact isolated validation.
- Project discovery reads selected bounded regular non-symlink files and never executes their contents.
- Keychain holds secret values; SwiftData holds opaque references.
- SwiftUI invokes service protocols and `AppModel`; it never executes a command directly.

## Control mitigations

Process signals require a strong fingerprint and exact listener-edge revalidation immediately before each signal, including force escalation. Protected/root/system processes are refused. Managed groups require a live registry and revalidated member. External observations never receive reconstructed restart authority.

Docker standalone actions target one full container ID. Compose actions require canonical labels, non-symlink path identity, matching configuration hash, exact membership, explicit CLI scope, and fresh proof before mutation. They never fall back to a host PID.

Command execution uses executable URLs and discrete arguments. Only explicitly reviewed shell definitions use a shell. Secret-like environment names are rejected outside Keychain; redaction occurs before logs or persistence. Diagnostics exclude commands, environment, Keychain values, and logs.

## Residual risks

macOS may hide metadata for other-user or protected processes, so some ownership remains unavailable or inferred. A same-user attacker can alter accessible files or runtime between observations; last-moment identity checks reduce but cannot make the host environment atomic. A reviewed executable can change after validation, which downgrades confidence until revalidation but cannot prevent that executable’s own behavior. DevBerth installs no privileged helper and makes no claim to manage root-only runtime.

## Security validation

Automated tests cover malformed command output, PID/fingerprint/listener changes, protected processes, force confirmation, group escape, shell boundaries, secret staging/redaction, exact restart digests, hostile discovery input, Compose scope changes, and scoped session rollback. Integration tests control only owned fixtures. UI-test mode skips production migration and uses in-memory static fixtures.

