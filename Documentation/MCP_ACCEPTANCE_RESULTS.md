# MCP acceptance results

Date: 2026-07-21 (Asia/Seoul)

## Automated MCP checkpoint

The final `DevBerthMCPTests` target passed 19/19 tests. The complete non-UI application matrix passed 164/164 tests across `DevBerthTests`, `DevBerthIntegrationTests`, and `DevBerthMCPTests`.

The real development acceptance runner passed all nine scenarios through `ApplicationControlPlane.dispatch` with an in-memory V7 store and application-owned fixtures:

| Scenario | Result | Evidence exercised |
| --- | --- | --- |
| A — Create entire project | Pass | Bundled frontend/backend discovery, apply, two services, dependency, reservation, validation, isolated verification, start, topology, capture, previewed stop |
| B — Modify project | Pass | Revisioned rename, worker creation, expected port/reservation, ordered change set, immediate shared-container readback |
| C — Session lifecycle | Pass | Create/update/notes/remove expectation, export, diff, restore preview/execute, history, duplicate, previewed delete |
| D — Observed process adoption | Pass | Owned external-style listener discovery, ownership inspection, candidate, reviewed update, readiness, verification, safe stop, verified managed start |
| E — Safe conflict resolution | Pass | Owned occupying listener, conflict, exact preview effects, execute, backend verify/start, unrelated-process assertion |
| F — Coordinated change set | Pass | Two projects/services, dependency/ports/sessions, ordering, validation, reverse compensation after injected failure |
| G — Docker Compose control | Pass with environment limitation | Deterministic Docker-unavailable error and Compose association persistence; live daemon lifecycle was not executed because no usable daemon/context was available |
| H — GUI and MCP concurrency | Pass | MCP revision update, stale GUI save rejection, explicit current/attempted state, no silent overwrite |
| I — Development acceleration | Pass | Disposable project, fixture service, recent errors, executable parity validation, cleanup/reset, production-data assertion |

The runner returns `execution=real_control_plane_and_application_owned_fixtures`, `production_data_touched=false`, per-check structured evidence, and measured duration. Scenario cleanup stops fixture groups and managed runtimes; the final scenario resets all disposable V7 records.

## Security and isolation results

- Production and development handshake mismatch returns `production_data_protected`.
- Production rejects all `dev_*`; Release argument parsing rejects `--development`.
- Raw PID/process/command fields are rejected by operation preview.
- Secret-like plaintext environment input is rejected; opaque references are not echoed and only configured/resolved booleans are returned.
- Operation/change-set expiry, stale snapshot, stale revision, single-use replay, and compensation paths pass.
- Socket parent/socket modes are `0700`/`0600`; live-host replacement and >4 MiB frames are refused.
- Eight concurrent Unix clients complete without cooperative-executor starvation.
- Hosted tests use an in-memory store, no control socket, and empty/test-owned discovery.
- V6 data migrates to V7 without changing V1–V6 schemas.

## Protocol results

The helper negotiates MCP `2025-11-25` through official Swift SDK 0.12.1. Production discovery lists 82 tools and no `dev_*`; development adds 12 tools. Resources, resource templates, resource reads, prompt listing, and prompt retrieval pass. Structured content matches the response envelope, progress tokens receive `0/1` and `1/1` notifications around host calls, advisory cancellation is protocol-clean, EOF shuts down cleanly, and stdout contains JSON only.

## Known environmental limitation

No live Docker daemon with a disposable canonical Compose project was available for the Phase 3 acceptance run. Existing Docker/Compose unit tests retain exact context/hash/membership and scoped lifecycle coverage; Scenario G truthfully exercises the unavailable and persistence paths rather than reporting a skipped daemon workflow as a pass.

## Final validation

- `xcodegen generate`: passed.
- Clean detached-worktree Release application build (arm64, fresh Derived Data): passed; regeneration left the committed tree clean.
- Debug application build: passed.
- Universal Release application build: passed with warnings treated as errors.
- Debug and Release `DevBerthMCP` scheme builds: passed.
- `DevBerthMCPTests`: 19 passed, 0 failed, 0 skipped.
- `DevBerthTests` + `DevBerthIntegrationTests` + `DevBerthMCPTests`: 164 passed, 0 failed, 0 skipped.
- Exact full `DevBerth` scheme, including four UI tests: 168 passed, 0 failed, 0 skipped. An earlier attempt timed out while enabling Xcode automation mode; the final retry completed successfully.
- Release helper development-mode gate: exited 64, wrote zero bytes to stdout, and reported that development mode is absent.
- Visual QA: the real Settings → Integrations · Codex & MCP interface was exercised with Computer Use and captured at [Screenshots/mcp-codex-settings.png](Screenshots/mcp-codex-settings.png). This pass also found and fixed a missing `ControlHostStatusModel` injection on the in-app Settings navigation route.
- GitHub repository visibility: `PRIVATE`.
