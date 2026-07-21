# MCP troubleshooting

## Helper is missing or outdated

Open **Settings → Integrations → Codex & MCP** and select **Install/Repair Helper**. Expected path:

```text
~/Library/Application Support/DevBerth/bin/devberth-mcp
```

Verify without polluting MCP stdout:

```bash
"$HOME/Library/Application Support/DevBerth/bin/devberth-mcp" --version 2>&1
```

The version command intentionally writes to stderr.

## Codex does not list DevBerth

1. Confirm the `[mcp_servers.devberth]` table points to the stable absolute helper path.
2. Ensure `args = ["serve", "--stdio"]`.
3. Reload MCP servers or restart Codex after editing configuration.
4. Use the Settings configuration preview; duplicate `[mcp_servers.devberth]` tables are rejected.
5. Confirm the helper is executable and the app is installed with bundle identifier `com.ysbc.devberth`.

## `host_unavailable`

Open DevBerth once and retry. The helper asks Launch Services to open it and waits about five seconds. Check Settings for control-host status. A stale socket may be removed only after owner/type/device/inode verification; a live host is never replaced.

If an old development host is running, stop that app normally. Production and development use separate sockets and reject cross-mode clients.

## `entity_changed` or `stale_snapshot`

Another GUI or MCP action changed configuration after inspection/preview. Re-inspect the entity, reconcile the current and attempted values, then resubmit with the new `revision`. Never silently retry an old write.

## `operation_expired` or `operation_already_used`

Previews expire after five minutes and are single-use. Create a fresh preview from current state, show its exact targets/risks again, obtain approval, and execute that new ID.

## `identity_mismatch` or `ownership_changed`

The process/listener/controller/Compose evidence changed. DevBerth intentionally sent no fallback signal. Refresh runtime state, inspect/explain again, and create a new preview only if the current exact owner supports it.

## `service_not_verified`

The current service digest lacks a successful isolated start/readiness/controlled-stop result. Inspect the definition and secret-resolution status, run `service_verify`, then use `service_start` only if verification succeeds.

## `missing_secret_reference` or `secret_input_required`

MCP cannot accept or reveal the value. Open the managed service in DevBerth and enter the secret through the secure Keychain-backed editor. Then re-inspect `configured`/`resolved` state.

## `docker_unavailable`

Listener monitoring remains usable. Start Docker or fix the configured Docker context, then retry. Compose mutations additionally require canonical labels, non-symlink files, exact config hash, and current container membership.

## Release rejects development mode

This is expected. Use `Scripts/run-mcp-development` with a Debug build and an explicit absolute workspace. Do not modify the Release binary or production configuration to expose `dev_*`.

## Protocol or timeout problems

- STDOUT must contain only newline-delimited MCP JSON. Wrapper scripts must send diagnostics to stderr.
- The host rejects frames above 4 MiB.
- Default host timeout is 60 seconds; operation/change-set execution uses 120 seconds.
- Use cursors and bounded log/history queries instead of requesting unbounded results.
- EOF cleanly stops the STDIO helper. Cancellation is advisory and handled by the SDK; server-side identity/preview checks still apply if work reached the host.
