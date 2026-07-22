# Performance and soak results

Measurement date: 2026-07-22 (Asia/Seoul, UTC+09:00)
Baseline commit: `8cc670eabeabe8559383d6f0f6a1918485102f45`
Optimized branch: `performance/cpu-and-responsiveness`

## Result summary

The dominant background cost was eliminated by removing timestamp-only state propagation and persistence, consolidating monitoring into one adaptive/coalescing loop, and making SwiftUI publication conditional on semantic evidence and real foreground surface state. Follow-up live profiling also found and fixed two macOS-specific scheduling traps: inactive AppKit backing windows that remained visible after their SwiftUI surface closed, and volatile high-numbered interface UDP endpoints that continually extended transition polling.

| Metric | Baseline Release | Optimized Release | Change |
| --- | ---: | ---: | ---: |
| Closed-window CPU, 15-minute sample | 623.86 CPU-s / 901 s = 69.2% | 1.06 CPU-s / 901 s = 0.118% | 99.83% less CPU |
| Closed-window Time Profiler CPU, 30 s | 24.4 CPU-s (about 81%) | 0.027 CPU-s / 30.742 s = 0.088% | 99.89% less sampled CPU |
| Main-thread Time Profiler CPU, 30 s | 19.558 CPU-s | 0.001 CPU-s | 99.995% less sampled main-thread CPU |
| Deterministic monitoring children | at least 126/min before metadata work | 9 observed / 141 s = 3.8/min in final idle mode | about 97.0% fewer direct children |
| Stable hidden listener cadence | fixed 2 s | 10 s background; 30 s after 180 s stable | 5× / 15× slower |
| Stable scan persistence | 30 transactions and 3,460 persistent-history changes / 60 s | zero writes in deterministic unchanged-snapshot tests | false writes eliminated |
| Main-window foreground CPU | 34.17 CPU-s / 69 s = 49.5% | 1.57 CPU-s / 60 s = 2.62% | 94.7% less CPU |
| Menu-popover foreground CPU | not separately isolated | 0.06 CPU-s / 60 s = 0.10% | optimized result only |

An earlier post-semantic-fix trace captured 0.731 CPU-seconds (2.38%) and 0.013 main-thread CPU-seconds before the final foreground-surface and volatile-UDP cadence corrections. The table uses the definitive final trace after every scheduler correction.

## Release-process idle observation

The installed app and helper came from the same Release build through `Scripts/build-and-install-app`. The app observed the real local runtime and Docker Engine read-only; all app windows and the menu popover were closed before the long sample. No user process, service, or container was signalled.

The final 141-second direct-child sample observed exactly four paired TCP/UDP discovery passes and one Docker list command. This matches 30-second idle discovery plus cached Docker work. The very short batched resource `ps` process can fall between 200 ms process-tree samples, so the child rate is a measured lower bound, not a claim of zero resource sampling.

The production store entered this sample with 3,090,232 `ACHANGE` rows and 35,819 `ATRANSACTION` rows accumulated largely by the pre-fix application. Existing persistent-history rows were not destructively compacted as part of this performance change. The acceptance comparison therefore uses deltas and WAL growth, not the historical absolute size.

Over the final 901-second interval, cumulative CPU moved from 7.41 to 8.47 seconds. RSS began at 160,304 KiB, settled mostly between 85 and 115 MB with one 141 MB sample, and ended at 106,736 KiB. The 123,924,480-byte store did not grow. Its WAL checkpointed from 1,919,952 bytes to 173,072 bytes. Persistent history added 808 changes and 72 transactions (53.8 changes/minute and 4.8 transactions/minute), versus 3,460 changes/minute and 30 transactions/minute before the fix. Those remaining writes reflect genuine churn on the real host; deterministic unchanged snapshots write nothing. Process and lifecycle histories ended at 4,922 and 4,930 rows, remaining below the 5,000-row bounds.

## Scenario coverage

| Scenario | Evidence and outcome |
| --- | --- |
| Stable runtime, main visible | Active two-second cadence remains available while DevBerth is foreground-visible; semantic diffing and resource thresholds prevent timestamp-only graph invalidation. |
| Main closed | Actual AppKit window close/visibility, occlusion, application activation, and duplicate-callback state drive the background/idle transition. |
| Menu popover | The menu counts as active only while its backing window is key and DevBerth is active; inactive retained backing windows do not hold active cadence. |
| Port/listener changes | TCP and stable UDP changes extend the 15-second transition burst. High-numbered interface-bound UDP client endpoints remain observable but do not extend it. Parser/diff/monitor regressions cover add, update, remove, and timestamp-only behavior. |
| Project start/stop | Application-owned integration fixtures exercise launch, listener detection, dependency/lifecycle routing, termination, and cleanup. No unrelated local service is mutated. |
| Docker available | The real engine is read passively with one `ps` plus one batched `inspect`, a 30-second cache, and explicit invalidation after known mutations. |
| Docker unavailable | Deterministic Docker fixtures verify unavailable-engine backoff and unchanged-listener behavior without changing the host engine. |
| Health and logs | Deterministic tests verify cancellation/generation ownership, bounded health concurrency/cadence, chunk-safe redaction, ingress batching, revision polling, rotation, and retention. |
| Sleep/wake and manual refresh | Adaptive monitor tests verify one cancellable loop, one in-flight scan maximum, request coalescing, suspension, resume, and clean stop. |

