# Performance CPU and responsiveness handoff

Captured: 2026-07-22 10:58:50 KST (Asia/Seoul, UTC+09:00)

## Git and review state

- Branch: `performance/cpu-and-responsiveness`
- Captured HEAD: `e95e145cef5510e654822f24731d474d2b0e9238` (`docs(performance): record final profiling and soak results`)
- Baseline/main commit: `8cc670eabeabe8559383d6f0f6a1918485102f45`
- Working tree at capture: clean; no staged, unstaged, or untracked files
- Remote tracking branch: `origin/performance/cpu-and-responsiveness`, synchronized at captured HEAD
- Final shard PR: [#24 Complete CPU and responsiveness optimization](https://github.com/ysbc1247/portpilot-macos/pull/24), targeting `test/performance-regressions`; CI was in progress at capture
- Stack: [#19 instrumentation](https://github.com/ysbc1247/portpilot-macos/pull/19) → [#20 adaptive monitoring](https://github.com/ysbc1247/portpilot-macos/pull/20) → [#21 background scheduling](https://github.com/ysbc1247/portpilot-macos/pull/21) → [#22 diagnostics UI](https://github.com/ysbc1247/portpilot-macos/pull/22) → [#23 regression/soak tests](https://github.com/ysbc1247/portpilot-macos/pull/23) → [#24 final profiling fixes/results](https://github.com/ysbc1247/portpilot-macos/pull/24)
- PRs #19–#23 had green CI at capture. No shard PR had been merged; the requested next operation is one release-ready roll-up PR and one merge to `main`.

## Project state

The performance task is implementation-complete and locally validated. The former fixed two-second loop republished every timestamp refresh, wrote false lifecycle events, pruned continuously, woke retained SwiftUI graphs, spawned monitoring tools at high cadence, and independently refreshed Docker/resources. The final design owns one adaptive/coalescing monitor, compares semantic evidence, publishes only meaningful foreground changes, persists only genuine transitions, uses bounded native full-identity caching, decouples slower background work, and exposes bounded secret-free diagnostics.

Matched Release measurements show closed-window CPU falling from 69.2% to 0.118% over 901 seconds, final idle Time Profiler CPU falling from 24.4 CPU-seconds to 0.027 CPU-seconds, main-thread sampled CPU falling from 19.558 to 0.001 CPU-seconds, and direct monitoring children falling about 97%. The exact full test action, repeated soak gate, five-minute isolated Release soak, and stable app/helper installation all passed.

## Completed work

### Runtime monitoring and state propagation

- `DevBerth/Services/Monitoring/PortMonitor.swift`: one idempotent task, cancellable delay, immediate-request coalescing, maximum one in-flight scan, transition/active/background/idle cadence, sleep/wake ownership, and cadence-relevant UDP classification.
- `DevBerth/Services/ProcessDiscovery/LocalPortDiscovery.swift`: semantic listener discovery and bounded enrichment without timestamp-only change propagation.
- `DevBerth/Services/ProcessDiscovery/ProcessCacheIdentity.swift`: native PID/UID/start/parent/executable-device-inode/argument-digest/current-directory identity with PID-reuse and exec invalidation.
- `DevBerth/Domain/ObservationModels.swift` and `DevBerth/Domain/ProcessResourceModels.swift`: semantic diff and threshold contracts.
- `DevBerth/App/AppModel.swift`: retained newest evidence, listener/resource publication gates, exact one-time retained-snapshot publication on foreground activation, batched lifecycle writes, and shared control-plane snapshot.
- `DevBerth/App/RootView.swift`, `DevBerth/Features/MenuBar/MenuBarView.swift`, and `DevBerth/App/DevBerthApp.swift`: actual AppKit window/application/key-state surface tracking; inactive retained backing windows no longer select active cadence.
- `DevBerth/App/RootView.swift`: broad section transition animation removed after foreground navigation profiling reduced repeated microhitches.

### Background work and persistence

- `DevBerth/Services/Docker/DockerAssociationProvider.swift` and `DevBerth/Features/Docker/DockerView.swift`: batched passive inspection, 30-second success cache, exponential unavailable backoff, and explicit invalidation.
- `DevBerth/Services/HealthChecks/ServiceCheckRunner.swift`, `DevBerth/Services/Launching/LaunchCoordinator.swift`, and `DevBerth/Services/Launching/ManagedProcessLauncher.swift`: cancellable generations, adaptive health cadence, four-batch gate, and stale-work suppression.
- `DevBerth/Services/Logging/DevBerthLogger.swift`, `DevBerth/Features/LaunchProfiles/ProfileLogsView.swift`, and `DevBerth/Features/LaunchProfiles/LaunchProfilesView.swift`: 50 ms ingress batching, revision-based visible updates, and bounded redacted persistence.
- `DevBerth/Persistence/SwiftDataStore.swift`: batched semantic lifecycle/history writes and compatibility process-history retention at 5,000 rows with headroom.
- `DevBerth/ControlPlane/ApplicationControlPlane.swift`, `DevBerth/ControlPlane/ApplicationControlPlane+Operations.swift`, `DevBerth/Services/Ownership/OwnerAwareLifecycleRouter.swift`, and `DevBerth/Services/ServiceProtocols.swift`: one authoritative monitoring/control boundary and explicit refresh/invalidation paths.

### Instrumentation and UI

- `DevBerth/Services/Monitoring/PerformanceInstrumentation.swift`: OS-gated signpost intervals plus bounded, aggregate, non-secret counters/warnings.
- `DevBerth/Features/Settings/PerformanceDiagnosticsView.swift` and `DevBerth/Features/Settings/SettingsView.swift`: internal diagnostics sheet that polls only while visible and dismisses with Escape/cancel.

### Automated coverage and harnesses

- `DevBerthTests/AdaptiveMonitoringTests.swift`, `DevBerthTests/AppModelPerformanceTests.swift`, `DevBerthTests/ProcessCacheIdentityTests.swift`, and `DevBerthTests/RuntimeAndClassificationTests.swift`: coalescing, cadence, sleep/wake, duplicate-surface, volatile-UDP, hidden/publication, semantic-diff, and cache-identity regressions.
- `DevBerthTests/DockerTests.swift`, `DevBerthTests/LaunchCoordinatorTests.swift`, `DevBerthTests/PersistenceTests.swift`, and `DevBerthTests/SecurityAndLoggingTests.swift`: bounded background/persistence/log behavior.
- `DevBerthTests/PerformanceBenchmarkTests.swift` and `DevBerthTests/PerformanceInstrumentationTests.swift`: parser/diff benchmarks and diagnostic bounds.
- `DevBerthUITests/DevBerthUITests.swift`: Performance Diagnostics UI coverage within the production-data isolation boundary.
- `Scripts/run_soak_tests.sh`: repeatable multi-suite performance/soak gate.
- `Scripts/run_performance_soak.sh`: exact-PID isolated Release sampler for CPU, cumulative CPU, RSS, threads, children, and error lines.

### Durable documentation

- `AGENTS.md`: prescriptive adaptive-monitoring, surface, retained-publication, cache, and diagnostics rules.
- `ARCHITECTURE.md` and `Documentation/ARCHITECTURE.md`: root navigation and canonical architectural boundary.
- `CHANGELOG.md`: unreleased performance change summary.
- `Documentation/PERFORMANCE_AUDIT.md`: untouched baseline, root-cause attribution, Instruments paths, matched results, and remaining gaps.
- `Documentation/PERFORMANCE_OPTIMIZATION_PLAN.md`: evidence-to-change priorities, defaults, and acceptance criteria.
- `Documentation/MONITORING_ARCHITECTURE.md`: scheduler, semantic evidence, cache, background work, diagnostics, safety, and trade-offs.
- `Documentation/PERFORMANCE_AND_SOAK_RESULTS.md`: final Release measurements, scenarios, validation, and residual limitations.
- `Documentation/PERFORMANCE_AND_SOAK_TEST.md`: historical measurement-era design clearly marked superseded.
- `Documentation/README.md`, `docs/README.md`, and `docs/implementations/devberth/README.md`: indexed/current implementation state.

## Observed validation and runtime results

- Exact repository command passed: 210/210 tests, zero failures/skips/expected failures, about 117 seconds. Result bundle: `/Users/theokim/Library/Developer/Xcode/DerivedData/DevBerth-fduqwhbmgbjvrdfsmjeotmfegtiu/Logs/Test/Test-DevBerth-2026.07.22_10-53-48-+0900.xcresult`.
- `DEVBERTH_SOAK_PASSES=2 Scripts/run_soak_tests.sh` passed both iterations. Result bundle: `/tmp/devberth-soak-derived/Logs/Test/Test-DevBerth-2026.07.22_10-43-45-+0900.xcresult`.
- Five-minute isolated Release soak: `/tmp/devberth-performance-final-soak`. It recorded 60 five-second samples, 0.11 CPU-seconds after warm-up over 293 seconds (~0.038%), steady RSS 132,992–165,568 KiB ending at 133,040 KiB, five to eleven threads settling at six, zero children in every sample, zero application error/fatal/crash lines, and clean exact-PID termination.
- Installed-app closed-window sample: 1.06 CPU-seconds / 901 seconds = 0.118% average CPU, versus 69.2% baseline; RSS ended at 106,736 KiB without monotonic growth.
- Installed-app foreground sample: main window 1.57 CPU-seconds / 60 seconds = 2.62%, versus 49.5% baseline; menu popover 0.06 CPU-seconds / 60 seconds = 0.10%.
- Final child sample: 9 direct children / 141 seconds = 3.8/minute, versus at least 126/minute deterministic baseline before metadata work.
- Production persistent-history rate: 808 changes and 72 transactions / 901 seconds, 98.4% and 84.0% lower rates than baseline. Deterministic unchanged snapshots produce zero lifecycle writes. Existing historical backlog was not compacted.
- Final Time Profiler: `/tmp/devberth-final-idle-time-profiler.trace`, 0.027 sampled CPU-seconds / 30.742 seconds, 0.001 on main, no potential hangs.
- Final SwiftUI: `/tmp/devberth-final-idle-swiftui.trace`, no hitches or hangs. Allocations: `/tmp/devberth-final-idle-allocations.trace`; `leaks -quiet` reported three 80-byte `CGRegion` allocations (240 bytes total), with no growing application-owned leak signature observed.
- Navigation Time Profiler: `/tmp/devberth-final-active-navigation-no-animation.trace`, two remaining potential hangs of 279.19 and 319.81 ms; uninstrumented Projects rendering completed between 100 and 500 ms.
- Power Profiler was unavailable to command-line Instruments on macOS 26.4. System Trace did not finish exporting after more than two minutes and was cancelled without a usable artifact. No kernel-wakeup percentage was fabricated.
- Final `Scripts/build-and-install-app` succeeded. `/Applications/DevBerth.app` and `/Users/theokim/Library/Application Support/DevBerth/bin/devberth-mcp` are matching Release 0.1.0 (1) artifacts.

## Current services, ports, data, and credentials

- Production `/Applications/DevBerth.app`: not running at capture. It exposes no TCP listener. The installed helper is stdio-only.
- Active installed stdio helpers at capture: PIDs 2153, 2279, 42333, and 54763, each `/Users/theokim/Library/Application Support/DevBerth/bin/devberth-mcp serve --stdio`.
- Active development MCP pair: PID 42474 app control host and PID 42475 stdio helper. The control host owns current-UID Unix socket `/Users/theokim/Library/Application Support/DevBerth/IPC/Development/control.sock`; it exposes no network URL or TCP port.
- Production SwiftData: `/Users/theokim/Library/Application Support/DevBerth.store` (118 MB at capture), with `-shm` 32 KB and `-wal` 1.6 MB. Isolated test/soak runs use in-memory or `/tmp` test-owned data and no production socket.
- Secrets: production secret values remain in macOS Keychain through `SecretStoring`; SwiftData contains opaque references only. No credential value was printed or copied into this handoff.
- Unrelated Docker workloads observed read-only and left running:
  - `tender_shannon`: `http://127.0.0.1:8080`, container port 8080.
  - `pg-consistency-lab`: PostgreSQL at `127.0.0.1:54329`, healthy.
  - `fervent_darwin`: `http://127.0.0.1:5173`.
  - `pharmacy-local-backend-1`: `http://127.0.0.1:18080`, healthy.
  - `pharmacy-local-postgres-1`: PostgreSQL at `127.0.0.1:15432`, healthy.
- Docker/database credentials were not inspected; their owning projects/environment are the source of truth. Do not stop or mutate these unrelated containers as part of the DevBerth performance task.

## Decisions and reasoning

- Optimize repeated work rather than micro-optimizing parser arithmetic: Time Profiler tied the dominant cost to timestamp-only publication/persistence and hidden SwiftUI invalidation.
- Keep polling on the macOS 14 API baseline, but adapt cadence to real foreground surfaces and stability. Known mutations/wake/manual refresh remain immediate.
- Treat timestamps as fresh evidence, not semantic transitions. Genuine identity/ownership/project/Docker/managed-service changes still publish and persist.
- Keep high-numbered interface-bound UDP endpoints observable but exclude their churn from transition-cadence extension; otherwise normal browser traffic pins subsecond polling.
- Keep resource evidence current internally, suppress hidden resource-only publication, and emit one retained-snapshot publication when the first foreground surface appears.
- Validate cache reuse against native full process identity. Cache data never grants destructive authority; lifecycle actions retain fresh safety revalidation.
- Preserve the existing production store and historical backlog. Automatic compaction/vacuum would be a separate destructive data-maintenance decision.
- Use test-owned/in-memory fixtures for mutation and soak. Real-host profiling remained read-only.

## Known bugs, risks, and incomplete areas

- Foreground section navigation retains two measured 279–320 ms microhitches. This is materially improved and separate from the eliminated idle loop, but future work should profile view construction and data shaping.
- Hidden stable listener evidence may be up to 30 seconds old. A short-lived high-numbered interface UDP endpoint can appear and disappear between hidden scans.
- The pre-fix persistent-history backlog remains in the 118 MB store. New false writes are eliminated, but safe offline compaction is not implemented.
- No matched kernel idle-wakeup counter exists for the untouched baseline. Power Profiler/System Trace limitations are explicit in the audit.
- One earlier XCUITest attempt timed out while enabling automation before tests ran, and one isolated first launch missed Runtime; the immediate case retry and final full 210-test action passed. This appears to be macOS automation startup instability, not a reproducible app failure.
- GitHub source releases remain separate from Xcode `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`; the installed app is not claimed to be signed, notarized, distributable, or auto-updatable.

## Exact next tasks

1. Wait for PR #24 CI and stop if any required check or review is blocking.
2. Create a release-ready roll-up branch from the fully composed `performance/cpu-and-responsiveness` tip and a roll-up PR to `main`. Link PRs #19–#24 and include the measured validation above.
3. Verify every shard `headRefName`/`baseRefName` and the roll-up check state, then merge only the roll-up PR with a merge commit. Do not merge lower shards individually and do not squash.
4. Verify `.github/workflows/release-on-merge.yml` succeeds once, the one immutable `v0.1.<run-number>` tag targets the roll-up merge commit, and the published GitHub Release truthfully links the roll-up and incorporated shards.
5. Close PRs #19–#24 as incorporated with a link to the roll-up PR/merge commit. Keep stack branches until no open PR uses them as head or base.
6. Switch to `main`, fast-forward from `origin/main`, and report the exact roll-up PR, merge commit, incorporated PRs, tag/release, and measured results.

## Resume and validation commands

```sh
cd /Users/theokim/Documents/github/portpilot-macos
git fetch origin
git switch performance/cpu-and-responsiveness
git pull --ff-only

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project DevBerth.xcodeproj \
  -scheme DevBerth \
  -destination 'platform=macOS' \
  test

DEVBERTH_SOAK_PASSES=2 Scripts/run_soak_tests.sh

DEVBERTH_PERFORMANCE_SOAK_SECONDS=300 \
DEVBERTH_PERFORMANCE_SAMPLE_SECONDS=5 \
DEVBERTH_PERFORMANCE_RESULTS=/tmp/devberth-performance-final-soak \
DEVBERTH_PERFORMANCE_SKIP_TESTS=1 \
Scripts/run_performance_soak.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/build-and-install-app
```

## Stop commands

- Production app is not running. If opened later: `osascript -e 'tell application "DevBerth" to quit'`.
- Stop the development MCP pair from its owning terminal with Control-C. At capture the exact PIDs were 42475 and 42474; recheck their full commands with `ps -ww -p 42475,42474 -o pid=,command=` before `kill -TERM 42475 42474` because PIDs can be reused.
- The installed stdio MCP helpers belong to active clients; close their owning Codex tasks instead of killing them blindly.
- Do not stop the listed Docker containers for this task; they are unrelated user workloads.

## Ready-to-paste prompt for the next Codex session

```text
Resume the DevBerth CPU/responsiveness task from /Users/theokim/Documents/github/portpilot-macos. Read AGENTS.md and docs/next-steps/README.md completely. The implementation is complete on performance/cpu-and-responsiveness at captured HEAD e95e145; exact local validation passed 210/210 tests, two repeated soak iterations passed, and the isolated 300-second Release soak was stable. Inspect PR #24 and the full #19→#24 stack, preserve every immediate base relationship, then complete the one release-ready roll-up PR to main, merge only that roll-up with commit history preserved, verify the single release workflow/tag/GitHub Release, close the lower PRs as incorporated, and update local main. Do not merge lower shards individually, squash, delete a branch used by an open PR, mutate unrelated Docker workloads, or compact the production store. Report any blocking review/check instead of force-merging.
```
