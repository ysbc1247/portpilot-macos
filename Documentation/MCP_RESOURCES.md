# MCP resources

Resources are read-only views over the same app-owned control plane as tools. They never establish independent authority, and clients that do not support resources can call the corresponding query tool.

| URI | Kind | Backing query | Content |
| --- | --- | --- | --- |
| `app://runtime/snapshot` | Resource | `runtime_snapshot` | Current bounded runtime overview |
| `app://projects` | Resource | `projects_list` | Projects |
| `app://projects/{projectID}` | Template | `project_inspect` | One project, definitions, topology, revision |
| `app://services/{serviceID}` | Template | `service_inspect` | One safe service definition and runtime/trust state |
| `app://sessions/{sessionID}` | Template | `session_inspect` | One session, expectations, drift, restore history |
| `app://history/recent` | Resource | `history_query limit=50` | Recent lifecycle evidence |
| `app://schemas/project` | Resource | Registry | Project tool definitions and schemas |
| `app://schemas/service` | Resource | Registry | Service tool definitions and schemas |
| `app://schemas/session` | Resource | Registry | Session tool definitions and schemas |
| `app://capabilities` | Resource | Registry | Complete capability registry for the active build mode |
| `app://diagnostics/status` | Resource | `settings_get` | Safe host/MCP status |

All resources use `application/json`. Template IDs must be stable UUIDs returned by DevBerth. Unknown URIs and unknown IDs return a structured invalid-parameter or `entity_not_found` error. Capability output differs by build mode: Release never lists `dev_*`.
