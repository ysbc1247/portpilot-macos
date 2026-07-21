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
- MCP clients are untrusted same-user callers. They reach only the app-owned control plane over a current-UID Unix socket; the STDIO helper owns no runtime or persistence authority.

## Control mitigations

Process signals require a strong fingerprint and exact listener-edge revalidation immediately before each signal, including force escalation. Protected/root/system processes are refused. Managed groups require a live registry and revalidated member. External observations never receive reconstructed restart authority.

Docker standalone actions target one full container ID. Compose actions require canonical labels, non-symlink path identity, matching configuration hash, exact membership, explicit CLI scope, and fresh proof before mutation. When service-wide proof is unavailable, Stop/Restart may fall back only to the exact associated container ID; Remove, sibling expansion, and host-PID fallback remain forbidden.

Command execution uses executable URLs and discrete arguments. Only explicitly reviewed shell definitions use a shell. Secret-like environment names are rejected outside Keychain; redaction occurs before logs or persistence. Diagnostics exclude commands, environment, Keychain values, and logs.

The MCP socket lives under `~/Library/Application Support/DevBerth/IPC`, with `0700` parent and `0600` socket modes, same-effective-UID peer checks, 4 MiB frames, deadlines, protocol/schema negotiation, and separate production/development paths. A live socket is never unlinked; stale removal rechecks owner, type, device, and inode. The helper uses STDIO only and writes diagnostics to stderr.

MCP runtime targets are stable listener IDs, never raw PIDs. Destructive actions require a five-minute, single-use preview and revalidate state versions, revisions, fingerprints, listener edges, ownership routes, and exact Docker/Compose context before execution. Change-set tokens are single-use and compensate already-applied configuration steps on failure. Production cannot call development fixtures or reset data.

MCP accepts opaque Keychain reference UUIDs only. Service inspection reports configured/resolved booleans without returning the UUID or value. Plaintext secret-like environment names are rejected, and secret canaries are tested across structured responses.

## Residual risks

macOS may hide metadata for other-user or protected processes, so some ownership remains unavailable or inferred. A same-user attacker can alter accessible files or runtime between observations; last-moment identity checks reduce but cannot make the host environment atomic. A reviewed executable can change after validation, which downgrades confidence until revalidation but cannot prevent that executable’s own behavior. DevBerth installs no privileged helper and makes no claim to manage root-only runtime.

## Security validation

Automated tests cover malformed command output, PID/fingerprint/listener changes, protected processes, force confirmation, group escape, shell boundaries, secret staging/redaction, exact restart digests, hostile discovery input, Compose scope changes, scoped session rollback, raw-PID rejection, stale/replayed operation and change-set tokens, revision conflicts, frame bounds, socket modes, live-socket protection, production/development isolation, and Release debug-tool exclusion. Every hosted test app skips production migration, disables the control socket, and uses in-memory empty or test-owned discovery.
