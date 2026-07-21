# MCP tool reference

The executable registry in `DevBerthControlContracts/CapabilityRegistry.swift` is authoritative. Production exposes 82 tools. Debug development mode exposes those tools plus 12 `dev_*` tools.

Approval legend: **A** = automatic read-only; **P** = client write/runtime approval; **D** = destructive approval plus server preview enforcement where required; **Dev** = isolated Debug host only. Codex policy is advisory defense in depth; the app always enforces revisions, trust, ownership, and previews.

## Common request and response

Every input is a JSON object. Unknown or unsafe fields are rejected where they could expand authority. UUIDs and listener IDs must come from current DevBerth results; a raw PID is never a runtime target. Mutating an existing entity should include its current integer `revision`. Query inputs commonly accept `query`, `filters`, `limit`, and `cursor`; results are bounded.

Every successful tool returns both MCP text and `structuredContent` containing:

| Field | Meaning |
| --- | --- |
| `schema_version` | Tool schema version (`1`) |
| `request_id` | Correlation-safe request identifier |
| `snapshot_version` | App control-plane state version |
| `generated_at` | ISO-8601 response time |
| `data` | Tool-specific result described below |
| `warnings` | Bounded structured warnings |
| `truncated` | Whether more rows exist |
| `next_cursor` | Continuation cursor when truncated |

Failures set MCP `isError=true` and replace `data` with `error: {code, message, recovery_suggestion?, details?}` in the same envelope.

## Runtime and projects

| Tool | Inputs | `data` result | Approval |
| --- | --- | --- | --- |
| `runtime_snapshot` | none | listeners/processes, managed runtime statuses, counts, snapshot metadata | A |
| `runtime_search` | optional `query`, `filters`, `limit`, `cursor` | matching bounded runtime rows | A |
| `runtime_inspect` | `runtime_id` | exact listener/process/fingerprint/resource/owner/service/Docker evidence | A |
| `runtime_explain` | `runtime_id` | ownership graph, confidence/method/evidence, supported safe actions | A |
| `runtime_update_metadata` | stable `id`, optional `revision`, metadata/action fields | created or revised runtime metadata record | P |
| `projects_list` | optional `query`, `filters`, `limit`, `cursor` | project summaries and revisions | A |
| `project_inspect` | `project_id` | project, services, sessions, dependencies, runtime topology | A |
| `project_create` | `name`; optional caller `id`, `folder_path`, metadata | created project and revision | P |
| `project_update` | `project_id`, `revision`, `patch` | revised project | P |
| `project_duplicate` | `project_id`; optional `name`, options | independent copied project | P |
| `project_discover` | `root_path` | expiring discovery ID, review-only candidates/evidence | A |
| `project_apply_discovery` | `discovery_id`, `project_id`; optional selection | imported unreviewed service definitions | P |
| `project_import` | `path` or manifest payload; optional `apply` | validation preview or imported project/definitions | P |
| `project_export` | `project_id`; optional `path` | redacted versioned manifest and application-owned output path | A |
| `project_archive` | `project_id`, `revision`, optional `archived` | revised archive state | P |
| `project_delete` | `project_id`, optional `revision` | deletion when no references; otherwise required-operation details | D |
| `project_validate` | `project_id` | validity, cycles/missing definitions/ports/secrets/trust issues | A |

## Managed services and dependencies

Service create/update configuration may include launch mechanism, executable/command, discrete arguments, reviewed custom-shell intent, working directory, non-secret environment, opaque `secret_references`, expected ports, dependencies, timeouts, checks, shutdown/restart/log policy, project, tags, favorite/enabled/archive metadata. Plaintext secret-like environment keys are rejected.

