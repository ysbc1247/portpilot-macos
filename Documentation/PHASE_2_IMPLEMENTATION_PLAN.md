# Phase 2 implementation plan

This plan follows the evidence in `PHASE_2_AUDIT.md`. Each slice must preserve the macOS 14 baseline, add tests for its risk boundary, update durable documentation, and land as a meaningful commit. The optional alias router remains deferred until the core acceptance gates pass.

## Delivery slices

Current status on 2026-07-21: slices 1–8 and the Docker/Compose control half of slice 9 are implemented and locally validated. The broader product redesign and final hardening in slices 9–10 remain active work; the optional alias router remains deferred.

1. **Audit and plan**
   - Freeze the baseline, gaps, measurements, removals, and acceptance evidence.
   - Deliver `PHASE_2_AUDIT.md` and this plan before major code changes.

2. **Product identity and migration foundation**
   - Research GitHub, web, package registries, macOS apps, developer tools, domain variations, and obvious marks.
   - Document candidates and choose a distinct, pronounceable final name.
   - Add a migration coordinator and old-identity constants before renaming target/product/bundle/store/log/Keychain/defaults identifiers.
   - Prove a V1 store, preferences, logs, and Keychain references remain available after rename.

3. **Deliberate domain model and V2 persistence**
   - Add separate observed listener, observed process, managed service, runtime instance, project, workspace session, ownership evidence, restart trust, discovery evidence, and lifecycle event contracts.
   - Keep transient runtime snapshots out of SwiftData configuration models.
   - Add V1 fixtures, explicit V1→V2 migration stages, corrupt-store handling, and retention policy.

4. **Process identity and process-tree safety**
   - Add PID, numeric UID, start time, executable path/file identity, command digest, parent PID, process-group ID, and detection timestamp.
   - Re-query identity and selected listener/runtime ownership before signals and again before escalation.
   - Launch managed processes in controlled groups; track descendants and the actual expected-port owner.
   - Cover exits, reuse, executable/UID/command/listener changes, supervisors, shared listeners, multiple processes, replacement, detachment, and ignored SIGTERM.

5. **Ownership graph and lifecycle controllers**
   - Produce value/confidence/evidence/method/time conclusions for the requested owner categories.
   - Reconcile managed runtime instances with observed processes and listeners.
   - Route actions through managed-process, Docker, Compose, Homebrew, Kubernetes-forward, SSH-tunnel, launchd, and guarded unknown-process controllers as supported.
   - Add “Why is this running?” and safe-action rationale to the inspector.

6. **Restart trust and managed-service verification**
   - Implement verified, conditional, inferred-candidate, and not-restartable states with explanations.
   - Build the guided observed-process conversion flow.
   - Require a successful isolated validation run before `verified restartable`.
   - Detect secret-like environment fields, keep values in Keychain, sanitize history/diagnostics, and fix secret lifecycle/duplication.

7. **Runtime lifecycle, health, and diagnostics**
   - Track runtime identifiers, fingerprints, listeners, health, exit results, logs, parent relationships, and lifecycle events.
   - Separate running/listening/ready/healthy and implement configurable TCP, HTTP status/text, command, file, Docker, and dependency checks.
   - Add deterministic incident summaries, structured safe metadata, related events, bounded retention, batching, and pruning.
   - Implement tested restart policies against runtime instances rather than UI flags.

8. **Projects, discovery adapters, and sessions**
   - Implement non-recursive discovery adapters for requested ecosystems and review-only import/export.
   - Add project topology and dependency diagnostics.
   - Implement session capture, comparison, dry-run preview, conflicts, dependency-order restore, independent parallelism, readiness waits, rollback, and restore history.

9. **Docker/Compose context and native product redesign**
   - **Implemented:** retain health/restart policy, full Compose project/service/files/directory/environment context, and route exact revalidated stop/restart/remove actions without unrelated-service or host-PID fallback.
   - Redesign navigation to Runtime, Projects, Sessions, Managed Services, History, Docker, and Settings.
   - Add grouped/saved runtime views, ownership/trust/health columns, complete inspector sections, onboarding, compact menu metrics, and the expanded command palette.
   - Keep every status understandable without color and every user-facing string localization-ready.

10. **Performance, security, and final quality gate**
    - Replace per-event saves/full-log rewrites and cancellation leaks with bounded, batchable work.
    - Add repeatable timing/signpost instrumentation and a soak harness covering fixtures, log rotation, lifecycle writes, inspectors, and Docker transitions.
    - Complete threat model and all documentation deliverables.
    - Run clean-checkout build, every unit/integration/UI/migration target, static analysis, secrets scan, appearance/menu/login/offline/Docker/permissions/safety/session/retention/log checks, and the acceptance scenarios.
    - Push the dedicated branch without changing repository visibility.

## Commit strategy

The intended history is one or more coherent commits for each delivery slice. A slice is not ready to commit when its implementation, tests, repository instructions, and durable documentation disagree. Large slices may be split by vertical behavior (for example ownership evidence before controllers), but unrelated work must not be bundled into one final commit.

## Verification contract

For every requirement, the final completion matrix will link to one of:

- a concrete source or migration artifact;
- a focused automated test and its result;
- a harmless fixture/acceptance run and captured output;
- a rendered UI screenshot plus accessibility inspection;
- an actual performance/soak measurement;
- repository/CI/privacy evidence.

Absence of a failure is not proof. Features remain incomplete when evidence is missing, indirect, or narrower than the requirement.
