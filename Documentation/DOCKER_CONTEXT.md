# Docker and Compose context

Decision date: 2026-07-21 (Asia/Seoul)

## Purpose

DevBerth treats exact Docker Engine association as one-container authority and a verified Compose scope as short-lived service-wide authority. A host listener owned by Docker infrastructure must map to the actual published container port. A Compose project or service name by itself is never enough to run a service-wide command.

## Container observation

Each refresh runs `docker ps --quiet --no-trunc` followed by one `docker inspect` containing every returned ID. The decoded snapshot keeps:

- full container ID, name, image, and state;
- health state when the image declares a health check;
- restart-policy name;
- each host address and port mapped to container port and protocol;
- the canonical Compose labels used by the current container.

`DockerAssociationProvider` caches this result for five seconds and joins it to host listeners by host port plus protocol. The process shown by `lsof` may be Docker infrastructure; lifecycle routing uses the associated container or verified Compose controller and never signals that host PID.

## Compose verification

The context candidate requires these canonical labels:

- `com.docker.compose.project`;
- `com.docker.compose.service`;
- `com.docker.compose.config-hash`;
- `com.docker.compose.project.working_dir`;
- `com.docker.compose.project.config_files`;
- `com.docker.compose.project.environment_file` when environment files were used.

The working directory and every file must be absolute and normalized. Symbolic links, missing paths, non-regular files, and paths whose device/inode cannot be read are refused. File size and modification time are captured with identity so in-place changes also invalidate cached evidence. Compose one-off containers never receive service-wide scope because that could target a different execution; their exact container ID may still receive the one-container Stop/Restart fallback.

DevBerth reconstructs only this explicit command prefix:

```text
docker compose \
  --project-name PROJECT \
  --project-directory WORKING_DIRECTORY \
  --file CONFIG_FILE ... \
  --env-file ENV_FILE ...
```

It then performs two non-mutating proofs:

1. `config --hash SERVICE` must exactly match the container's `config-hash` label.
2. `ps --all --no-trunc --format json SERVICE` must contain the exact full container ID, project, and service tuple.

Successful proof is cached for fifteen seconds while the captured path evidence is unchanged. This prevents duplicate Compose calls during the five-second association refresh without converting old proof into durable trust.

## Mutation rules

Every Compose mutation captures the paths again and repeats both proofs immediately before sending a state-changing command. A mismatch, missing path, replaced file, changed hash, missing exact container, malformed response, unavailable CLI, or nonzero command result refuses the Compose action. If current Engine metadata still supplies one exact full container ID, DevBerth may instead offer container Stop/Restart; this is not Compose authority and cannot remove the container or expand to sibling/dependent services.

Supported operations are deliberately distinct:

- standalone stop: `docker stop CONTAINER_ID`;
- standalone restart: `docker restart CONTAINER_ID`;
- standalone remove: `docker rm --force CONTAINER_ID`;
- unverified-Compose fallback stop/restart: the same one-container commands above, without Remove;
- Compose stop: verified prefix plus `stop SERVICE`;
- Compose restart: verified prefix plus `restart --no-deps SERVICE`;
- Compose remove: verified prefix plus `rm --force --stop SERVICE`.

The UI confirms every mutation and calls permanent removal out separately. Unverified Compose rows expose only the exact-container Stop/Restart fallback. `--no-deps` prevents verified Compose restart from expanding to dependencies, and exactly one verified service argument prevents changes to unrelated services.

## Evidence and testing

The Docker inspector exposes state, health, restart policy, port bindings, project/service, working directory, configuration files, environment files, hash, verification time, and the exact Compose-scope refusal reason. Successful container stop/restart/remove and Compose changes write structured lifecycle events. Failed revalidation writes a redacted safety-refusal event.

Focused tests cover batched inspection, IPv4/IPv6 port bindings, short-lived proof caching, full scope argument reconstruction, configuration-hash mismatch, one-off refusal, exact Compose and container-fallback routing, case-only macOS path spelling, true symlink refusal, and file replacement between inspection and action. Tests use a mock command runner and harmless test-owned files; they do not require or mutate a real Docker daemon.
