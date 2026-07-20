# PortPilot implementation plan

## Delivery sequence

1. Establish the native macOS application, domain boundaries, dependency container, design tokens, and CI-capable Xcode project.
2. Implement machine-readable `lsof` parsing, `ps` enrichment, project inference, classification, runtime diffing, and safe polling.
3. Add guarded process control with identity revalidation and auditable graceful/force-stop state machines.
4. Add SwiftData records and stores for projects, launch profiles, dependencies, expected ports, observations, history, favorites, preferences, and log metadata. Keep secrets behind Keychain references.
5. Implement reliable launching, dependency graph orchestration, preflight port conflicts, health checks, bounded/redacted logs, and Docker CLI integration.
6. Deliver dense active-port and management interfaces, menu-bar controls, command palette, accessibility, localization readiness, fixtures, and icon assets.
7. Exercise parsers, orchestration, safety, persistence, Docker fallbacks, health checks, and harmless high-port integrations. Measure monitoring overhead and perform a clean-build/secrets audit.
8. Commit in coherent milestones, push to the private repository, and verify that the GitHub Actions workflow matches local validation.

## Product truthfulness

PortPilot distinguishes verified operating-system metadata from heuristics. A discovered command is never executed automatically. Reliable restarts require a reviewed launch profile because an arbitrary process's original environment and shell state cannot be reconstructed safely.

## Toolchain

- Xcode 26.4 at `/Applications/Xcode.app`
- Swift 6.2.4 toolchain, compiling the project in Swift 5.10 language mode
- Deployment target macOS 14.0
- XcodeGen 2.46.0 generates the committed Xcode project from `project.yml`

