# Privacy

PortPilot operates locally on the Mac.

It reads local port, process, executable, command, working-directory, owner, start-time, Docker, and project-marker metadata to provide its core interface. It stores user-created projects, launch profiles, expected ports, preferences, favorites, bounded redacted service logs, and event history in local Application Support data. Secret launch values are stored in Keychain.

PortPilot does not upload process, command, project, port, Docker, log, history, preference, or diagnostic information. It includes no analytics, advertising, telemetry, tracking, crash-reporting service, or cloud account.

The only application-initiated network requests beyond local discovery are optional health-check URLs explicitly configured in launch profiles. Docker actions follow the Docker context already configured by the user.

Diagnostics export is user-initiated and excludes full commands, environment values, logs, and Keychain content. The resulting file stays where the user saves it.

Uninstalling PortPilot does not automatically delete user data. Local SwiftData and service-log files can be removed from the user’s Application Support directory, and secret entries can be removed from Keychain.

