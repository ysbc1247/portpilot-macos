# Privacy

DevBerth is local-only. It has no account, analytics, telemetry, advertising SDK, crash-upload service, or runtime-data upload endpoint.

## Data processed on this Mac

DevBerth observes local listener addresses/ports and same-user-accessible process metadata, including PID, owner, executable, command, working directory, start time, lineage, and transient CPU/resident memory. Docker is queried only when available. macOS permissions and ownership may make fields unavailable; DevBerth displays that limitation instead of seeking elevation.

SwiftData retains projects, managed-service definitions, opaque Keychain references, restart-validation evidence, workspace sessions, bounded lifecycle/history evidence, and non-secret settings. Secret values live in macOS Keychain. Managed-service stdout/stderr is redacted and bounded locally. Resource usage and current listener/process objects are transient and are not persisted.

## User-directed exports

Diagnostics exports omit commands, environment values, Keychain data, and logs. Project manifests omit secret values and Keychain reference identifiers. Log export includes only the selected managed service’s already-redacted local log buffer. No export is automatic.

## Retention and deletion

History retention is configurable. Lifecycle, ownership, incident, and log stores have explicit bounds. Deleting a managed service removes unused Keychain references only after persistence succeeds and only when no remaining service references them. Legacy PortPilot data remains as a recovery source after one-way copy migration; DevBerth does not delete it automatically.

## Network behavior

DevBerth may perform user-configured HTTP health checks against reviewed URLs and communicates with a local Docker daemon through the Docker CLI when the user opens or uses Docker functionality. It does not send observed runtime or project data to DevBerth-operated servers because no such service exists.

## MCP access

The optional `devberth-mcp` helper exchanges bounded JSON with the DevBerth app over a same-user Unix-domain socket and speaks MCP over the launching client's standard input/output. It does not open a network listener, scan runtime state, access SwiftData directly, or read Keychain values. MCP responses may contain the same non-secret runtime, project, service, session, Docker, history, log, and settings data visible in the app. Every MCP action is local and recorded with bounded, secret-safe audit metadata.

Codex configuration is changed only after a user previews and applies it in Settings. The editor preserves unrelated TOML, writes atomically, and keeps a local backup. No configuration or runtime data is uploaded by DevBerth.
