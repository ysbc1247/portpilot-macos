# Runtime lifecycle intelligence

Decision date: 2026-07-21 (Asia/Seoul)

## Truth model

DevBerth treats these as independent observations:

1. The managed process scope exists.
2. Required listeners are open.
3. The service is ready for dependents.
4. Configured health criteria are passing.

A PID is never health evidence. A required listener can make a service ready when no further check is configured. When checks exist, the runtime remains in waiting-for-readiness until they pass. A later failure changes health to degraded without falsely claiming the process stopped.

`RuntimeLifecycleTracker` is the ordered state owner. `ManagedProcessLauncher` reports process identity, controlled-group lifetime, stop intent, and exit result. `LaunchCoordinator` reports preflight, listener readiness, reviewed checks, and ongoing health. `AppModel` consumes snapshots and never manufactures healthy state.

## Check contract

Supported criteria are:

- expected TCP listener;
- HTTP status and optional response text;
- absolute executable plus discrete arguments;
- file existence;
- Docker health status for a validated container identity;
- readiness of another managed service.

Every `ServiceCheckConfiguration` stores timeout, interval, retry limit, initial delay, success criteria, and a reviewed failure message. HTTP bodies and command outputs are evaluated transiently and are not copied into persisted failures. Commands discovered from a project or process remain inert until the user reviews and validates the managed-service definition.

Required listener checks use the profile startup timeout. Additional checks run sequentially at startup and are sampled after launch at the shortest configured interval. Health events are edge-triggered: one degraded event on a passing→failing transition and one recovery event on failing→passing. The monitor is cancelled on user stop, failed launch cleanup, or unexpected process exit.

## Runtime and event evidence

Each runtime has a stable runtime UUID, the strong leader fingerprint, start time, optional parent-runtime relationship, current lifecycle and health states, listener IDs, exit result, bounded lifecycle-event IDs, and log-metadata references. Runtime records are upserted by runtime ID; a new execution receives a new ID.

The frozen V2 lifecycle base stores identity, category, outcome, summary, safe details, and primary relationships. V5 adds a one-to-one context sidecar for severity, source, trigger, fingerprint, listener, duration, and related-event IDs. The production store retains the newest 5,000 base/context pairs and prunes every 100 writes. Incident summaries retain the newest 250.

Observed listener discovery, change, and release events include only port, protocol, process name, inferred project label, stable listener ID, and process fingerprint. They exclude command lines, environment values, HTTP bodies, and logs.

## Incident summaries

Incident summaries are deterministic. The summarizer orders the latest eight service events plus the terminal event, removes duplicate IDs, and uses the terminal event as the cause. Suggested action is selected from the verified source category (readiness, health, restart policy, or general lifecycle). Each step links back to an event ID.

This is explainable rule-based diagnostics, not AI. Redacted logs remain available separately for human inspection and are never silently promoted into a causal claim.

## Automatic restart

`never`, `onFailure`, and `always` are evaluated against the actual exit result and intentional-stop flag. An intentional stop never restarts. Before every automatic launch, DevBerth requires a successful exact validation for the current launch definition.

Attempts use bounded exponential backoff: 1, 2, then 4 seconds. No more than three attempts are allowed in a rolling 60-second window. A failed startup can consume the next bounded attempt; a trust refusal stops immediately. Scheduling, failure, success, and the final crash-loop refusal are lifecycle/history evidence.

## Current limitations

- Runtime log metadata is linked through the managed-service log stream; per-runtime persisted log segment identifiers are reserved but not yet populated.
- Check execution is sequential. This favors deterministic evidence; independent check parallelism can be added only with stable ordering and cancellation semantics.
- Retention is currently count-based. The settings UI exposes legacy history duration; a unified lifecycle count/time policy remains part of product-quality work.
- Incident summaries use lifecycle evidence and safe failure guidance. They do not parse arbitrary stderr into causal facts.
