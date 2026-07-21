# Control-plane parity

Date: 2026-07-21 (Asia/Seoul)

The executable capability registry is authoritative. This document is its human-readable contract. `Preview` means an expiring app-host token is mandatory before execution. `GUI` and `Menu` describe Phase 2 entry points; MCP-only organization operations are valid production capabilities when they extend the same application model rather than duplicate it.

| Capability ID | Capability | GUI | Menu | MCP tool | Class | Preview | Destructive | Builds | Test |
| --- | --- | ---: | ---: | --- | --- | ---: | ---: | --- | --- |
| `runtime.snapshot` | Inspect runtime overview | Yes | Partial | `runtime_snapshot` | Query | No | No | Both | `RuntimeSnapshotToolTests` |
| `runtime.search` | Search/filter runtime | Yes | No | `runtime_search` | Query | No | No | Both | `RuntimeSearchToolTests` |
| `runtime.inspect` | Inspect listener/process/runtime/service/port | Yes | No | `runtime_inspect` | Query | No | No | Both | `RuntimeInspectToolTests` |
| `runtime.explain` | Explain ownership and safest action | Yes | No | `runtime_explain` | Query | No | No | Both | `RuntimeExplainToolTests` |
| `runtime.metadata.update` | Label/associate/watch/ignore runtime | Partial | No | `runtime_update_metadata` | Config | Conditional | No | Both | `RuntimeMetadataToolTests` |
| `runtime.stop` | Stop exact owned runtime | Yes | No | `operation_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `OperationRuntimeTests` |
| `runtime.forceStop` | Force-stop exact owned runtime | Yes | No | `operation_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `OperationRuntimeTests` |
| `runtime.restart` | Restart through verified owner | Yes | Yes | `operation_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `OperationRuntimeTests` |
| `runtime.monitoring` | Pause/resume/refresh monitoring | Yes | Yes | `settings_update` / `runtime_snapshot` | Config | No | No | Both | `SettingsToolTests` |
| `projects.list` | List/search projects | Yes | Yes | `projects_list` | Query | No | No | Both | `ProjectToolTests` |
| `project.inspect` | Inspect project/topology/drift | Yes | Yes | `project_inspect` | Query | No | No | Both | `ProjectToolTests` |
| `project.create` | Create project | Yes | No | `project_create` | Config | No | No | Both | `ProjectToolTests` |
| `project.update` | Patch/reorder/tag project | Partial | No | `project_update` | Config | Conditional | No | Both | `ProjectToolTests` |
| `project.duplicate` | Duplicate project/options | No | No | `project_duplicate` | Config | No | No | Both | `ProjectToolTests` |
| `project.discover` | Discover candidates from selected root | Yes | No | `project_discover` | Query | No | No | Both | `ProjectDiscoveryToolTests` |
| `project.discovery.apply` | Apply selected recent candidates | Yes | No | `project_apply_discovery` | Config | No | No | Both | `ProjectDiscoveryToolTests` |
| `project.import` | Validate/import manifest | Yes | No | `project_import` | Config | Conditional | Conditional | Both | `ProjectImportExportToolTests` |
| `project.export` | Export safe manifest | Yes | No | `project_export` | Query | No | No | Both | `ProjectImportExportToolTests` |
| `project.archive` | Archive/unarchive project | No | No | `project_archive` | Config | No | No | Both | `ProjectToolTests` |
| `project.delete` | Delete project | Yes | No | `project_delete` or operation tools | Config | Conditional | Yes | Both | `ProjectToolTests` |
| `project.validate` | Validate configuration/topology | Partial | No | `project_validate` | Query | No | No | Both | `ProjectValidationToolTests` |
| `project.start` | Start project dependency graph | Yes | Yes | `service_start` or change/operation tools | Runtime | Conditional | No | Both | `ProjectLifecycleToolTests` |
| `project.stop` | Stop project dependency graph | Yes | Yes | `operation_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `ProjectLifecycleToolTests` |
| `project.restart` | Restart project | Yes | Yes | `operation_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `ProjectLifecycleToolTests` |
| `services.list` | List/search managed services | Yes | Yes | `services_list` | Query | No | No | Both | `ServiceToolTests` |
| `service.inspect` | Inspect safe service definition/state | Yes | Yes | `service_inspect` | Query | No | No | Both | `ServiceToolTests` |
| `service.create` | Create draft service | Yes | No | `service_create` | Config | No | No | Both | `ServiceToolTests` |
| `service.update` | Patch service configuration | Yes | No | `service_update` | Config | Conditional | No | Both | `ServiceToolTests` |
| `service.duplicate` | Duplicate without secret values | Yes | No | `service_duplicate` | Config | No | No | Both | `ServiceToolTests` |
| `service.adopt` | Build reviewed candidate from observation | Yes | No | `service_adopt_runtime` | Config | No | No | Both | `ServiceAdoptionToolTests` |
| `service.verify` | Isolated validation launch/stop | Yes | No | `service_verify` | Runtime | No | No | Both | `ServiceVerificationToolTests` |
| `service.enable` | Enable/disable service | Partial | No | `service_enable` | Config | No | No | Both | `ServiceToolTests` |
| `service.archive` | Archive/unarchive service | No | No | `service_archive` | Config | No | No | Both | `ServiceToolTests` |
| `service.delete` | Delete service and references | Yes | No | `service_delete` or operation tools | Config | Conditional | Yes | Both | `ServiceToolTests` |
| `service.start` | Start verified service | Yes | Yes | `service_start` | Runtime | No | No | Both | `ServiceLifecycleToolTests` |
| `service.stop` | Stop managed service | Yes | Yes | `operation_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `ServiceLifecycleToolTests` |
| `service.restart` | Restart managed service | Yes | Yes | `operation_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `ServiceLifecycleToolTests` |
| `service.recover` | Execute configured recovery | Partial | No | `service_recover` | Runtime | No | No | Both | `ServiceLifecycleToolTests` |
| `dependencies.get` | Inspect dependency graph | Yes | No | `dependency_graph_get` | Query | No | No | Both | `DependencyToolTests` |
| `dependencies.update` | Patch dependency semantics | Yes | No | `dependency_update` | Config | No | No | Both | `DependencyToolTests` |
| `dependencies.validate` | Validate cycles/order/readiness | Yes | No | `dependency_validate` | Query | No | No | Both | `DependencyToolTests` |
| `sessions.list` | List/search sessions | Yes | Yes | `sessions_list` | Query | No | No | Both | `SessionToolTests` |
| `session.inspect` | Inspect session/drift/history | Yes | Yes | `session_inspect` | Query | No | No | Both | `SessionToolTests` |
| `session.create` | Create explicit session | Partial | No | `session_create` | Config | No | No | Both | `SessionToolTests` |
| `session.capture` | Capture managed workspace | Yes | Yes | `session_capture` | Config | No | No | Both | `SessionToolTests` |
| `session.update` | Patch session metadata/expectations | Partial | No | `session_update` | Config | No | No | Both | `SessionToolTests` |
| `session.updateRuntime` | Update selected expectations | No | No | `session_update_from_runtime` | Config | Yes | No | Both | `SessionToolTests` |
| `session.duplicate` | Duplicate session | No | No | `session_duplicate` | Config | No | No | Both | `SessionToolTests` |
| `session.diff` | Compare session to live state | Yes | No | `session_diff` | Query | No | No | Both | `SessionToolTests` |
| `session.export` | Export safe session manifest | No | No | `session_export` | Query | No | No | Both | `SessionImportExportToolTests` |
| `session.import` | Validate/import session manifest | No | No | `session_import` | Config | Yes | Conditional | Both | `SessionImportExportToolTests` |
| `session.archive` | Archive/unarchive session | No | No | `session_archive` | Config | No | No | Both | `SessionToolTests` |
| `session.delete` | Delete session/history links | Yes | No | `session_delete` or operation tools | Config | Conditional | Yes | Both | `SessionToolTests` |
| `session.restore` | Preview/restore session | Yes | No | `session_restore_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `SessionRestoreToolTests` |
| `ports.list` | List active/expected/organized ports | Yes | No | `ports_list` | Query | No | No | Both | `PortToolTests` |
| `port.inspect` | Inspect ownership/conflict/actions | Yes | No | `port_inspect` | Query | No | No | Both | `PortToolTests` |
| `port.watch` | Create/update/delete watch | Partial | No | `port_watch_create/update/delete` | Config | No | No | Both | `PortToolTests` |
| `port.reservation` | Create/update/delete reservation | No | No | `port_reservation_create/update/delete` | Config | No | No | Both | `PortToolTests` |
| `port.alias` | Create/update/delete supported alias | No | No | `port_alias_create/update/delete` | Config | Conditional | Conditional | Both | `PortToolTests` |
| `port.ignore` | Create/delete ignore rule | Partial | No | `port_ignore_rule_create/delete` | Config | No | No | Both | `PortToolTests` |
| `port.release` | Safely release occupied port | Yes | No | `operation_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `PortOperationTests` |
| `docker.status` | Inspect Docker integration | Yes | No | `docker_status` | Query | No | No | Both | `DockerToolTests` |
| `docker.containers` | List/inspect containers | Yes | No | `docker_containers_list`, `docker_container_inspect` | Query | No | No | Both | `DockerToolTests` |
| `docker.compose` | List/inspect Compose topology | Yes | No | `docker_compose_projects_list`, `docker_compose_project_inspect` | Query | No | No | Both | `DockerToolTests` |
| `docker.association` | Associate/import verified context | Partial | No | `docker_association_update`, `docker_import_compose_project` | Config | No | No | Both | `DockerToolTests` |
| `docker.lifecycle` | Stop/restart/remove scoped Docker entity | Yes | No | `operation_preview` + `operation_execute` | Runtime | Yes | Yes | Both | `DockerOperationTests` |
| `logs.read` | Read/search bounded redacted logs | Yes | No | `service_logs` | Query | No | No | Both | `LogToolTests` |
| `logs.export` | Export bounded redacted logs | Yes | No | `logs_export` | Config | No | No | Both | `LogToolTests` |
| `logs.clear` | Clear managed logs | Yes | No | `operation_preview` + `operation_execute` | Config | Yes | Yes | Both | `LogToolTests` |
| `history.query` | Query/search lifecycle history | Yes | Yes | `history_query` | Query | No | No | Both | `HistoryToolTests` |
| `history.inspect` | Inspect event and evidence | Yes | No | `history_event_inspect` | Query | No | No | Both | `HistoryToolTests` |
| `history.export` | Export selected history | Partial | No | `history_export` | Query | No | No | Both | `HistoryToolTests` |
| `history.clear` | Clear selected history | Yes | No | `operation_preview` + `operation_execute` | Config | Yes | Yes | Both | `HistoryToolTests` |
| `diagnostics.analyze` | Deterministic incident diagnosis | Yes | No | `diagnostics_analyze` | Query | No | No | Both | `DiagnosticsToolTests` |
| `settings.get` | Read safe settings | Yes | No | `settings_get` | Query | No | No | Both | `SettingsToolTests` |
| `settings.update` | Patch safe settings | Yes | No | `settings_update` | Config | Conditional | No | Both | `SettingsToolTests` |
| `favorites.update` | Update favorites | Yes | Yes | `favorites_update` | Config | No | No | Both | `OrganizationToolTests` |
| `tags.manage` | Create/rename/merge/delete tags | Partial | No | `tags_manage` | Config | Conditional | Conditional | Both | `OrganizationToolTests` |
| `filters.manage` | Create/update/delete saved filters | Yes | No | `saved_filter_create/update/delete` | Config | No | No | Both | `OrganizationToolTests` |
| `operations.preview` | Preview high-impact operation | Yes | No | `operation_preview` | Query | No | No | Both | `OperationCoordinatorTests` |
| `operations.execute` | Execute exact approved preview | Yes | No | `operation_execute` | Runtime | Token | Yes | Both | `OperationCoordinatorTests` |
| `changes.preview` | Plan coordinated domain changes | No | No | `change_set_preview` | Query | No | No | Both | `ChangeSetTests` |
| `changes.execute` | Execute exact coordinated plan | No | No | `change_set_execute` | Config | Token | Conditional | Both | `ChangeSetTests` |
| `secrets.references` | Assign/remove/check secret references | Yes | No | service create/update/inspect | Config | No | No | Both | `SecretBoundaryToolTests` |
| `dev.buildInfo` | Inspect development build | No | No | `dev_build_info` | Query | No | No | Debug | `DevelopmentToolTests` |
| `dev.internalState` | Inspect bounded internal state/errors | No | No | `dev_internal_state`, `dev_recent_errors` | Query | No | No | Debug | `DevelopmentToolTests` |
| `dev.fixtures` | List/start/stop owned fixtures | No | No | `dev_fixture_list/start/stop` | Runtime | No | No | Debug | `DevelopmentFixtureTests` |
| `dev.acceptance` | Run bounded scenario/suite | No | No | `dev_acceptance_scenario_run`, `dev_acceptance_suite_run` | Runtime | No | No | Debug | `DevelopmentAcceptanceTests` |
| `dev.migration` | Validate historical fixtures | No | No | `dev_migration_validate` | Query | No | No | Debug | `DevelopmentToolTests` |
| `dev.performance` | Measure bounded control-plane paths | No | No | `dev_performance_measure` | Query | No | No | Debug | `DevelopmentToolTests` |
| `dev.reset` | Reset disposable development store | No | No | `dev_test_store_reset` | Config | Yes | Yes | Debug | `DevelopmentSecurityTests` |
| `dev.parity` | Validate registry parity | No | No | `dev_capability_parity_validate` | Query | No | No | Debug | `CapabilityParityTests` |

## Explicit exclusions

| Capability | Reason |
| --- | --- |
| Arbitrary shell, Docker, Homebrew, launchctl, SQL, file write, or code execution | It bypasses DevBerth domain validation and expands control into a general machine executor. |
| Raw PID termination | PID existence is not identity or ownership authority; all actions use stable runtime/listener IDs and revalidated fingerprints. |
| Secret value input/output over normal MCP tools | Keychain entry stays in DevBerth's secure GUI; MCP handles opaque references and resolution state only. |
| Finder/Terminal/browser opening | Presentation-only action outside durable application state; it may unexpectedly activate another app. |
| Quit/open main window | UI lifecycle is not a domain capability and quitting would tear down the authoritative host. Secure secret entry may explicitly request UI activation. |
| Production data reset | Development reset is compiled and routed only for an explicitly disposable development store. |
| Streamable HTTP production transport | Codex supports it, but a same-user local app needs no network listener; STDIO plus current-user Unix IPC is narrower. |

Automated parity is complete only when `CapabilityParityTests` passes in Debug and Release, Release discovers no development tools, and all mapped end-to-end workflows pass.

