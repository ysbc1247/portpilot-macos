# MCP security

## Trust boundary

An MCP client is an untrusted same-user caller. `devberth-mcp` has no direct domain authority; it connects to the app-owned control host at:

```text
~/Library/Application Support/DevBerth/IPC/control.sock
```

Development uses `IPC/Development/control.sock`. The parent directory is mode `0700`, the socket is `0600`, and both sides require `getpeereid` to match the effective UID. Frames are four-byte big-endian length-prefixed JSON and are rejected above 4 MiB before allocation. Requests include protocol/schema versions, client identity/build mode, request/correlation IDs, deadline, source, and optional idempotency key.

The host refuses production/development mode mismatch. It does not unlink a live socket, and stale removal rechecks owner, socket type, device, and inode to resist path replacement. No TCP listener or privileged helper exists.

## Authorization model

| Class | Annotation/approval | Server enforcement |
| --- | --- | --- |
| Query | read-only, automatic | Bounded result; no mutation |
| Configuration | write, prompt | Stable ID, validation, optimistic revision, audit |
| Runtime start/verify/recover | write, prompt | Existing restart-trust and lifecycle checks |
| Conditional delete | destructive, prompt | Direct only when unreferenced; otherwise preview |
| Destructive runtime/configuration | destructive, prompt | `operation_preview` → approval → single-use execute |
| Coordinated changes | prompt/destructive when needed | `change_set_preview` → approval → single-use execute |
| Development | Debug-only | Separate in-memory host and fixtures |

Client approvals are defense in depth. Server checks remain mandatory even if a client misconfigures approval policy.

## Destructive operation safety

`operation_preview` accepts registered operation names and stable targets, never raw process or command fields. Its five-minute lease captures the exact snapshot version, entity revisions, process fingerprints, owner routes, Docker/Compose evidence, affected ports/dependencies/sessions, unrelated-process flag, risks, and compensation summary.

`operation_execute` requires that unused lease. Immediately before action, the app rechecks snapshot/revisions and current runtime evidence. Process actions still pass through `OwnerAwareLifecycleRouting`, `SafeProcessController`, or the managed runtime controller, which revalidates fingerprint and exact listener edge before every signal and before force escalation. Compose actions reconstruct and reverify the canonical context/hash/membership. A token is marked used before execution and cannot be replayed.

Change-set previews are also five-minute, single-use leases. They normalize ordering, reject missing references, port conflicts, cycles, unsupported tools, plaintext secrets, and stale revisions. Configuration steps run through the same dispatcher; already-applied configuration is compensated in reverse order on failure. Runtime actions remain explicit operation previews and do not gain implicit authority from a change set.

## Secrets and privacy

- MCP never returns Keychain values or opaque reference UUIDs.
- Secret-like plaintext environment fields are rejected.
- Service inspection reports each secret name as `configured` and `resolved` booleans.
- Logs, exports, diagnostics, lifecycle details, ownership evidence, sessions, and audit events remain bounded and secret-safe.
- The helper writes MCP only to stdout; usage/errors/version diagnostics go to stderr.
- There is no telemetry, cloud sync, or DevBerth data upload.

## Forbidden capabilities

The registry intentionally contains no arbitrary shell, executable, Docker CLI, `brew`, `launchctl`, SQL, Keychain read, environment dump, general file write, raw PID, approval bypass, safety-disable, privilege elevation, or production-reset tool.

## Validation coverage

Automated tests cover socket permissions/live-host protection/frame limits/concurrent clients, production/development mismatch, raw PID rejection, secret canaries, revisions, expiry, replay, stale snapshots, V6→V7 migration, protocol-clean stdout, Release tool exclusion, deterministic Docker-unavailable behavior, isolated fixture ownership, and real preview/execute paths. The broader Phase 1/2 suites retain fingerprint/listener/group/Compose/session rollback coverage.

Residual risk remains for any same-user client allowed to call approved MCP tools and for host state that changes after observation. A guarded instance stop may be recreated by an inferred supervisor or service manager; it does not become manager authority. Short leases, last-moment fingerprint/listener or container validation, protected-process refusals, and bounded audit reduce but do not make the local machine atomic.
