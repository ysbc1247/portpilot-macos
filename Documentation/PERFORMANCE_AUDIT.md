# DevBerth Performance Audit

Status: complete
Baseline commit: `8cc670eabeabe8559383d6f0f6a1918485102f45`  
Measurement date: 2026-07-22 (KST, UTC+09:00)

## Test system

- MacBook Pro (Mac17,2), Apple M5, 10 cores, 24 GB memory
- macOS 26.4 (25E246)
- Xcode 26.4 (17E192)
- DevBerth Release build 0.1.0 at `/Applications/DevBerth.app`
- Docker client/server 29.3.0 available during the initial run
- Approximately 70 active listener rows in the real local runtime

The baseline uses the installed Release application and its real read-only listener and Docker observations. No unrelated process or container is signalled. Mutation scenarios use only test-owned fixture processes. CPU percentages are normalized to one logical core, as reported by `top`; values can exceed 100% when more than one core is active.

## Reproducible measurement method

1. Build the untouched source with:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
     -project DevBerth.xcodeproj \
     -scheme DevBerth \
     -configuration Release \
     -destination 'platform=macOS' \
     CODE_SIGNING_ALLOWED=NO \
     build
   ```

2. Record cumulative process CPU time, resident memory, the SwiftData WAL size, and bounded lifecycle/history row counts at each checkpoint.
3. Use `top` one-second samples for short visible-window and menu-bar comparisons. Derive interval CPU from the change in cumulative process CPU time so sampling spikes do not dominate the result.
4. Capture Time Profiler, SwiftUI, Allocations, Leaks, System Trace, and Points of Interest traces with `xctrace`; retain traces as local profiling artifacts rather than source-controlled binaries.
5. Count only direct children of the DevBerth process when measuring command-spawn frequency.

## Initial baseline

| Scenario | Window | Duration | CPU time used | Average CPU | Resident memory | Notes |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Stable runtime, no interaction | Open on Projects | ~69 s | 34.17 s | ~49.5% | 129–143 MB | Repeated 80–105% one-second spikes |
| Stable runtime, no interaction | Closed; menu-bar extra retained | 60 s | 50.28 s | ~83.8% | 176–185 MB | 33 net lifecycle rows added while retention pruning remained active |
| Stable runtime, no interaction | Closed; menu-bar extra retained | 5 min | 185.09 s | ~61.5% | 168–185 MB | WAL remained active; one-minute transaction sample below |
| Stable runtime, no interaction | Closed; menu-bar extra retained | 15 min | 623.86 s | ~69.2% | 168–185 MB | Memory stabilized; CPU did not. Process history added 88 rows and lifecycle retention continuously pruned/replaced rows. |

The live SwiftData persistent-history tables grew by 30 transactions and 3,460 changes during a separate 60-second closed-window sample. The 30-transaction rate exactly matches the fixed two-second monitor cadence, confirming one persistence transaction per scan even though the runtime was stable.

## Time Profiler attribution

A 30-second Time Profiler recording of the closed-window Release process captured 24.4 CPU-seconds (about 81% average CPU during the trace). The main thread accounted for 19.558 CPU-seconds, or 80.2% of all sampled CPU. The highest inclusive paths were:

| Inclusive path | Sampled CPU | Interpretation |
| --- | ---: | --- |
| SwiftUI `NSRunLoop.flushObservers` | 14.657 s | Hidden/closed scene graph continued processing published model updates |
| SwiftUI `GraphHost.flushTransactions` | 13.598 s | Repeated broad view transactions |
| AttributeGraph update | 13.566 s | Large dependency graph invalidated on each monitor publish |
| `AppModel.recordPortChanges` → `RuntimeLifecycleTracker.transition` | 4.415 s / 4.409 s | Timestamp-only listener updates treated as lifecycle transitions |
| `SwiftDataStore.record` | 4.390 s | False transitions persisted every scan |
| `SwiftDataStore.pruneLifecycleEvents` | 3.866 s | Retention repeatedly fetched and pruned while the false write stream continued |

Inclusive values overlap because parent and child frames share samples. The trace nevertheless establishes two independent hot paths: main-thread SwiftUI invalidation and background lifecycle persistence/pruning. The trace is retained locally at `/tmp/devberth-baseline.Npfcrl/background-time-profiler.trace` and is not committed as a binary artifact.

## Child-process pressure

A 600-iteration, 100 ms process-tree sample observed 97 distinct direct DevBerth child PIDs. Three were pre-existing managed runtimes, leaving at least 94 newly observed command children during the sampling window. Short-lived `ps` commands can start and exit between samples, so this is a lower bound.

The source cadence provides the deterministic minimum before metadata refresh work:

- 60 `lsof` commands/minute from paired TCP/UDP discovery at two-second polling;
- 30 batched resource `ps` commands/minute; and
- up to 36 Docker commands/minute from `version`, `ps`, and batched `inspect` on the five-second Docker refresh.

That is at least 126 monitoring subprocesses/minute, plus the rolling metadata refresh budget. Once metadata is stale, each refreshed PID currently adds a `ps` and `lsof` pair; with many active processes the three-PID-per-scan budget can add up to 180 more subprocesses/minute until the stale set cycles.

These values are observed measurements, not projections. The optimized comparison uses the same installed Release workflow and real read-only host observations.

## Confirmed root-cause chain

The first source audit found a deterministic high-cost loop:

1. `PortMonitor` performs a full listener scan on a fixed two-second interval regardless of visibility or runtime stability.
2. `LocalPortDiscovery` assigns a fresh `lastDetectedAt` to every listener on every scan.
3. `RuntimeDiffer` uses whole-value equality, so the timestamp-only mutation classifies every unchanged listener as `updated`.
4. `AppModel` republishes the complete listener array and a newly allocated resource-usage dictionary on every scan.
5. `recordPortChanges` forwards every timestamp-only `updated` listener into `RuntimeLifecycleTracker`.
6. Lifecycle tracking persists those false changes through SwiftData. The lifecycle table is bounded, but repeated insert/prune/save work and WAL traffic continue indefinitely.
7. Each scan also launches two `lsof` processes plus batched `ps` resource inspection; Docker correlation refreshes independently every five seconds.

This chain explains both the background CPU result and the additional visible-window cost. It also explains why capping history rows did not cap persistence work.

## Additional confirmed risks

- Process metadata is cached by PID plus the short `lsof` name. PID reuse can return stale metadata because UID, start time, executable identity, and command digest are not part of the cache key.
- `refreshNow()` cancels and recreates the monitor stream. Cancellation does not await the in-flight scan, so repeated refresh requests can overlap expensive discovery work.
- `RootView.task` calls `startMonitoring()` whenever the main scene task is recreated. The old task is cancelled, but ownership and cancellation are not expressed as one idempotent application-lifetime pipeline.
- Docker availability and observation have a fixed five-second cache with no unavailable-engine backoff.
- Process resource usage is republished even when values do not cross a meaningful display threshold.
- Process history contains more than 12,000 rows on the baseline store and has no automatic retention path equivalent to lifecycle retention.

## Instrumentation added for the optimized build

`PerformanceInstrumentation.swift` defines reusable, OS-gated signpost intervals for:

- full runtime scan;
- listener discovery;
- process enrichment;
- Docker refresh;
- project inference;
- runtime diff;
- SwiftData write;
- health-check batch;
- log processing;
- SwiftUI state publish;
- MCP request; and
- lifecycle operation.

The same component retains bounded, non-secret diagnostic counters for scan latency/count, coalescing, cache size/hit rate, Docker latency, health checks, background tasks, and recent performance warnings.

Settings now exposes those counters in an internal Performance Diagnostics sheet. It polls the bounded aggregate snapshot once per second only while open, supports explicit refresh and Escape/Cancel dismissal, and never displays listener details, paths, commands, logs, environment values, or secrets.

## Runtime scheduling and semantic fixes

The optimized pipeline has one idempotent `PortMonitor` loop. Immediate refresh requests interrupt its cancellable delay and collapse behind an in-flight scan, preventing the former cancel-and-recreate overlap. Main-window and menu-bar visibility select the configured active cadence; transitions use a short burst, hidden stable monitoring uses at least ten seconds, and a hidden runtime unchanged for three minutes backs off to at least thirty seconds. System sleep suspends work and wake schedules one fresh transition scan.

Docker correlation now precedes the runtime diff. The semantic comparator excludes `firstDetectedAt`, `lastDetectedAt`, and fingerprint `detectedAt`, but retains process identity, command, project, managed-service, and Docker evidence. AppModel therefore retains fresh evidence without invalidating SwiftUI or writing lifecycle rows for timestamp-only scans. Resource state applies explicit CPU and memory publication thresholds.

The process metadata cache now uses a native, non-spawning identity read for PID, UID, start time, parent PID, executable path/device/inode, argument digest, and current directory. It invalidates PID reuse, `exec`, executable replacement, argument changes, and directory changes immediately, retains entries for five minutes, refreshes at most three otherwise-expired entries per scan, and never exceeds 512 current entries.

## Background work fixes

- Passive Docker observation now uses the existing batched `ps` plus one `inspect` path directly, removing the separate `docker version` command. Its normal cache is 30 seconds, failures back off exponentially to five minutes, and manual or completed Docker mutations invalidate immediately.
- Process resource sampling is independent of listener cadence: one second during transitions, five seconds active, 30 seconds background, and 60 seconds idle, with immediate sampling when the PID set changes.
- Ongoing health schedules use the reviewed fast interval only for recovery, move to a minimum fifteen-second interval after three healthy samples, back off repeated failures to sixty seconds, add ten-percent jitter, and share a four-batch concurrency gate. Stop, exit, deletion, and sleep suppress stale work.
- Managed stdout/stderr bytes are combined in 50 ms ingress batches before redaction, line parsing, bounded persistence, and UI visibility. The open log view checks a lightweight revision twice per second and fetches entries only after a committed batch.
- Compatibility process history is pruned to the newest 5,000 records at startup and with 100-record write headroom, matching the existing lifecycle bound without altering shipped schemas.

## Optimized Release comparison

| Metric | Baseline | Optimized | Observed change |
| --- | ---: | ---: | ---: |
| Closed-window CPU over 901 seconds | 623.86 CPU-s (69.2%) | 1.06 CPU-s (0.118%) | 99.83% lower |
| Closed-window Time Profiler sampled CPU | 24.4 CPU-s / 30 s | 0.027 CPU-s / 30.742 s | 99.89% lower |
| Main-thread Time Profiler sampled CPU | 19.558 CPU-s | 0.001 CPU-s | 99.995% lower |
| Direct monitoring children | deterministic minimum 126/min before metadata work | 9 / 141 s (3.8/min) | about 97.0% lower |
| Persistent-history changes | 3,460 / 60 s | 808 / 901 s | 98.4% lower rate on the churny real host; zero for unchanged deterministic snapshots |
| Persistent-history transactions | 30 / 60 s | 72 / 901 s | 84.0% lower rate on the real host |
| Main-window foreground CPU | 34.17 CPU-s / 69 s (49.5%) | 1.57 CPU-s / 60 s (2.62%) | 94.7% lower |
| Menu-popover foreground CPU | not separately isolated | 0.06 CPU-s / 60 s (0.10%) | optimized result only |

The final closed-window process began the 901-second interval at 7.41 cumulative CPU-seconds and ended at 8.47. Resident memory began at 160,304 KiB, settled mostly between 85 and 115 MB, had one 141 MB sample, and ended at 106,736 KiB; it did not grow monotonically. The store stayed at 123,924,480 bytes. Its WAL checkpointed from 1,919,952 bytes before the interval to 173,072 bytes afterward. Process and lifecycle histories remained under their 5,000-row caps.

The 141-second process-tree sample saw four TCP/UDP `lsof` pairs and one Docker `ps`. A very short batched resource `ps` can start and exit between 200 ms samples, so 3.8 children/minute is a measured lower bound. It is consistent with the final 30-second hidden-stable listener schedule rather than the former two-second schedule.

The real host was not semantically static: high-numbered browser UDP endpoints and other process evidence changed during the interval. The semantic fix therefore removes false timestamp-only writes, while genuine observations still produce bounded history. Deterministic unchanged-snapshot tests verify zero lifecycle persistence and zero listener publication.

## Instruments and responsiveness findings

The final unattended Time Profiler trace at `/tmp/devberth-final-idle-time-profiler.trace` captured only 27 milliseconds of sampled CPU over 30.742 seconds, including one millisecond on the main thread. It reported no potential hangs longer than 250 ms. The final idle SwiftUI trace at `/tmp/devberth-final-idle-swiftui.trace` reported no hitches or hangs; its scene-graph update rows did not form a sustained CPU path. The Allocations trace is at `/tmp/devberth-final-idle-allocations.trace`. `leaks -quiet` reported three 80-byte `CGRegion` allocations (240 bytes total) among 124,303 malloc nodes / 26,088 KiB, with no growing application-owned leak signature during the observation.

Foreground navigation remained the largest responsiveness limit. A Time Profiler navigation run initially reported three potential main-thread hangs of 259–345 ms. Removing the broad selection animation reduced the repeated run to two potential hangs, 279.19 and 319.81 ms. Uninstrumented capture showed Projects fully rendered by 500 ms after selection but not at 100 ms. This is a residual microhitch, not a background loop regression, and remains called out for future view-construction profiling.

The macOS 26.4 Power Profiler template was unavailable to command-line Instruments, and a System Trace attempt did not finish exporting after more than two minutes and was cancelled without a usable artifact. Those gaps are reported rather than replaced with inferred kernel wakeup values. Scheduled listener passes and direct-child counts are the repeatable external-work proxies available for both builds.

## Regression and soak harness

`Scripts/run_soak_tests.sh` repeats the bounded persistence/log tests, parser/diff benchmarks, AppModel/monitor regressions, Docker/log tests, application-owned integration fixtures, and development control-plane/MCP acceptance coverage. It uses normal project tools and does not require an output-filtering wrapper.

`Scripts/run_performance_soak.sh` first runs that suite, then builds an isolated Release app and launches it with `DEVBERTH_UI_TESTING=1`: in-memory V7 persistence, a static listener/resource fixture, unavailable test Docker, and no control socket. It samples CPU, cumulative CPU, RSS, thread count, and direct child count into CSV and always terminates only the exact isolated PID it launched. A 10-second harness smoke run completed five samples with zero child processes and zero application error lines; RSS warmed from 11.8 MB to 155.7 MB and settled at 147.7 MB, while cumulative CPU reached 0.92 seconds during startup and did not increase in the last three samples. The final repeated and five-minute results are recorded in `Documentation/PERFORMANCE_AND_SOAK_RESULTS.md`.
