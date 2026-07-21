# MCP prompts

Prompts are conservative workflow guides. They do not grant permission, execute tools, or weaken server-side gates.

| Prompt | Availability | Workflow |
| --- | --- | --- |
| `inspect_local_runtime` | Production | Read snapshot, inspect and explain selected stable runtime IDs without mutation |
| `diagnose_port_conflict` | Production | Inspect port/owner evidence, preview safest exact resolution, wait for approval |
| `onboard_existing_project` | Production | Discover only a user-selected root, review untrusted candidates, apply selections |
| `create_managed_service` | Production | Create reviewed intent without plaintext secrets and report trust state |
| `verify_service` | Production | Inspect, run isolated verification, separate process/listener/readiness/health evidence |
| `restore_workspace_session` | Production | Inspect/diff, preview, resolve blockers, approve, execute restore |
| `review_unhealthy_services` | Production | Query deterministic lifecycle/health evidence and distinguish runtime facts |
| `prepare_project_shutdown` | Production | Inspect topology/dependencies and preview exact project stop |
| `analyze_unexpected_process` | Production | Inspect stable runtime and ownership graph; keep inference non-authoritative |
| `run_development_acceptance_suite` | Debug development only | Verify isolated identity, run all disposable scenarios, report each result |

Prompt arguments are accepted as optional client context. The server prompt text never asks for raw PIDs, secret values, arbitrary commands, or an approval bypass. Essential behavior remains available as tools because MCP client prompt support varies.
