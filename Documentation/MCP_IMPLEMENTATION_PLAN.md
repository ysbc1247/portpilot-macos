# MCP implementation plan

Date: 2026-07-21 (Asia/Seoul)

## Outcome

Add a production `devberth-mcp serve --stdio` executable that exposes DevBerth's complete domain control plane while the DevBerth application remains the only runtime monitor, lifecycle authority, Keychain broker, and SwiftData writer.

## Target architecture

```text
SwiftUI / menu bar ───────┐
                         ▼
                  ApplicationControlPlane
                         │
              domain services + SwiftData V7
                         ▲
                         │ app-owned UDS, current UID only
Codex ── STDIO MCP ── devberth-mcp
```

Targets:

| Target | Responsibility |
| --- | --- |
| `DevBerthControlContracts` | Codable IPC envelopes, error codes, schemas, capability registry, annotations, resource/prompt metadata, bounded JSON framing |
| `DevBerth` | Existing UI/domain plus `ApplicationControlPlane`, V7 repository, operation/change-set coordinator, Unix-socket host, helper/configuration UI |
| `DevBerthMCP` | Official Swift MCP SDK bootstrap, STDIO transport, registries, IPC client, result formatting, host activation |
| `DevBerthMCPTests` | Registry parity, protocol, schemas, security, IPC, concurrency, operation/change-set, and end-to-end fixture tests |

The contracts target contains no SwiftUI, SwiftData, Docker, shell, process, or Keychain implementation. The MCP target depends on contracts and the official SDK, not GUI types. Only the app target can translate a request into existing domain services.

## Implementation sequence

1. Add the formal capability registry and generated parity validation. Registry entries include identifier, display name, category, query/command class, GUI/menu location, MCP tool, permission, preview/destructive flags, build availability, schema identifier, and test reference.
2. Add additive SwiftData V7 records for mutable revisions, port watches/reservations/aliases/ignore rules, tags, saved filters, associations, and MCP audit metadata. Add V6 migration coverage.
3. Introduce `ApplicationControlPlane` as the shared query/command facade. Route new MCP work and migrated GUI/menu actions through this facade. It composes the existing `AppModel` services and the one app-owned `ModelContainer`.
4. Add an actor-isolated operation planner with five-minute, opaque, single-use tokens; snapshot/revision/fingerprint/ownership preconditions; idempotency; compensation; and audit events. No token grants authority beyond the concrete preview.
5. Add a change-set planner with ordered validation, cycle/conflict/secret checks, atomic configuration writes where possible, bounded runtime compensation, expiration, and replay prevention.
6. Add the current-user Unix-socket host with version negotiation, client identity, request/correlation IDs, timeouts, cancellation, reconnect, frame limits, peer UID validation, and mutation serialization.
7. Add the Swift SDK 0.12.1 executable using protocol 2025-11-25. Register production tools, resources, prompts, annotations, structured content, progress notifications, and cancellation. STDOUT is owned exclusively by the transport; diagnostics use STDERR/unified logging.
8. Add development mode with a disposable V7 store and application-owned fixtures. Release tool discovery omits every `dev_*` tool.
9. Add helper install/update/repair/uninstall and atomic Codex TOML configuration support. Back up, parse, diff, validate, and roll back configuration changes.
10. Add Settings → Integrations → Codex & MCP with helper/host status, counts, connection validation, configuration preview, diagnostics, and development guidance.
11. Add protocol, parity, project, service, runtime, session, port, Docker, history/log, settings, operation, change-set, security, concurrency, migration, and acceptance tests.
12. Run build, Release/Debug discovery, protocol fixtures, all automated tests, acceptance scenarios, security canaries, and performance measurements. Record exact results without converting environmental skips into passes.

## IPC contract

- Socket: `~/Library/Application Support/DevBerth/IPC/control.sock`
- Directory/socket permissions: `0700` / `0600`
- Peer: same effective UID only
- Framing: four-byte big-endian length followed by UTF-8 JSON; request and response limits are enforced before allocation
- Handshake: control protocol version, product version, schema version, build mode, client name/version/instance ID
- Request: request ID, correlation ID, tool name, arguments, idempotency key, deadline, source (`mcp`)
- Response: common envelope or stable error; never secret values
- Concurrency: concurrent reads, serialized conflicting writes and destructive executions, no lock held during readiness waits
- Availability: connect, ask Launch Services to start DevBerth without activation, bounded retry, then `host_unavailable`

## Security and exclusions

- No arbitrary shell, Docker CLI, `brew`, `launchctl`, SQL, file writes, Keychain values, environment dumps, raw PIDs, approval bypass, safety disabling, or production reset.
- No production Streamable HTTP listener. It is unnecessary for a same-user macOS application and would add network authentication and exposure.
- No privileged helper.
- No MCP mapping for presentation-only Finder/Terminal/browser opening, opening/closing the DevBerth window, or quitting the app. These do not alter DevBerth's domain state and can unexpectedly disrupt the user.
- Kubernetes port forwards, SSH tunnels, Homebrew, and launchd remain inspectable. Mutation is available only when the existing ownership resolver produces exact controlling context; otherwise the host returns `unsupported_capability` or `ownership_changed`.
- MCP never accepts plaintext secrets. It can assign/remove opaque references, check resolution, and request secure GUI input.

## Validation gates

- `xcodegen generate` after `project.yml` changes.
- All-target Debug and Release builds, plus explicit `DevBerthMCP` Debug/Release builds.
- Unit and integration tests without touching unrelated user processes or containers.
- UI tests only with `DEVBERTH_UI_TESTING=1` and an in-memory store.
- MCP STDIO transcript test proves initialization, discovery, tool call, resource/prompt listing, cancellation, EOF, and no non-protocol STDOUT.
- Registry parity test proves GUI mappings, shared command route, destructive preview, Release availability, and schema consistency.
- Release binary discovery proves no development tools.
- Secret canaries prove values never cross IPC, structured results, logs, exports, diagnostics, or events.
- Operation and change-set tests prove expiration, replay refusal, stale revisions, stale snapshots, identity changes, and idempotency.

## Git delivery

Work is developed on `phase-3-full-mcp-control-plane`. After all quality gates, commits are pushed to the existing private repository. The completed branch is merged into `main`, `main` is pushed, repository visibility is rechecked, and the final report names the resulting HEAD.

