# DevBerth engineering rules

- Target macOS 14 or newer with SwiftUI and Swift Concurrency. Use AppKit only when a native SwiftUI API cannot provide the required behavior.
- Keep transient runtime models in `DevBerth/Domain` and SwiftData records in `DevBerth/Persistence`; never persist live `Process` objects.
- Keep `ObservedListener` and `ObservedProcess` as operating-system evidence, and `ManagedServiceConfiguration` as durable user-authored intent. Do not make an observation manageable or restartable by adding configuration flags to it.
- UI code must depend on service protocols. It must not invoke `Process`, `lsof`, `ps`, `kill`, Docker, or a shell directly.
- Invoke trusted tools with an executable URL and discrete argument array through `CommandRunning`. Only explicitly user-authored launch profiles may use a login shell.
- A destructive process action must revalidate the captured `ProcessFingerprint` (PID, UID, executable path and file identity when available, start time, command digest, and parent PID) and the exact listener-to-process edge immediately before every signal. Revalidate again before force escalation; never treat PID existence alone as authority or weaken protected-process checks to make an action succeed.
- Store secret values only through `SecretStoring` (Keychain in production). SwiftData may contain opaque secret references, never secret values.
- Ownership evidence, lifecycle details, discovery metadata, and workspace-session snapshots may store identifiers and redacted explanations, never secret values or raw environment values.
- Keep verified process metadata separate from inferred classification or relaunch suggestions in the UI and domain models.
- Add parser fixtures and tests when changing command formats. Tests must use mocks and must never terminate real user processes.
- Localize user-facing strings with `String(localized:)` or `LocalizedStringKey`; keep business-logic errors actionable and non-secret.
- Treat `ProductIdentity` and `ProductDataMigrator` as the compatibility boundary for the PortPilot-to-DevBerth rename. Never remove legacy identifiers or reset user storage without a tested migration and an explicit compatibility decision.
- Treat `DevBerthSchemaV1` and `DevBerthSchemaV2` as shipped, immutable schemas. Add a new version and migration stage for later persistence changes, and validate from a previous-version fixture.
- Regenerate `DevBerth.xcodeproj` with `xcodegen generate` after changing `project.yml`.
- Validate locally with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DevBerth.xcodeproj -scheme DevBerth -destination 'platform=macOS' test`.
- Architectural boundary or contract changes require matching updates to this file and `Documentation/ARCHITECTURE.md` (or the relevant `docs/implementations/*/README.md`).
