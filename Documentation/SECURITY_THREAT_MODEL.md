# Security threat model

## Scope and assets

Protected assets are unrelated user processes and containers, project files, managed-service definitions, Keychain secrets, local history/logs, and the integrity of ownership/restart claims. The attacker may be a same-user process, malicious project checkout, stale runtime state, misleading Docker/Compose metadata, or an accidentally unsafe imported command. DevBerth does not defend a compromised root account or kernel.

| Threat | Boundary and mitigation | Residual limitation |
| --- | --- | --- |
| Stale PID / PID reuse | Require PID, UID, executable path/file identity, start time, command digest, parent PID, and exact listener edge; re-query immediately before every signal and escalation. | Separate OS observations cannot be atomic; any mismatch refuses. |
| Shell injection / command substitution | Invoke trusted tools by absolute URL and discrete arguments. Only explicitly reviewed login/custom-shell definitions use a shell. Discovered strings are never interpolated into a shell command. | User-authored custom shell text has normal shell power. |
| Malicious project files | Read only selected-root, bounded, regular non-symlink files; parsers do not evaluate scripts, variables, includes, or package-manager commands. | Complex definitions may be omitted or require manual review. |
| Malicious imported or inferred commands | Every candidate remains unreviewed. Preserve exact argument boundaries where available; process command text is never auto-split into authority. Require isolated start/readiness/stop validation for the exact digest. | Validation proves the test behavior, not that arbitrary application code is benign. |
| Path manipulation / symlink changes | Normalize roots; reject discovery symlinks. Compose paths require absolute non-symlink component identities and fresh device/inode/size/mtime evidence. Check working directories/executables before launch. | Same-user files can change after a check; changed evidence requires revalidation. |
| Executable replacement | Fingerprints include executable device/inode; destructive actions compare fresh identity. Managed restart validation binds authored path/arguments. | A program may change behavior without changing all configuration. |
| Environment-variable leaks | Reject secret-like plaintext names; keep values in Keychain; inject only at launch; exclude values from SwiftData, lifecycle details, diagnostics, and manifests. | Arguments and custom shell text must not contain secrets. |
| Keychain access | Use device-only generic-password items addressed by opaque UUID. Stage/rollback changes, clone references on duplication, and delete only after persistence/reference checks. | macOS ultimately governs same-user Keychain access. |
| Secret logging | Redact known values across arbitrary output chunk boundaries before memory/disk; bound memory and disk; export only already-redacted logs. | Unknown secrets not supplied through DevBerth cannot be recognized reliably. |
| Docker command scope | Address standalone actions by one full container ID and refresh exact inspection first. Never shell, broaden, or fall back to the host PID. | Docker authority follows the configured daemon/context. |
| Compose project confusion | Require canonical project/service/files/directory/env/hash labels, non-symlink path identity, exact hash and membership, explicit CLI scope, and fresh proof. One-offs are inspection-only. | Incomplete contexts cannot be controlled as Compose services. |
| Log-file growth | Keep 2,000 in-memory entries and a bounded file. Append normally; overflow rotates to half maximum so full reads/rewrites occur only at rotation. | Disk-full or I/O failure may drop logs and is reported locally. |
| Diagnostics export | Export is explicit and excludes commands, environment, logs, Keychain values, and HTTP/command bodies. | Listener summaries disclose local port/process names to the file recipient. |
| Privilege escalation | Install no helper, request no silent elevation, and reject root/recognized system processes. Hardened Runtime remains enabled. | Global observation/control requires App Sandbox to remain disabled. |
| Root-owned / other-user processes | Root/system targets are protected. Inaccessible fields remain unavailable and cannot satisfy a strong fingerprint. | DevBerth cannot explain metadata macOS withholds. |
| Untrusted HTTP health response | Enforce reviewed URL/status/text criteria and timeout/retry bounds; never persist response bodies. | The configured endpoint can observe health requests. |
| Local router exposure | The optional `.localhost` alias router is not implemented. Any future router must default to loopback, validate host routing, bound requests, and receive a separate review. | No routing convenience is claimed in Phase 2. |

## Execution rule

Finding a command in `package.json`, Makefile, Compose, Procfile, Process Compose, shell history, or process arguments never causes execution. Discovery yields review-only evidence. All actions pass through the same ownership, fingerprint, restart-trust, secret, and confirmation boundaries regardless of whether they originate in the main window, menu bar, command palette, project, or session.

