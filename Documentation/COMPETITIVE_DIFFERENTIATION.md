# Competitive differentiation

## Category and overlap

DevBerth is a local-development runtime explainer and guarded service controller for macOS. It overlaps established categories without replacing them:

- Apple Activity Monitor is a general process/resource monitor and can quit or force-quit a process; it is not organized around listener ownership, reviewed restart definitions, project dependency topology, or session restore ([Apple guide](https://support.apple.com/guide/activity-monitor/welcome/mac)).
- Raycast Port Manager lists open ports, process metadata, menu-bar items, copy actions, and TERM/KILL operations. That is the closest port-focused overlap ([Raycast Store](https://www.raycast.com/lucaschultz/port-manager)).
- Docker Desktop provides a broad dashboard for containers, images, volumes, builds, Kubernetes resources, logs, and quick container/Compose actions ([Docker documentation](https://docs.docker.com/desktop/use-desktop/)).
- OrbStack is primarily an environment for running containers, Kubernetes, and Linux machines, including automatic domains and file/SSH/VPN conveniences ([OrbStack documentation](https://docs.orbstack.dev/)).
- IDE task runners, package-manager scripts, Procfile tools, and Compose orchestrate definitions the user already knows; they generally do not explain unrelated host listeners or unify their owner evidence.

## Intentionally different

DevBerth’s center is not “kill port” or “run containers.” It separates observation, ownership, management, and restart trust. A PID/listener is not assumed to be the correct lifecycle layer. A discovered command is not assumed reproducible. Docker Compose control is withheld until exact project context is proven. Host processes, managed groups, standalone containers, and Compose services can appear in one Runtime view while keeping their control contracts distinct.

The ownership graph matters because stopping the visible PID can be wrong: a supervisor may respawn it, a container owns it, or a child rather than the launcher owns the socket. Restart trust matters because an observed command line omits reliable argument boundaries, environment, secrets, shell initialization, and readiness. Lifecycle history matters because “running now” does not explain a failed dependency, readiness delay, health degradation, exit, or bounded automatic restart. Project sessions matter because developers often need a reviewed multi-service state, drift preview, dependency order, and scoped rollback—not merely a saved list of ports.

## Features intentionally not copied

DevBerth does not provide a container engine/VM, image registry/browser, Kubernetes cluster, general system profiler, arbitrary one-click PID killer, cloud account, team sync, remote deployment, embedded AI assistant, or automatic execution of discovered scripts. It does not attempt automatic local domains in Phase 2; the alias router remains deferred behind a separate exposure and routing review.

## Remaining limitations

macOS can withhold other-user/system metadata. Homebrew, launchd, and supervisor resemblance remains inspection-only without exact controller proof. A validated managed service can still run faulty or malicious application code. Session restore covers managed intent, not arbitrary terminal state. Docker features depend on the configured CLI/daemon. Distribution is not yet Developer-ID signed, notarized, or auto-updating.

