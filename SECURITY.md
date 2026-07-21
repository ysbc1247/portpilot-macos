# Security policy

## Command execution boundaries

Trusted system and Docker tools are invoked by absolute executable URL with separate argument arrays through `CommandRunning`. DevBerth never concatenates discovered values into a shell command. A shell is used only when a user explicitly selects a login/custom shell for a reviewed managed service.

Discovered commands are untrusted suggestions. Saving a discovered process requires review, and `ManagedProcessLauncher` refuses a profile that is not marked reviewed.

## Process termination safeguards

- Root-owned and recognized Apple/system processes are blocked.
- Strong identity requires PID, numeric UID, full executable path and file identity when available, process start time, command digest, and parent PID.
- Identity is re-queried immediately before `SIGTERM` or `SIGKILL`.
- The exact protocol/address/port listener edge is re-queried with the fingerprint.
- A mismatch aborts with no signal.
- Force stop requires explicit UI confirmation and records the result.
- Port conflicts never cause an automatic kill.
- DevBerth never silently requests administrator privileges and installs no privileged helper.

## Secrets

Secret values are stored as device-only Keychain generic passwords. SwiftData records contain only environment names and UUID references. Secret values are injected only at launch and redacted before managed output reaches memory or disk. Diagnostics exclude environment values, commands, logs, and Keychain contents.

Do not put secrets in profile arguments or custom shell text; process arguments can be visible to other local tools and users with sufficient permissions.

Known secret values are redacted across arbitrary stdout/stderr chunk boundaries before entering the bounded memory or disk log. A same-user process can still emit an unknown secret DevBerth was never given, so log review remains necessary before sharing.

## Local-only policy

DevBerth does not include analytics, telemetry, crash-reporting SDKs, cloud sync, or an application data upload endpoint. Optional HTTP health checks contact only URLs explicitly configured by the user. Docker commands contact the user’s configured local/remote Docker context as Docker itself defines.

The optional MCP helper uses STDIO plus an app-owned current-user Unix socket; it never listens on TCP. Socket permissions, peer UID, frame limits, deadlines, protocol/build-mode negotiation, stable identifiers, revisions, and expiring single-use preview tokens are enforced by the app. MCP cannot retrieve Keychain values, accept raw PID authority, execute arbitrary commands, reset production data, or expose Debug tools from Release.

## App permissions

DevBerth is not App Sandbox-enabled because global port discovery and signaling are core features. Hardened Runtime is enabled. Normal operation does not require root.

## Reporting a vulnerability

Open a private GitHub security advisory for `ysbc1247/portpilot-macos`. Do not include credentials, secret environment values, private command lines, or unrelated process data in a public issue. Include a minimal reproduction, affected commit, macOS version, and expected security boundary.

The complete asset, attacker, mitigation, and residual-risk analysis is in [Documentation/SECURITY_THREAT_MODEL.md](Documentation/SECURITY_THREAT_MODEL.md).