| Tool | Inputs | `data` result | Approval |
| --- | --- | --- | --- |
| `services_list` | optional `query`, `filters`, `limit`, `cursor` | safe service summaries, revisions, trust/runtime state | A |
| `service_inspect` | `service_id` | safe definition, checks, expected ports/dependencies, trust, runtime, secret configured/resolved booleans | A |
| `service_create` | `name`; optional caller `id` and configuration fields | created unverified service and revision | P |
| `service_update` | `service_id`, `revision`, `patch` | revised service; verification invalidated when digest changes | P |
| `service_duplicate` | `service_id`; optional `name` | independent unverified copy; no secret value copied | P |
| `service_adopt_runtime` | `runtime_id`, `project_id`; optional reviewed fields | unverified candidate derived from observed evidence | P |
| `service_verify` | `service_id` | isolated start/listener/readiness/check/controlled-stop evidence and trust result | P |
| `service_enable` | `service_id`, `revision`, `enabled` | revised enabled state | P |
| `service_archive` | `service_id`, `revision`, optional `archived` | revised archive state | P |
| `service_delete` | `service_id`, optional `revision` | deletion when stopped/unreferenced; otherwise required-operation details | D |
| `service_start` | `service_id`; optional `wait_level` | managed runtime ID and observed start/readiness state | P |
| `service_recover` | `service_id`; optional recovery options | bounded configured recovery result | P |
| `dependency_graph_get` | optional project/service filters | graph nodes/edges and current revisions | A |
| `dependency_update` | `service_id`, `dependency_service_id`, `action` (`add`/`remove`), `revision` | revised service dependency set | P |
| `dependency_validate` | optional project/service filters | topological layers or cycle/missing-dependency issues | A |

## Workspace sessions

| Tool | Inputs | `data` result | Approval |
| --- | --- | --- | --- |
| `sessions_list` | optional `query`, `filters`, `limit`, `cursor` | session summaries and revisions | A |
| `session_inspect` | `session_id` | expectations, project/service IDs, drift, restore history, revision | A |
| `session_create` | `name`; optional caller `id`, `project_ids`, `services`, notes/options | created explicit session | P |
| `session_capture` | `name`; optional `project_ids`, `service_ids` | captured managed-only session | P |
| `session_update` | `session_id`, `revision`, `patch` | revised session metadata/expectations | P |
| `session_update_from_runtime` | `session_id`, `revision`, selected IDs/options | revised selected expectations based on current managed state | P |
| `session_duplicate` | `session_id`; optional `name` | independent copied session | P |
| `session_diff` | `session_id` | bounded added/missing/digest/port/health/runtime drift | A |
| `session_export` | `session_id`; optional `path` | redacted session manifest/output path | A |
| `session_import` | `path` or `session`; optional `apply` | validation preview or imported session | P |
| `session_archive` | `session_id`, `revision`, optional `archived` | revised archive state | P |
| `session_delete` | `session_id`, optional `revision` | deletion when no history references; otherwise required-operation details | D |
| `session_restore_preview` | `session_id`; optional restore `options` | fresh preflight/diff plus a concrete `restore_session` operation preview | A |

## Ports and organization

Generic port records accept caller `id` on create, `port_id` plus `revision` on update/delete, and type-specific fields in `patch` or top level. Ports must be 1–65535.

| Tool | Inputs | `data` result | Approval |
| --- | --- | --- | --- |
| `ports_list` | optional `query`, `filters`, `limit`, `cursor` | active, expected, watched, reserved, aliased, ignored port records | A |
| `port_inspect` | `port_id` or `port` | runtime owner/conflict/organization evidence and supported actions | A |
| `port_watch_create` | `name`, `port`; optional protocol/project/service/options | watch and revision | P |
| `port_watch_update` | `port_id`, `revision`, `patch` | revised watch | P |
| `port_watch_delete` | `port_id`, `revision` | deleted watch ID | P |
| `port_reservation_create` | `name`, `port`; optional project/service/options | reservation and revision | P |
| `port_reservation_update` | `port_id`, `revision`, `patch` | revised reservation | P |
| `port_reservation_delete` | `port_id`, `revision` | deleted reservation ID | P |
| `port_alias_create` | `name`, `port`; optional local alias metadata | alias and revision | P |
| `port_alias_update` | `port_id`, `revision`, `patch` | revised alias | P |
| `port_alias_delete` | `port_id`, `revision` | deleted alias ID | P |
| `port_ignore_rule_create` | `name`; port/process/project match fields | ignore rule and revision | P |
| `port_ignore_rule_delete` | `port_id`, `revision` | deleted ignore-rule ID | P |
| `favorites_update` | stable `id`, `action` or favorite value; optional kind/revision | favorite record/state | P |
| `tags_manage` | `action`; tag IDs/names/merge targets and optional revision | created/revised/merged/deleted tag result | P/D conditional |
| `saved_filter_create` | `name`; filter payload, optional caller `id` | saved filter and revision | P |
| `saved_filter_update` | stable `id`, `revision`, `patch` | revised filter | P |
| `saved_filter_delete` | stable `id`, `revision` | deleted filter ID | P |

