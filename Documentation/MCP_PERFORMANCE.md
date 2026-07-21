# MCP performance

Measured 2026-07-21 on an Apple Silicon MacBook Pro, macOS 26.4, Xcode 26.4/Swift 6.3, Debug with coverage instrumentation. These are local development measurements, not release guarantees.

## Control-plane microbenchmarks

`dev_performance_measure` ran 50 repeated snapshots and disposable project/service/session probes in an in-memory V7 host. Every created entity was removed before the tool returned.

| Path | Measured latency |
| --- | ---: |
| Runtime snapshot minimum / median / maximum | 0.099 / 0.104 / 0.379 ms |
| Project inspect | 0.358 ms |
| Project create | 1.558 ms |
| Project update | 0.589 ms |
| Session capture | 2.934 ms |
| Session diff | 29.507 ms |
| Change-set preview | 1.285 ms |
| Operation preview | 0.942 ms |
| Bounded empty-log retrieval | 28.433 ms |
| Process peak-resident delta across the probe | 2,048,000 bytes |

The result is recorded by `ApplicationControlPlaneTests.testDevelopmentPerformanceCoversRequiredControlPlanePathsWithoutPersistentProbes`. The test also proves the disposable project, service, and session collections are empty afterward.

## Protocol and transport

| Measurement | Result |
| --- | ---: |
| 20 helper process starts + MCP initialization + EOF shutdown | 0.60 s total, about 30 ms/run |
| Peak resident set for the 20-process loop | 16,662,528 bytes |
| Eight simultaneous current-user Unix clients | Passed in 0.036 s in the MCP target run |
| Maximum IPC frame | 4 MiB, rejected before oversized allocation/send |
| Production host activation retry | 40 × 125 ms, bounded to about 5 s |
| Default control deadline | 60 s |
| Operation/change-set deadline | 120 s |

The STDIO transcript test covers clean initialization, production/development discovery, resources, prompts, EOF, and zero non-JSON stdout. The official SDK owns cancellation and graceful shutdown. Progress tokens receive monotonic dispatch (`0/1`) and completion (`1/1`) notifications around host calls.

## Runtime overhead and bounds

MCP creates no second runtime scan or Docker poll. Queries serialize the app's existing snapshot; the helper has no discovery or persistence dependencies. Development discovery adds an `lsof -a -p <owned PIDs>` selector and filters parsed rows before metadata enrichment, preventing unrelated-process work.

Existing runtime measurements remain applicable: about 215 ms wall time per raw TCP/UDP `lsof` pair with roughly 70 listeners, a two-second default refresh, a 30-second metadata cache, and at most three stale metadata refreshes per poll. See [PERFORMANCE_AND_SOAK_TEST.md](PERFORMANCE_AND_SOAK_TEST.md).

Responses, logs, history, errors, discovery leases, operation/change-set leases, ownership evidence, lifecycle events, incidents, audit records, metadata caches, and in-memory service logs are bounded. The Unix client performs blocking socket work on a dispatch queue rather than Swift's cooperative executor, so a client burst cannot starve the tasks that answer it.

## Interpretation and remaining release gate

The measurements demonstrate low control-plane overhead and bounded memory for the exercised paths. They do not replace the existing eight-hour production-monitor soak gate, signed/notarized distribution testing, or workload-specific Docker/large-history measurements. Performance regressions should be compared using the same Debug/coverage configuration and then confirmed in Release.
