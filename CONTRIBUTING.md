# Contributing

1. Read `AGENTS.md`, `Documentation/ARCHITECTURE.md`, `SECURITY.md`, and `PRIVACY.md`.
2. Create a focused branch from `main`.
3. Preserve the separation between runtime domain values, SwiftData records, injected service protocols, and SwiftUI presentation.
4. Add fixtures and parser tests for every command-format change. Tests must never signal an unrelated process.
5. Run `xcodegen generate` after changing `project.yml` or source structure and commit the generated `DevBerth.xcodeproj` changes.
6. Run the full build and test commands from `README.md`.
7. Audit the diff for credentials, private process output, local databases, logs, and Xcode user state.

Warnings are treated as errors. User-facing errors must be actionable, and inferred process values must remain visibly distinct from verified metadata.

