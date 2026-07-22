# Historical Phase 2 performance and soak test

> This document preserves the 2026-07-21 pre-audit measurements. The current adaptive design, final Release profiling, and completed soak evidence are in [MONITORING_ARCHITECTURE.md](MONITORING_ARCHITECTURE.md) and [PERFORMANCE_AND_SOAK_RESULTS.md](PERFORMANCE_AND_SOAK_RESULTS.md).

Measurement date: 2026-07-21 (Asia/Seoul)  
Machine: Apple Silicon MacBook Pro, macOS 26.4  
Toolchain: Xcode 26.4, Swift 6.3 toolchain, Swift 5 language mode

## Measurement-era design (superseded)

- Monitoring emits newest-only diff snapshots at a configurable two-second default.
- Process identity metadata has a 30-second cache and a three-stale-PID refresh budget.
- CPU/resident-memory evidence uses one read-only `ps` call per batch of at most 128 unique PIDs.
- Docker listing uses one ID query plus one inspect batch; container and proven Compose contexts have separate bounded caches.
- Unchanged runtime produces no lifecycle/history writes. A listener-change burst becomes one lifecycle batch and one compatibility-history batch.
- Lifecycle rows prune with headroom so the base/context pair stays at or below 5,000 after writes.
- Logs keep 2,000 entries in memory. Disk writes append; overflow rotates to half maximum. Secret redaction spans arbitrary chunks.

## Measured results

| Workload | Result |
| --- | --- |
| 20 raw paired TCP/UDP `lsof` polls | 4.655 s; 232.74 ms/pair; 1.04 s user + 0.69 s system CPU; 7.19 MB max RSS for the benchmark process |
| Six-container Docker Engine list | `docker ps -q --no-trunc` completed in 0.04 s |
| One six-container inspect batch | `docker inspect` completed in 0.03 s; Compose proof is separate and cached for 15 seconds only while path evidence is unchanged |
| 24 listener lifecycle changes | One recorder batch; 0.012 s test duration |
| 40 lifecycle + 40 history rows | Two batch calls, all base/context rows present; 0.077 s test duration |
| Synthetic bounded soak | 250 cycles, 6,250 lifecycle insert attempts, 750 log lines, 6,250 resource rows, and 6,250 inspector projections in 7.321 s; final lifecycle ≤5,000 and logs ≤2,000/profile |
| Bounded disk-log rotation | 5,000 approximately 500-byte lines through a 64 KiB file in 0.549 s; final file ≤64 KiB and known secrets absent from memory and disk |
| UI fixture, 13 s | 0.6% point-in-time CPU; 131,712 KiB RSS |
| UI fixture, 79 s | 2.1% point-in-time CPU during inspection; 154,800 KiB RSS |

The 79-second UI sample shows framework/cache warm-up, not multi-day stability. The repeatable synthetic soak proves configured bounds and batch behavior; the owned integration suite separately cycles high-port fixture launch, signal handling, group descendants, replacements, and cleanup. Docker availability/context changes use deterministic CLI fixtures.

## Harness

Run `Scripts/run_soak_tests.sh`. By default it repeats the 250-cycle soak four times and also runs event batching, chunk-boundary logging, Docker transition/context fixtures, and every harmless integration fixture. Override `DEVBERTH_SOAK_PASSES` for a longer run. Each run uses a fresh in-memory database and temporary log directory; integrations own random high-port fixtures and clean up on failure/cancellation.

The signed local UI-test runner passed four isolated tests covering onboarding safety disclosure, the primary navigation hierarchy, named empty-state actions, Runtime ownership/restart-trust accessibility evidence, Runtime filtering/empty state, and keyboard command-palette routing. The runner emits a non-fatal LLDB version-store diagnostic before launch on this Xcode installation; result bundles nonetheless contain four executed passes. Manual Computer Use independently inspected the final Runtime accessibility tree and screenshot using the same static, in-memory fixture.

## Extended-run acceptance

Before signed release, run at least eight hours with the production monitor and owned fixtures while sampling resident memory every five minutes. Exercise both Runtime layouts, saved filters, inspector/palette/menu actions, log rotation, lifecycle pruning, Docker daemon loss/recovery, and Compose invalidation. Acceptance requires no monotonic post-warm-up memory trend, no orphan fixtures, bounded stores, no stale authorization, and responsive UI.