## Profiling artifacts

Binary Instruments traces remain local and are not committed:

- baseline Time Profiler: `/tmp/devberth-baseline.Npfcrl/background-time-profiler.trace`;
- post-semantic-fix Time Profiler: `/tmp/devberth-final-background-time-profiler.trace`;
- final traces and exported summaries: paths recorded in the final validation section below.

The baseline main thread spent 14.657 sampled seconds in SwiftUI run-loop observer flushing and 13.566 seconds in AttributeGraph updates. The definitive final trace `/tmp/devberth-final-idle-time-profiler.trace` reduced the main thread to one sample (0.001 seconds) and the whole process to 27 samples (0.027 seconds) across 30.742 seconds. It reported no potential hangs over 250 ms and no remaining dominant main-thread loop.

The final SwiftUI trace `/tmp/devberth-final-idle-swiftui.trace` reported no hitches or hangs. The Allocations trace is `/tmp/devberth-final-idle-allocations.trace`; `leaks -quiet` reported three 80-byte `CGRegion` allocations, 240 bytes total, among 124,303 malloc nodes / 26,088 KiB. Command-line Instruments did not expose the Power Profiler template on macOS 26.4. A System Trace attempt did not finish exporting after more than two minutes and was cancelled without a usable result, so this report does not fabricate kernel wakeup data.

## Automated soak and regression coverage

`Scripts/run_soak_tests.sh` repeats the performance-soak, parser/diff, AppModel/monitor, batching, Docker, security/logging, owned integration, and MCP control-plane tests with fresh test-owned state. `Scripts/run_performance_soak.sh` builds an isolated Release app with in-memory persistence, a static listener/resource fixture, unavailable test Docker, and no production control socket, then records process CPU, RSS, threads, children, and error lines.

The short harness proof recorded five samples over ten seconds: startup reached 0.92 cumulative CPU-seconds, the last three samples added no CPU time, no child process was observed, no application error line was emitted, and RSS settled from a 155.7 MB peak to 147.7 MB. The final repeated and extended results are recorded after the final validation run below.

## Final validation

- The repository's exact warnings-as-errors command passed all 210 tests with zero failures, skips, or expected failures in about 117 seconds. This includes all seven UI tests, nine application-owned integration tests, 19 MCP tests, performance benchmarks, and the new scheduling/publication regressions. An earlier attempt hit a macOS XCUITest automation bootstrap timeout before executing UI coverage; an isolated retry and this final complete action both passed. Result: `/Users/theokim/Library/Developer/Xcode/DerivedData/DevBerth-fduqwhbmgbjvrdfsmjeotmfegtiu/Logs/Test/Test-DevBerth-2026.07.22_10-53-48-+0900.xcresult`.
- `DEVBERTH_SOAK_PASSES=2 Scripts/run_soak_tests.sh` passed both iterations over performance soak/benchmarks, AppModel/monitor regressions, event batching, security/logging, Docker, application-owned integration fixtures, and MCP protocol coverage. The result bundle is `/tmp/devberth-soak-derived/Logs/Test/Test-DevBerth-2026.07.22_10-43-45-+0900.xcresult`.
- The 300-second isolated Release soak at `/tmp/devberth-performance-final-soak` produced 60 five-second samples. From the first post-startup sample through the last, cumulative CPU rose from 0.77 to 0.88 seconds: 0.11 CPU-seconds over 293 seconds, or about 0.038%. Steady RSS ranged from 132,992 to 165,568 KiB and ended at 133,040 KiB. Threads settled from 11 to five or six, every sample had zero direct children, and the application log contained zero `error`, `fatal`, or `crash` lines. The harness terminated only the exact process it launched.
- `Scripts/build-and-install-app` rebuilt and atomically refreshed both `/Applications/DevBerth.app` and `~/Library/Application Support/DevBerth/bin/devberth-mcp` from the same Release build.

## Residual limitations

- Polling remains necessary on the macOS 14 API baseline. Hidden stable observations may be up to 30 seconds old until a known mutation, wake, surface activation, or manual/MCP refresh interrupts the delay.
- High-numbered interface-bound UDP endpoint churn is still captured, but it is sampled at the current background/idle cadence instead of forcing transition cadence. A short-lived endpoint can therefore appear and disappear between hidden scans.
- The optimized code stops new false SwiftData writes; it does not automatically vacuum the large persistent-history backlog created by earlier builds. A separate reviewed data-maintenance change would be required to compact existing stores safely.
- Kernel idle-wakeup counters were not captured for the untouched baseline, so no fabricated before/after wakeup percentage is reported. Scheduled listener passes fell from 30/minute to 2/minute in idle mode, and direct-child observation provides the comparable external-work metric.
- Foreground section navigation still produced two Time Profiler potential hangs of 279–320 ms after removing broad selection animation. Uninstrumented Projects rendering completed between 100 and 500 ms. Further view-construction work is intentionally deferred rather than conflated with the eliminated idle loop.
