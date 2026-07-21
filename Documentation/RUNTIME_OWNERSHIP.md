# Runtime ownership

## Question answered

For a selected listener, ownership answers: what runtime is this, what evidence explains why it is running, which layer controls it, how certain is that conclusion, and which lifecycle actions can be performed safely now?

## Resolution priority

1. A live DevBerth managed-runtime registration with a strong fingerprint and current group evidence.
2. Exact Docker published-port/container metadata, with separately verified Compose context where applicable.
3. Bounded process-lineage and command evidence for Kubernetes port forwards, SSH tunnels, coding agents, supervisors, Homebrew/launchd, IDEs, terminals, and shells.
4. Standalone or unknown host-process observation.

Each `OwnershipConclusion` retains the subject, category, value, confidence, evidence items, detection method, and observation time. Verified means a current authoritative source matched exact identity. Strongly or weakly inferred conclusions remain inference and cannot authorize a controlling-service action.

## Action routing

`OwnerAwareLifecycleRouter` accepts a resolved graph, not a PID. Managed services route through their reviewed process policy. Docker uses one full container ID. Compose uses a freshly proven project/service/files/directory/environment/hash/membership scope. Kubernetes forwards and SSH tunnels may route to the guarded external-process controller only while their exact fingerprint and listener edge still match. Homebrew, launchd, and supervisors remain inspection-only until a verifiable controller contract exists.

Direct process signals require a strong fingerprint, protected-process rejection, exact listener ownership, and fresh checks immediately before TERM or KILL. Restart is never offered to an external observation because command text and a working directory do not reconstruct the original environment or argument boundaries.

## Presentation

Runtime shows a concise ownership label in the table and the full graph in “Why is this running?”: primary category/value/confidence, detection method, process group, action rationale, lineage, and individual observed/inferred evidence. The inspector also separates ownership from restart trust; a verified owner does not imply a verified restart definition.

Implementation details and controller-specific checks live in `Documentation/ARCHITECTURE.md`.

