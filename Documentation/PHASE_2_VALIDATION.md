# Phase 2 validation

Validation date: 2026-07-21 (Asia/Seoul)  
Toolchain: Xcode 26.4 (17E192), LLDB 2100.0.16.4, Swift 6.3 in Swift 5 language mode  
Host: Apple Silicon MacBook Pro, macOS 26.4

This record distinguishes implementation evidence from release evidence. A deterministic fixture can prove a safety contract; it does not become a claim that every third-party tool or long-running host has been exercised manually.

## Automated evidence

| Scope | Result | Evidence |
| --- | --- | --- |
| Complete unit + integration + UI scheme | 149 passed, 0 failed, 0 skipped | `/tmp/devberth-all-final-20260721-1415.xcresult` |
| Detached clean-checkout scheme | 149 passed, 0 failed, 0 skipped | Commit `4160f3f`; `/tmp/devberth-clean-validation-20260721.xcresult` |
| Isolated native UI confirmation | 4 passed, 0 failed, 0 skipped | `/tmp/devberth-ui-final-20260721-1412.xcresult` |
| Repeated soak selection | Four iterations passed in 50.318 seconds | `Scripts/run_soak_tests.sh`; performance, batching, security/logging, Docker transitions, all owned integration fixtures |
| Static analysis | Passed | Xcode `analyze`, arm64 Debug target |
| Source secret-pattern scan | No matching credential/private-key patterns | Repository-wide `rg`, excluding Git metadata and result bundles |
| Generated-project consistency | Passed | `xcodegen generate`; committed project regenerated from `project.yml` |

The 149-test result includes all four UI cases plus schema and product-identity migrations, corrupted-store handling, process discovery/parsing, strong identity mismatches, listener-edge and escalation revalidation, protected targets, managed groups/descendants/replacements/supervisors, ownership/confidence/routing, exact restart trust and isolated validation, secret transaction behavior, lifecycle/health/incidents/restarts, project discovery/import, sessions/rollback, Docker/Compose scope, retention, batching, log redaction/rotation, and repository-owned process fixtures.

The UI-test process launches with `DEVBERTH_UI_TESTING=1`. It skips product migration, uses in-memory SwiftData, and injects one static loopback listener/resource reading. It never enumerates or controls host processes or containers. Tests cover first-run disclosures, sidebar order and named destination actions, Runtime ownership and restart-trust evidence, filtering/empty state, and keyboard command-palette routing. Xcode emits a non-fatal `no debugger version` diagnostic before UI-host launch on this machine; the signed runner then executes normally and the result bundle reports four passes.

## Runtime and visual evidence

- Computer Use inspected the final native accessibility tree and `Documentation/Screenshots/runtime-phase-2.jpeg`. It confirmed the exact sidebar hierarchy, labeled toolbar controls, four top metrics, protocol filtering, table headers, a static listener row with ownership/trust/health/runtime/uptime/resource evidence, and the persistent inspector. The inspection caught a vertically centered Runtime workspace; the layout was corrected and re-inspected top-aligned with a full-height table.
- A live read-only Docker Engine measurement listed six existing containers in 0.04 seconds and inspected them in one 0.03-second batch. DevBerth did not stop, restart, remove, or otherwise mutate those containers.
- Repository-owned Python integration fixtures covered random high-port listeners, multiple listeners, child/group shutdown, supervisor respawn, executable replacement, ignored TERM, force escalation, detached descendants, and cleanup. No unrelated process received a signal.
- At the end of validation, no DevBerth app, Xcode build, HTTP fixture, or process-tree fixture remained running.

## Acceptance scenarios

| Scenario | Verified evidence | Boundary not overstated |
| --- | --- | --- |
| A — unknown Vite process | External host-process ownership, project/runtime classification, inferred restart status, guarded TERM, and lifecycle evidence have unit/integration/UI coverage. | The final pass used a deterministic external-process fixture, not a developer’s live Vite checkout. |
| B — convert discovered process | Review-only conversion, working-directory/shell/secret/port/check editing, isolated validation, exact digest, and verified relaunch are covered. Gradle and Maven discovery have fixtures. | No real Spring Boot application was downloaded or trusted merely to satisfy the scenario. |
| C — PID reuse safety | Stale PID, start/UID/executable/digest/listener changes, and force-escalation mismatch all refuse before signaling. | PID reuse is simulated deterministically; relying on probabilistic OS PID recycling would be weaker evidence. |
| D — supervisor respawn | Owned supervisor fixture restarts a child; lineage evidence and owner-aware refusal/action rationale are tested. | DevBerth does not guess a supervisor control command. |
| E — Docker Compose ownership | Exact project/service/files/directory/environment/hash/path/membership proof, scoped stop/restart/remove arguments, one-off refusal, invalidation, and no host-PID fallback are tested. | Live user containers were read only; destructive Compose proof used a deterministic CLI fixture. |
| F — workspace session | Capture, drift, preview, dry run, missing requirements, occupied ports, dependency layering, independent parallelism, restore, history, and scoped rollback are tested. | Only managed-service intent is restored; arbitrary terminals/external processes are intentionally excluded. |
| G — failed dependency | Failed readiness blocks dependents, emits structured lifecycle/incident evidence, preserves redacted logs, and supports retry through fresh preflight. | Reviewed checks cannot prove application correctness beyond their configured criteria. |
| H — long-running stability | Four-pass repeatable soak, 250-cycle bounded-store workload, 5,000-line disk-log rotation, integration churn, and 13/79-second live UI samples passed. | This is not a multi-day stability claim. An eight-hour production-monitor soak remains the signed-release gate. |

## Final gate disposition

Implemented safety and compatibility gates are green: detached clean-checkout build with all 149 current tests, clean-derived build, migration fixtures, owned integrations, static analysis, source credential scan, Keychain lifecycle tests, product-data migration tests, Docker-unavailable/context invalidation, permission/protected-process refusal, force confirmation/revalidation, session rollback, event retention, and log rotation.

The following are deliberately not claimed as completed release/distribution evidence:

- Developer ID signing, notarization, and an update channel are not implemented.
- The required eight-hour production-monitor soak has not yet been run; only the repeatable bounded soak and short live samples are recorded.
- Launch-at-login was not toggled on the developer’s account during automated validation because that would mutate a user-level login item. The `SMAppService` path remains a manual pre-release check.
- The final visual smoke used the current dark appearance. The UI relies on semantic system materials/colors, but light appearance, increased contrast, reduced motion, and VoiceOver should receive a dedicated human pre-release pass.
- The optional `.localhost` alias router remains intentionally deferred and unimplemented.

These limitations do not weaken destructive-action verification. They prevent a signed production-release claim until their specific release gates are completed.
