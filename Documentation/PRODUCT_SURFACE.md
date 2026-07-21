# Native product surface

## Information architecture

DevBerth uses one stable three-level model: sidebar destination, primary workspace, and contextual inspector or preview. The destination order is Runtime, Projects, Sessions, Managed Services, History, Docker, and Settings. Runtime replaces the former Overview plus Active Ports split; there is one source of truth for metrics, filtering, selection, and inspection.

## Runtime

Runtime presents the current listener snapshot in a customizable macOS table or grouped by inferred project. The saved views are All Runtime, Managed, Unexpected, Unhealthy, Docker, and Externally Reachable. Search covers ports, protocol, address, process, command, and project. Sorting covers port, process, project, runtime, and uptime. Native table/list selection provides keyboard traversal and multiple selection; a multi-selection inspector summarizes listener/process counts and resources without offering ambiguous bulk destructive actions.

The table keeps high-frequency fields together: listener status/protocol, port, process/PID, project, ownership, restart trust, health, runtime, uptime, and CPU/resident memory. The inspector provides Summary, Network listeners, Process identity, Observed command, Why is this running?, Restart trust, Managed-service relationship, Health and recent lifecycle, Project, Docker association, Logs, and Safe actions. Unknown or permission-limited evidence is labeled unavailable instead of guessed.

## Projects and sessions

Projects show each managed service, expected ports, health/lifecycle status, Docker relationship, dependency edges, startup layers, cycle/incomplete warnings, and recent failures. Start and stop operate through the verified project orchestrator.

Sessions contain selected projects, expected running/stopped managed-service state, comparison drift, restore history, and a fresh restore preview. Palette restore always opens the preview; it never directly mutates runtime. Dry-run, issue confirmation, optional rollback, and expected-stopped handling retain their independent controls.

## Managed services

The user-facing term is Managed Service. `LaunchProfileRecord` remains only as a frozen persistence compatibility name. Start and restart require exact current validation; draft and conditional definitions route to review. Logs, directory, copy-command, stop, and verified start/restart actions are exposed consistently through the main table and command palette.

## Onboarding

The welcome guide requires no account. Before completion it explains that data stays local, macOS visibility may be limited to same-user-accessible metadata, discovery is not management, reliable restart requires an explicit validated definition, secrets live in Keychain, destructive operations revalidate exact ownership, and no runtime information is uploaded. It routes to Runtime, project import, managed-service creation, or session capture and can be shown again from Settings.

## Menu bar and command palette

The compact menu reports active managed, unexpected listener, and unhealthy counts; offers listener search, favorite managed-service control, recent project start/stop, session capture, monitoring, and main-window access.

Command-K opens a keyboard-navigable palette. It searches ports, PIDs, processes, commands, projects, managed services, and sessions. It opens every destination; refreshes/toggles monitoring; starts/stops projects; captures or previews session restore; opens/copies managed-service data; and starts, stops, or restarts services. Restart appears only when `RestartTrustEvaluator` reports `verifiedRestartable` for the exact current digest.

## Accessibility and localization

Controls use native labels and system symbols, critical state always includes text, table/group rows combine meaningful accessibility descriptions, and onboarding/empty states expose named actions. User-facing SwiftUI text uses literals accepted by `LocalizedStringKey`; business-logic strings remain non-secret and actionable. The UI test fixture is static, loopback-only, and in-memory.

