# Project discovery and manifest contract

Decision date: 2026-07-21 (Asia/Seoul)

## Scope and trust boundary

Project discovery begins only from a folder the user already attached to a DevBerth project. `ProjectDiscoveryCoordinator` invokes independent adapters against direct children of that folder; it never walks the full disk or recursively enters nested projects. A source file must be a non-symlink regular file no larger than 1 MiB before an adapter may read it. Discovery never launches a command, asks Docker or a package manager to evaluate configuration, or writes into the project.

Every adapter returns a `ProjectDiscoveryFinding` with its adapter identifier, project type, confidence, evidence, and zero or more `DiscoveredServiceCandidate` values. Candidates preserve command and argument boundaries where the source format provides them. Procfile and Process Compose expressions remain explicit custom-shell candidates and carry a shell-review warning because their formats encode shell text. All candidates become `ManagedServiceConfiguration` values with `isReviewed == false`; `ManagedProcessLauncher` therefore refuses them until the user reviews and validates the exact definition.

## Supported adapters

| Adapter | Direct markers | Candidate behavior |
| --- | --- | --- |
| JavaScript | `package.json` plus package-manager/config markers | npm, pnpm, Yarn, or Bun script invocation; script text is evidence only and may provide a tentative explicit port |
| Gradle | Gradle build/settings files | Wrapper when executable, otherwise `gradle`; explicit tasks plus evidence-backed `run`/`bootRun` |
| Maven | `pom.xml` | Wrapper when executable, otherwise `mvn`; plugin-backed Spring Boot, Quarkus, or exec goals |
| Python | `pyproject.toml`, `requirements.txt`, `manage.py` | Django, Flask, evidence-backed FastAPI/Uvicorn, and declared project scripts |
| Go | `go.mod` | Review-only `go run .` candidate |
| Cargo | `Cargo.toml` | Review-only `cargo run` candidate |
| Docker Compose | one selected standard Compose filename | Exact absolute configuration file, service name, host ports, and parsed `depends_on` names; no compatibility claim for arbitrary YAML features |
| Procfile | `Procfile` | One custom-shell candidate per process line |
| Process Compose | `process-compose.yaml` or `.yml` | Parsed command, dependency names, and explicit ports as custom-shell candidates |
| DevBerth manifest | `devberth-runtime.json` | Product-native service definitions with relative paths, discrete arguments, ports, dependencies, and secret names |
| Workspace markers | `.git`, pnpm/Turbo/Nx/Vite/Next markers, `.devcontainer`, Makefile, Taskfile | Project-type evidence only; no command is guessed from an arbitrary task file |

The conservative YAML reader supports the mapping/list subset needed to extract service names, `depends_on`, published ports, and Process Compose commands. It does not claim full Docker Compose or Process Compose round-trip compatibility. Exact Compose lifecycle control remains a separate controller-context contract.

## Review and import

The Projects screen exposes discovery only when the project has a folder. Its review sheet shows each source, confidence, command, ports, dependencies, and shell risk before selection. `ProjectDiscoveryImporter` stores selected definitions as unreviewed profiles, expected ports, controlled-process policies, resolvable dependencies, and V2 discovery metadata. It records unresolved dependency names instead of silently connecting an ambiguous name.

No ecosystem adapter stores environment values from source files. Secret names from the native manifest become fresh local references with no value; the user must populate them through the normal Keychain-backed editor. Discovery metadata may store paths and redacted explanations, never raw command bodies, environment values, or secret values.

## Native manifest

`devberth-runtime.json` is a versioned, sorted JSON interchange format. Export preserves project-local relative working directories, launch mechanism, discrete arguments, shell selection, reviewed non-secret environment values, expected ports, named dependencies, timeout/restart policy, and secret variable names. Opaque Keychain reference UUIDs and secret values are never exported. Export refuses a plaintext environment key that matches the sensitive-name policy.

Import does not imply trust even when the manifest was previously exported by DevBerth. Schema version 1 is accepted; unknown versions are refused with an actionable error. Because Docker Compose, Process Compose, and Procfile cannot represent the full DevBerth service model, their adapters are import-only evidence sources rather than full round-trip serializers.

## Validation evidence

Focused tests cover all four JavaScript package managers, Gradle, Maven, Python, Go, Cargo, Compose ports/dependencies, Procfile and Process Compose shell review, non-recursion, native manifest safety/round-trip behavior, and SwiftData import of unreviewed profiles plus discovery metadata.
