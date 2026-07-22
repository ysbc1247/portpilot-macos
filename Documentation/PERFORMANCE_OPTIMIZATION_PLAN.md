# Performance optimization plan

Status: implemented and under final measured validation  
Branch: `performance/cpu-and-responsiveness`  
Baseline: `8cc670eabeabe8559383d6f0f6a1918485102f45`

## Decision rule

Every optimization in this plan traces to a baseline measurement, a Time Profiler path, or a deterministic command/write count. The work deliberately avoids generic micro-optimization: the dominant cost was repeated work, not a slow inner arithmetic loop.

## Prioritized findings and actions

| Priority | Evidence | Root cause | Implemented action | Success criterion |
| --- | --- | --- | --- | --- |
| P0 | Closed-window Release used 69.2% CPU over 15 minutes; 24.4 CPU-seconds in a 30-second trace | A fixed two-second scan converted observation timestamps into semantic updates, full SwiftUI invalidation, lifecycle writes, and retention pruning | Compare stable runtime evidence separately from observation time; publish and persist only genuine transitions | Stable scans produce no lifecycle writes and no listener publication |
| P0 | 19.558 of 24.4 sampled CPU-seconds were on the main thread | Whole AppModel state was republished to a retained hidden SwiftUI graph | Keep listener/resource evidence internally, publish semantic listener changes only, threshold resource changes, and suppress resource-only publication with no visible surface | Closed-window main-thread sample share and CPU fall materially |
| P0 | At least 126 deterministic monitoring children/minute before metadata work | Listener, resource, and Docker loops ran at independent fixed high cadence | One adaptive monitor; decoupled resource cadence; slower Docker cache/backoff; native metadata identity/cache | Child launches scale with active/background/idle mode and no N+1 metadata children remain |
| P0 | SwiftUI `onDisappear` did not fire when a macOS window closed | View lifecycle was incorrectly used as window/popover visibility | Observe the containing AppKit window's visible/occlusion/minimize/close state | Closed main window and closed menu popover select background then idle mode |
| P0 | A browser's high-numbered interface UDP endpoint appeared/disappeared on successive scans | Correct but volatile UDP evidence reset the 15-second transition burst indefinitely | Retain the endpoint in snapshots/diffs/history but exclude that endpoint class from cadence extension | Busy client UDP activity cannot pin transition cadence; TCP and stable UDP remain immediate |
| P0 | Reconstructed visibility reporters and inactive backing windows woke scans | Duplicate callbacks interrupted delays; AppKit visibility/key state alone did not express foreground use | Make surface membership idempotent and require application activation for foreground surfaces | Repeated equal callbacks cause no scan and inactive/closed surfaces back off |
| P1 | Refresh cancellation could leave an old scan in flight | Manual/MCP/operation refresh recreated stream tasks | Keep one idempotent monitor task; interrupt its delay and coalesce to one pending scan | Maximum concurrent scan count remains one |
| P1 | PID/name cache could survive PID reuse | Cache key lacked start time, UID, executable identity, and command identity | Native `libproc`/`sysctl` identity fingerprint with bounded age, count, and stale-refresh budget | PID reuse and `exec` invalidate cached metadata immediately |
| P1 | Docker ran availability plus list/inspect work every five seconds | Separate availability and fixed cache duplicated CLI work and amplified daemon loss | Direct batched `ps`/`inspect`, 30-second success cache, exponential unavailable backoff to five minutes, explicit invalidation | No N+1 queries or separate passive availability subprocess |
| P1 | Health work could remain frequent and concurrent | Per-service scheduling lacked global capacity and stable cadence | Generation cancellation, four-batch gate, healthy slowdown, failure backoff, jitter, sleep/deletion suppression | Deleted/stopped services have no surviving checks; concurrency never exceeds four |
| P1 | Logs could publish per stdout/stderr chunk | Chunk arrival drove actor, disk, and UI work separately | 50 ms ingress batching, revision-based visible polling, existing count/byte rotation and cross-chunk redaction | Bounded logs with fewer UI/disk updates and unchanged streaming correctness |
| P1 | Process history exceeded 12,000 rows | Compatibility history had no automatic retention | Startup repair and 5,000-row retention with 100-row write headroom | Long-running history remains bounded without prune-per-event churn |

## Delivery sequence

1. Instrument every required operation with stable, low-cost signposts and bounded secret-free counters.
2. Establish the untouched Release baseline and retain local traces.
3. Consolidate and adapt the runtime monitor; add semantic diffing and safe native metadata caching.
4. Bound Docker, resource, health, log, and persistence work.
5. Expose the bounded diagnostics snapshot only while its Settings sheet is open.
6. Add deterministic regressions, parser/diff benchmarks, and isolated soak tooling.
7. Re-profile the same Release installation protocol, compare like-for-like scenarios, and keep any remaining limitation explicit.

## Recommended defaults

| Mode/work | Default |
| --- | ---: |
| Transition listener scan | 0.75 s for 15 s after a known mutation/wake/cadence-relevant change |
| Visible active listener scan | 2 s, user configurable with conservative derived lower bounds |
| Hidden stable listener scan | 10 s |
| Hidden idle listener scan | 30 s after 180 s without semantic change |
| Resource sample | 1 s transition, 5 s active, 30 s background, 60 s idle |
| Passive Docker refresh | 30 s success cache; exponential failure backoff capped at 5 min |
| Stable healthy service check | At least 15 s after three healthy results |
| Health concurrency | 4 batches maximum |
| Log ingress/UI | 50 ms ingress batches; visible revision check every 500 ms |

The listener defaults keep known mutations immediate while making the no-window steady state approximately fifteen times slower than the original two-second loop. App Nap remains enabled; DevBerth takes no artificial activity assertion for passive observation.

## Acceptance

- One owned runtime monitor and no overlapping scans.
- Timestamp-only observations cause zero SwiftUI listener publications and zero lifecycle persistence.
- Full-identity cache invalidation passes PID-reuse, executable, command, and current-directory tests.
- Docker, health, resource, logging, history, and control-plane regressions pass.
- Release CPU and memory stabilize in the measured soak; no continuous child, history, WAL, or log growth.
- Stable `/Applications/DevBerth.app` and the installed `devberth-mcp` helper come from the same validated Release build.
