# Brand decision: DevBerth

Decision date: 2026-07-21 (Asia/Seoul)

## Decision

The Phase 2 application name is **DevBerth**.

“Dev” keeps the audience explicit: this is a local development utility, not a general system monitor. A “berth” is an assigned place where something is anchored and accounted for. That metaphor matches the product’s core promise: each running service should have an explainable place, owner, project, lifecycle, and restoration definition. The name does not promise automatic repair, cloud orchestration, or broad production operations.

The name is pronounced “dev berth,” is spelled as two familiar words, works as a macOS application name, and supports a future `devberth` CLI without shortening to an unrelated alias.

## Why PortPilot was rejected

The conflict is direct, current, and in the same product category:

- [portpilot.dev](https://portpilot.dev/) is a local-development port, process, routing, and service launcher distributed through npm.
- [PyPI `portpilot`](https://pypi.org/project/portpilot/) is a macOS/Linux port and process manager with stop/force-stop actions.
- [portpilot.app](https://portpilot.app/) is a native local-port tunnelling product.
- Additional GitHub/npm projects use PortPilot for a Swift macOS menu-bar port manager, tunnels, proxies, and local-domain management.
- A marine software company also operates as Portpilot LLC.

Keeping the name would make search results ambiguous, collide with a future CLI/package, and create unnecessary product-identity risk. The rename is therefore a required migration, not a cosmetic preference.

## Candidates reviewed

| Candidate | Result | Reason |
| --- | --- | --- |
| PortPilot | Rejected | Multiple exact-name developer products and packages overlap ports, process management, macOS, launching, routing, and tunnels. |
| StackMoor | Rejected | `stackmoor.com` is an active operating company that includes software/tooling. |
| LocalRig | Rejected | `localrig.com` is an active local-AI/GPU product; a LocalRig coding-agent tool also appears publicly. |
| RunTether | Rejected | The exact compound was sparse, but “Tether” is crowded by current macOS developer tools, including a local coding-agent execution debugger and process-group/worktree tooling. |
| RunClave | Rejected | `runclave.app` is an active agent control-plane product. |
| Runstead | Rejected | Active consulting/software/AI businesses and a consumer product use the name. |
| ServiceYard | Rejected | Existing iOS/service-marketplace applications use the exact name. |
| DevMoor | Rejected | An active software/AI publication and domain use the name. |
| DevBerth | Selected | No relevant exact-name product, package, repository, macOS app, or obvious mark was found in the checks below. |

## DevBerth conflict-review evidence

This is a practical product-name review, not legal trademark clearance. Results are a dated snapshot and domain results are not reservations.

- Exact web and obvious-mark searches returned no relevant DevBerth product. The only indexed exact-text result was an unrelated personal name in a document.
- [GitHub repository search](https://github.com/search?q=devberth&type=repositories) returned zero repository names through the GitHub Search API.
- Exact package lookups returned not found in [npm](https://www.npmjs.com/search?q=devberth), [PyPI](https://pypi.org/search/?q=devberth), and [crates.io](https://crates.io/search?q=devberth). Homebrew had no exact formula or cask.
- Apple’s macOS software search returned fuzzy developer-tool results but no app named DevBerth.
- Registry RDAP checks for `devberth.com`, `devberth.dev`, `devberth.app`, and `devberth.io` returned not found, and the checked names had no A records. Availability can change and must be rechecked immediately before registration.
- Search results did not reveal an obvious DevBerth trademark or developer tool. A professional trademark search remains necessary before commercial release outside this private repository.

## Identity migration contract

The rename must preserve existing local data and keep legacy names only where required for migration compatibility.

| Identity | Legacy | Current |
| --- | --- | --- |
| Product/target/module | `PortPilot` | `DevBerth` |
| Bundle identifier | `com.ysbc.portpilot` | `com.ysbc.devberth` |
| Main SwiftData store | `Application Support/PortPilot.store` | `Application Support/DevBerth.store` |
| Service logs | `Application Support/PortPilot/ServiceLogs` | `Application Support/DevBerth/ServiceLogs` |
| Keychain service | `com.ysbc.portpilot.secrets` | `com.ysbc.devberth.secrets` |
| Defaults domain | `com.ysbc.portpilot` | `com.ysbc.devberth` |
| GitHub repository | `portpilot-macos` | `devberth-macos` only after separate authorization and verified code/data migration |

Migration rules:

1. Never edit the shipped V1 schema in place.
2. Snapshot a legacy store only when the current store does not exist. Use SQLite's online-backup API so committed WAL data is materialized consistently, atomically promote the completed snapshot, roll back a partial destination, and retain the legacy store/WAL/SHM files as a recovery source.
3. Copy the legacy log directory only when the current directory does not exist; never overwrite a current log, and retain the legacy directory as a recovery source.
4. Copy only known non-secret defaults when the corresponding current value is unset.
5. Resolve Keychain references from the current service first, then the legacy service; copy a successfully read legacy value into the current service.
6. Delete a secret reference from both services when the owning configuration is intentionally removed.
7. Preserve legacy identity constants and migration tests until the compatibility window is deliberately retired.
8. Do not rename the private GitHub repository without separate authorization. Verification is necessary but does not itself authorize that external change.

## Migration verification

Verified locally on 2026-07-21 (Asia/Seoul) with Xcode 26.4 and the DevBerth bundle identity:

- A warning-as-error Debug build produced `DevBerth.app` with bundle identifier `com.ysbc.devberth`.
- The full suite passed 40 of 40 tests with zero failures or skips. It includes consistent SQLite snapshotting, corrupt-store rollback, non-overwrite, known-defaults, legacy V1 SwiftData reopening, Keychain fallback, and three real-process integration tests.
- The local legacy store remained present as a rollback source. All 1,278 legacy history UUIDs were found in the migrated DevBerth store; the DevBerth store had 1,494 rows after test-host monitoring added new observations.
- The three pre-existing service-log files were byte-identical in the DevBerth log directory. Three new DevBerth-only test logs did not alter the legacy copies.
- Existing window and split-view defaults were copied to `com.ysbc.devberth`, and the migration marker was set to version 1.
- The local Keychain did not contain a legacy testable secret. Legacy-service lookup, current-service precedence, copy-forward, and dual-service deletion were therefore verified with an isolated Keychain accessor rather than by modifying a user credential.
- A direct runtime launch succeeded under the DevBerth executable and identity, then was stopped cleanly. No validation services remain running.

The GitHub repository remains private under its existing `portpilot-macos` name; renaming it is deliberately pending separate authorization.

## Brand limitations

- “Berth” is a metaphor and must not drive the UI into decorative nautical imitation.
- The name does not replace plain-language product descriptions in onboarding or accessibility labels.
- Domain and trademark results can change. This decision reduces obvious collision risk but does not guarantee registrability.
