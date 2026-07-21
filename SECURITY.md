# Security policy

## Command execution boundaries

Trusted system and Docker tools are invoked by absolute executable URL with separate argument arrays through `CommandRunning`. DevBerth never concatenates discovered values into a shell command. A shell is used only when a user explicitly selects a login/custom shell for a reviewed launch profile.

Discovered commands are untrusted suggestions. Saving a discovered process requires review, and `ManagedProcessLauncher` refuses a profile that is not marked reviewed.

## Process termination safeguards

- Root-owned and recognized Apple/system processes are blocked.
- Strong identity requires PID, full executable path, and process start time.
- Identity is re-queried immediately before `SIGTERM` or `SIGKILL`.
- A mismatch aborts with no signal.
- Force stop requires explicit UI confirmation and records the result.
- Port conflicts never cause an automatic kill.
- DevBerth never silently requests administrator privileges and installs no privileged helper.

## Secrets

Secret values are stored as device-only Keychain generic passwords. SwiftData records contain only environment names and UUID references. Secret values are injected only at launch and redacted before managed output reaches memory or disk. Diagnostics exclude environment values, commands, logs, and Keychain contents.

Do not put secrets in profile arguments or custom shell text; process arguments can be visible to other local tools and users with sufficient permissions.

## Local-only policy

DevBerth does not include analytics, telemetry, crash-reporting SDKs, cloud sync, or an application data upload endpoint. Optional HTTP health checks contact only URLs explicitly configured by the user. Docker commands contact the user’s configured local/remote Docker context as Docker itself defines.

## App permissions

DevBerth is not App Sandbox-enabled because global port discovery and signaling are core features. Hardened Runtime is enabled. Normal operation does not require root.

## Reporting a vulnerability

Open a private GitHub security advisory for `ysbc1247/portpilot-macos`. Do not include credentials, secret environment values, private command lines, or unrelated process data in a public issue. Include a minimal reproduction, affected commit, macOS version, and expected security boundary.

