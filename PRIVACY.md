# Privacy

DevBerth operates locally on the Mac.

It reads local port, process, executable, command, working-directory, owner, start-time, Docker, and project-marker metadata to provide its core interface. It stores user-created projects, managed-service definitions, expected ports, preferences, favorites, bounded redacted service logs, and event history in local Application Support data. Secret launch values are stored in Keychain.

CPU percentage and resident-memory readings are transient Runtime evidence. They are refreshed in a bounded batch and are not persisted to history, diagnostics, or managed-service configuration.

DevBerth does not upload process, command, project, port, Docker, log, history, preference, or diagnostic information. It includes no analytics, advertising, telemetry, tracking, crash-reporting service, or cloud account.

The only application-initiated network requests beyond local discovery are optional health-check URLs explicitly configured in managed services. Docker actions follow the Docker context already configured by the user.

When enabled, `devberth-mcp` communicates locally with the DevBerth app over a same-user Unix-domain socket and with its launching MCP client over STDIO. It opens no network listener, owns no second database or monitor, and cannot return Keychain secret values. MCP audit metadata is bounded and secret-safe.

Diagnostics export is user-initiated and excludes full commands, environment values, logs, and Keychain content. The resulting file stays where the user saves it.

Uninstalling DevBerth does not automatically delete user data. Local SwiftData and service-log files can be removed from the user’s Application Support directory, and secret entries can be removed from Keychain.

The detailed data inventory, bounds, migration behavior, and explicit non-collection commitments are in [Documentation/PRIVACY.md](Documentation/PRIVACY.md).