## Docker, logs, history, diagnostics, and settings

| Tool | Inputs | `data` result | Approval |
| --- | --- | --- | --- |
| `docker_status` | none | CLI/daemon availability and safe status | A |
| `docker_containers_list` | optional filters/limit/cursor | bounded running containers and published mappings | A |
| `docker_container_inspect` | `container_id` | exact container state/health/restart/ports/Compose evidence | A |
| `docker_compose_projects_list` | optional filters/limit/cursor | verified/inspection-only Compose group summaries | A |
| `docker_compose_project_inspect` | `compose_project_id` | services, containers, canonical context and verification state | A |
| `docker_association_update` | stable `id`/container plus project/service association and optional revision | persisted association metadata | P |
| `docker_import_compose_project` | Compose project/context selection and project options | imported project/service definitions or validation issues | P |
| `service_logs` | `service_id`; optional `query`, `limit`, `cursor` | bounded redacted log entries | A |
| `logs_export` | `service_id`; optional `query`, `path`, bounds | application-owned redacted export path/count | P |
| `history_query` | optional `query`, `filters`, `limit`, `cursor` | bounded lifecycle/audit evidence | A |
| `history_event_inspect` | `event_id` | event, context, related IDs, deterministic evidence | A |
| `history_export` | filters/IDs and optional `path` | bounded redacted history export path/count | A |
| `diagnostics_analyze` | optional event/service/runtime IDs and filters | deterministic cause/evidence/next-action analysis | A |
| `settings_get` | none | safe product/runtime/MCP settings; never credentials | A |
| `settings_update` | settings `patch` and optional revision | applied safe settings and current values | P |

## Destructive operations

`operation_preview` supports: `stop_runtime`, `force_stop_runtime`, `stop_service`, `restart_service`, `stop_project`, `restart_project`, `stop_selected_project_services`, `restore_session`, `release_occupied_port`, `resolve_port_conflict`, `stop_docker_container`, `restart_docker_container`, `stop_compose_service`, `restart_compose_service`, `stop_compose_project`, `restart_compose_project`, `stop_homebrew_service`, `restart_homebrew_service`, `stop_kubernetes_port_forward`, `stop_ssh_tunnel`, `delete_project_with_dependencies`, `delete_managed_service_with_references`, `delete_session_with_history`, `clear_selected_history`, `clear_selected_logs`, `remove_local_aliases_bulk`, and `apply_destructive_change_set`.

| Tool | Inputs | `data` result | Approval |
| --- | --- | --- | --- |
| `operation_preview` | `operation_type`, nonempty stable `targets`, optional `options`; raw PID/process/command fields forbidden | `operation_id`, exact targets, revisions/fingerprints/listener edges/owners/evidence, affected ports/dependencies/sessions, risks, compensation, expiry | A (no mutation) |
| `operation_execute` | `operation_id`; optional `idempotency_key` | per-target results and compensation status | D |
| `change_set_preview` | nonempty `changes[]` of allowed `{tool, arguments}` steps, maximum 100 | token, normalized ordered plan, revision preconditions, warnings, compensation, expiry | A (no mutation) |
| `change_set_execute` | `change_set_token`; optional `idempotency_key` | ordered per-step results and compensation status | P/D according to preview |

