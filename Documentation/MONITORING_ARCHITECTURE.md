# Monitoring architecture

## Authority and data flow

`AppModel` owns one `PortMonitor` actor for the application lifetime. RootView, the menu-bar UI, lifecycle operations, Docker actions, sessions, and the app-owned control plane request work from that same object; none starts a second poller.

```text
known mutation / wake / manual refresh / timer
                    |
                    v
         PortMonitor (one actor/task)
                    |
       batched TCP + UDP listener query
                    |
       native identity check + bounded cache
                    |
       slow cached Docker correlation
                    |
             semantic runtime diff
              /              \
     genuine transition     timestamp-only refresh
       |          |                 |
 targeted UI   batched          internal evidence only
 publication   lifecycle write   (no write/publish)
```

The MCP/control host reads the AppModel snapshot. It does not run discovery or own persistence, so GUI and protocol clients cannot create duplicate monitoring or competing SwiftData writers.

## Adaptive schedule

The monitor chooses a mode immediately before each scan:

- `transition`: 0.75 seconds for 15 seconds after start, wake, a genuine runtime change, or a known mutation;
- `active`: the configured interval (two seconds by default) while an actual main window or menu popover is foreground-visible;
- `background`: at least ten seconds when no monitoring surface is visible;
- `idle`: at least 30 seconds after 180 seconds without a semantic change and with no visible surface.

Window state comes from the containing `NSWindow`, including visibility, occlusion, minimize/deminiaturize, close, key-window state for the menu popover, and application activation/hide state. SwiftUI `onDisappear` is not a window-visibility contract on macOS and must not drive monitoring cadence. Duplicate visibility callbacks are ignored by both AppModel and PortMonitor so view reconstruction cannot interrupt an otherwise scheduled delay.

A refresh interrupts only the monitor's cancellable delay. If a scan is running, requests collapse into at most one pending scan. Sleep cancels the delay and suppresses scans; wake starts one transition period. Stopping the monitor cancels the task, finishes the newest-only stream, and releases the delay continuation.

## Runtime evidence and publication

Listener identity is protocol/address/port plus the strong process identity. `firstDetectedAt`, `lastDetectedAt`, and fingerprint observation time remain fresh evidence but do not constitute a change. Runtime, project, ownership, Docker, managed-service, executable, command, and process-identity changes do.

Cadence relevance is narrower than observation relevance. High-numbered (49152–65535), interface-bound UDP client endpoints remain in snapshots and diffs but do not extend the transition burst; they otherwise kept a busy browser's ephemeral UDP sockets at subsecond monitoring indefinitely. TCP changes, lower UDP ports, and wildcard/loopback UDP changes still accelerate immediately.

AppModel stores the newest snapshot even when it is semantically unchanged. It sends a SwiftUI change only for genuine listener evidence or a thresholded resource change while a monitoring surface is visible. When the first monitoring surface becomes foreground-visible, AppModel publishes the retained hidden snapshot exactly once; repeated `true` callbacks are ignored. CPU changes below one percentage point and resident-memory changes below the larger of one MiB or five percent do not publish.

## Process discovery and cache

Each listener pass launches one formatted TCP `lsof` and one formatted UDP `lsof`; no port-range connection scan is performed. The parser consumes tagged fields and deduplicates stable listener IDs.

Process enrichment validates a native fingerprint containing PID, UID, start time, parent PID, executable path plus device/inode when available, argument digest, and current directory. Cached command, classification, project inference, and Docker association are usable only behind that identity. Entries expire after five minutes, disappear immediately with the process, refresh at most three stale identities per pass, and cap at 512.

## Decoupled background work

- Resource usage: one bounded batched `ps` reader, separately scheduled at 1/5/30/60 seconds for transition/active/background/idle, with immediate PID-set sampling.
- Docker: passive one-list-plus-one-inspect batching, 30-second success cache, exponential unavailable backoff to five minutes, and immediate invalidation after user refresh or a completed Docker mutation.
- Health: one generation per service, cancelled on stop/exit/deletion, suspended across sleep, adaptive healthy/failure cadence, ten-percent jitter, four active batches maximum.
- Logs: stdout/stderr is continuously drained, combined into 50 ms ingress batches, redacted across chunk boundaries, appended/rotated within byte limits, and copied into visible UI only when a lightweight revision changes.
- Persistence: only meaningful state transitions are written. Lifecycle base/context rows and compatibility history are bounded to 5,000 with pruning headroom; visible history fetches at most the newest 100 rows.

## Diagnostics and tracing

`DevBerthPerformance` supplies named `os_signpost` intervals for runtime scan, listener discovery, enrichment, Docker, project inference, diff, persistence, health, log processing, SwiftUI publication, MCP, and lifecycle work. Calls are guarded by OS signpost enablement.

`PerformanceDiagnostics` retains only bounded aggregates: mode/interval, last/average/max scan duration, scan/coalescing counts, cache size/hit rate, Docker duration, health/background counts, and recent warnings. The Settings sheet reads this snapshot once per second only while open. No command, path, process detail, environment value, log text, or secret enters the diagnostics model.

## Safety and trade-offs

Polling remains necessary because the macOS 14 baseline has no public event API that provides complete TCP/UDP listener ownership. Hidden-state freshness is intentionally traded from two seconds to ten and then thirty seconds; known mutations, wake, and manual/MCP refresh are immediate. Cache reuse never grants control authority: every destructive action still performs fresh fingerprint, listener-edge, owner-context, and protected-process validation.

Passive monitoring performs no Compose proof or project-file access and never prevents App Nap. Test/soak launches use in-memory persistence, static or application-owned listeners, unavailable test Docker, and no production socket.
