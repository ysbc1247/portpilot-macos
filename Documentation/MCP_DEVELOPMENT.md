# MCP development mode

Development MCP is an explicit Debug-only acceleration environment. It never opens the production SwiftData store and never discovers or controls unrelated runtime.

## Start

From the repository:

```bash
Scripts/run-mcp-development
```

The script builds Debug app/helper artifacts and prints or runs the project-scoped configuration. Equivalent helper arguments are:

```text
devberth-mcp serve --stdio --development --workspace /absolute/repository
```

The helper starts a separate app host with `--development-control-host`, `DEVBERTH_DEVELOPMENT_CONTROL=1`, and the explicit workspace. The host uses an in-memory V7 container, a separate development socket, application-owned fixtures, and a PID-scoped discoverer. A Release helper rejects `--development` with exit status 64 and exposes no development tools.

Suggested `.codex/config.toml`:

```toml
[mcp_servers.devberth-development]
command = "/absolute/path/to/Debug/devberth-mcp"
args = ["serve", "--stdio", "--development", "--workspace", "/absolute/repository"]
startup_timeout_sec = 15
tool_timeout_sec = 180
```

## Development tools

| Tool | Inputs | Result |
| --- | --- | --- |
| `dev_build_info` | none | Build/configuration, git identity when available, schema/protocol flags |
| `dev_internal_state` | none | Bounded monitor/tasks/caches/errors/persistence/fixture state |
| `dev_fixture_list` | none | Supported fixtures and active counts |
| `dev_fixture_start` | `name`, optional `port` | Owned fixture ID, PID/group IDs when applicable, kernel-assigned ports |
| `dev_fixture_stop` | `fixture_id` | Stopped state |
| `dev_acceptance_scenario_run` | `name` | Real control-plane checks and duration for one scenario |
| `dev_acceptance_suite_run` | none | All nine scenario results; production-data flag |
| `dev_migration_validate` | none | V1–V7 schema/stage inventory; fixture test requirement |
| `dev_performance_measure` | optional `iterations` (1–200) | Bounded query/mutation latency samples |
| `dev_recent_errors` | none | Latest bounded structured internal errors |
| `dev_test_store_reset` | `confirm=true` | Disposable store/fixtures reset; never production |
| `dev_capability_parity_validate` | none | Registry uniqueness/schema/preview/test-reference status |

Fixtures: simple TCP, simple HTTP, UDP, multiple listeners, delayed readiness, failed readiness, immediate exit, ignored SIGTERM, supervisor respawn, detached child, port conflict, dependency failure, Docker unavailable simulation, and PID reuse simulation.

Unrequested network fixtures bind port `0` so the kernel assigns a free port. The controller owns exact process groups and can stop only its handles. Development discovery scopes `lsof` to active fixture and managed-runtime PIDs before metadata enrichment.

## Acceptance

Run `dev_acceptance_suite_run`. It executes:

1. full project discovery/configuration/verification/start/capture/stop;
2. revisioned project modification in a change set;
3. full session lifecycle;
4. observed fixture adoption;
5. safe port-conflict resolution;
6. coordinated multi-project changes plus compensation;
7. Docker-unavailable and Compose-association behavior;
8. GUI/MCP stale-revision concurrency;
9. development parity/error/reset workflow.

Each scenario cleans up fixtures and managed runtimes. The final acceleration scenario resets the in-memory store and asserts `production_data_touched=false`.