Allowed change-set steps are bounded configuration commands. Dependency and create steps are ordered before consumers. Destructive steps require an outer `apply_destructive_change_set` operation preview; a change-set token alone never authorizes an arbitrary runtime action.

For `stop_service`, `restart_service`, and project stop previews, an expected-port observation is captured as current evidence rather than control or restart authority. Execution resolves the owner again and requires the same exact fingerprint, listener edge, protected-process policy, and controller context as the native UI. Multiple observed ports are deduplicated only when they route to the same exact host process, Docker container, or verified Compose service.

## Development tools

| Tool | Inputs | `data` result | Approval |
| --- | --- | --- | --- |
| `dev_build_info` | none | build, git when available, protocol/schema/features | Dev |
| `dev_internal_state` | none | bounded monitor/task/cache/fixture/persistence state | Dev |
| `dev_fixture_list` | none | fixture catalog and active counts | Dev |
| `dev_fixture_start` | `name`; optional `port` | owned fixture ID/PID/groups/ports or simulated state | Dev |
| `dev_fixture_stop` | `fixture_id` | stopped state | Dev |
| `dev_acceptance_scenario_run` | `name` | one real isolated scenario result/checks/duration | Dev |
| `dev_acceptance_suite_run` | none | all nine scenario results and isolation assertion | Dev |
| `dev_migration_validate` | none | schema/stage inventory and validity | Dev |
| `dev_performance_measure` | optional `iterations` (1–200) | bounded query/mutation latency measurements | Dev |
| `dev_recent_errors` | none | latest bounded structured errors | Dev |
| `dev_test_store_reset` | `confirm=true` | disposable store/fixture reset and production-data assertion | Dev/D |
| `dev_capability_parity_validate` | none | duplicate/schema/preview/test-reference validation | Dev |

## Stable error codes

| Code | Meaning / recovery |
| --- | --- |
| `invalid_arguments` | Schema, identifier, port, unsafe field, or validation error; correct input |
| `entity_not_found` | Stable target no longer exists; list/inspect again |
| `entity_changed` | Revision/evidence changed; reconcile and resubmit current revision |
| `stale_snapshot` | State changed after preview; create a new preview |
| `identity_mismatch` | Process fingerprint changed; no signal was sent |
| `ownership_changed` | Listener/controller/Compose authority changed; inspect again |
| `operation_expired` | Five-minute operation lease expired; preview again |
| `operation_already_used` | Operation/change token replay; never retry it |
| `operation_not_approved` | Required destructive preview/confirmation is missing |
| `change_set_expired` | Change-set lease expired or unavailable |
| `conflict_detected` | Port, identifier, active runtime, or concurrent plan conflict |
| `dependency_cycle` | Dependency graph is cyclic; remove an indicated edge |
| `service_not_verified` | Exact configuration digest lacks restart trust; verify it |
| `missing_dependency` | Referenced project/service/dependency is absent |
| `missing_secret_reference` | Keychain reference is unresolved; enter value in GUI |
| `secret_input_required` | Secure GUI input is required; MCP cannot provide value |
| `host_unavailable` | App control host did not become reachable |
| `docker_unavailable` | Docker CLI/daemon/context is unavailable |
| `permission_denied` | OS, protected-process, path, or policy boundary refused |
| `timeout` | Deadline/readiness/IPC timeout; inspect current state before retry |
| `result_too_large` | Narrow filters or follow pagination |
| `unsupported_capability` | Active owner/build/platform does not support operation |
| `development_mode_required` | `dev_*` called on production host |
| `production_data_protected` | Production/development handshake or isolation violation |
| `internal_error` | Unexpected bounded failure; inspect diagnostics/recent errors |

MCP negotiation/schema failures may additionally use standard JSON-RPC/MCP invalid-request or invalid-parameter errors before a DevBerth envelope exists.
