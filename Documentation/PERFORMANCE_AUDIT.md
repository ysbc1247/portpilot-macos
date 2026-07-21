# DevBerth Performance Audit

Status: baseline measurement and implementation profiling in progress  
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

The UI-state scenarios, child-process counts, scan timing, trace call paths, and before/after comparison are appended only after each measurement completes. Values above are observed values, not projections.

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

The same component retains bounded, non-secret diagnostic counters for scan latency/count, coalescing, cache size/hit rate, Docker latency, health checks, background tasks, and recent performance warnings. The internal UI is added in a separate review shard.

## Evidence still to append

- complete 1/5/15-minute idle CPU, memory, wakeup, WAL, and row-count checkpoints;
- window-visible, window-closed, menu-bar-open, port-change, project-operation, Docker-available, and Docker-unavailable comparisons;
- Time Profiler and SwiftUI call-path summaries;
- child-process frequency and command-duration distribution;
- SwiftData write frequency and log-processing cost;
- main-thread stall/hitch measurements;
- before/after results from the same Release build protocol.
