# DevBerth engineering rules

## Working Method

### Think Before Coding

- Don't assume. Don't hide confusion. Surface tradeoffs.
- Before implementing:
  - State your assumptions explicitly. If uncertain, ask.
  - If multiple interpretations exist, present them; don't pick silently.
  - If a simpler approach exists, say so. Push back when warranted.
  - If something is unclear, stop. Name what's confusing. Ask.

### Simplicity First

- Use the minimum code that solves the problem. Nothing speculative.
- Do not add features beyond what was asked.
- Do not add abstractions for single-use code.
- Do not add flexibility or configurability that wasn't requested.
- Do not add error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.
- Ask: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### Surgical Changes

- Touch only what you must. Clean up only your own mess.
- When editing existing code:
  - Don't improve adjacent code, comments, or formatting.
  - Don't refactor things that aren't broken.
  - Match existing style, even if you'd do it differently.
  - If you notice unrelated dead code, mention it; don't delete it.
- When your changes create orphans:
  - Remove imports, variables, and functions that your changes made unused.
  - Don't remove pre-existing dead code unless asked.
- Every changed line must trace directly to the user's request.

### Goal-Driven Execution

- Define success criteria and loop until verified.
- Transform tasks into verifiable goals:
  - "Add validation" → write tests for invalid inputs, then make them pass.
  - "Fix the bug" → write a test that reproduces it, then make it pass.
  - "Refactor X" → ensure tests pass before and after.
- For multi-step tasks, state a brief plan:
  - [Step] → verify: [check]
  - [Step] → verify: [check]
  - [Step] → verify: [check]
- Strong success criteria should support independent execution. If criteria remain weak or ambiguous, stop and clarify.

## The `save` Handoff Command

The explicit handoff keyword is `save`, case-insensitive. Treat it as invoked when the user uses `save` as an actionable command, whether alone, as `save: <context>`, or combined with other requested actions such as `save and merge`, `save, push, and merge`, or `please save then merge`. Do not trigger it when the user merely discusses, quotes, or defines the word or this rule. When combined with other actions, run the complete save protocol at the requested point in the sequence; the other actions remain separately authorized by the same message.

When `save` is invoked:

1. Inspect the current branch, commit, Git status, staged and unstaged diffs, running services, and validation state.
2. Update every affected `docs/implementations/*/README.md` so it matches the actual implementation.
3. Rewrite `docs/next-steps/README.md` as the canonical current handoff.
4. Archive the same handoff under `docs/next-steps/history/<YYYY-MM-DD-HHMM>-<slug>.md` so older handoffs are not lost.
5. Include all of the following in the canonical and archived handoff:
   - timestamp and timezone;
   - branch and HEAD commit;
   - concise project state;
   - completed work with exact file paths;
   - observed test and runtime results;
   - current services, URLs, ports, databases, and credentials source;
   - uncommitted, staged, and untracked changes;
   - decisions and their reasoning;
   - known bugs, risks, and incomplete areas;
   - exact next tasks in priority order;
   - exact commands to resume, validate, and stop services;
   - a ready-to-paste prompt for the next Codex session.
6. Update `docs/README.md` if new documentation was added.
7. Run proportionate local validation and record the results truthfully. Never invent or copy stale results.
8. Do not commit, push, merge, deploy, or delete work merely because `save` was invoked. Perform those actions only if the user separately asks.

Create the required documentation directories and files if they do not yet exist.

## Git Workflow

- Every repository-changing task must start on a new task branch.
- Create task branches from an up-to-date `main` branch unless the user names a different base.
- When the user asks for follow-on work after a branch or PR already contains the previous finished work, create the next task branch from that finished branch unless the user explicitly asks to restart from `main`.
- Use a gitflow-style branch prefix that matches the task type. Choose the narrowest accurate prefix:
  - `feat/<short-task-name>` for user-facing features or strategy capabilities.
  - `fix/<short-task-name>` for bug fixes.
  - `docs/<short-task-name>` for documentation, research notes, protocol changes, and agent-rule updates.
  - `data/<short-task-name>` for data layout, metadata, manifests, and mirrored data-root README work.
  - `model/<short-task-name>` for modeling, ML, feature, labeling, training, or evaluation changes.
  - `test/<short-task-name>` for test-only work.
  - `chore/<short-task-name>` for maintenance that does not fit the categories above.
- Do not use `codex/` as a branch prefix in this repository.
- Do not include personal names, usernames, or agent names in branch names, including `theo`; use task-purpose descriptors instead.
- Do not place task commits directly on `main`.
- Git commits should be grouped by coherent reviewable change, not strictly by file count.
- A same-family bulk update may be one commit even when it touches many files. Examples: updating every blog post for a writing-style pass, regenerating paired bilingual post metadata, or changing one content schema across all entries.
- Different implementation layers must still be split into separate commits. For example, JavaScript/TypeScript/Astro/React behavior changes and CSS styling changes should be two commits even when they serve the same user request.
- If one task involves multiple layers, shard the commits by layer or review milestone. Typical layers include content/data, component or application code, styling, tests, documentation, config, and generated artifacts.
- Stage only the files that belong to the current logical commit group.
- Each commit message must clearly name the layer or artifact family and the purpose of the change.
- Git operations do not require additional user permission. Commit, push, branch, and related Git operations may be performed without asking first.
- If a Git operation produces unwanted behavior, the user will revert it manually.
- Never mix unrelated files or unrelated layers in the same commit, even when changes were made during the same task.
- When a simple non-stacked task is finished, push the task branch to the configured private GitHub remote and open a pull request targeting `main`.
- When a task is sharded into a stack, do not apply the simple-task target rule to child shards; each child PR must target its immediate parent branch.
- Do not merge the pull request just because the task is finished. Wait for the user to invoke the merge command.
- Preserve the logical commit-group history when merging. Do not squash unless the user explicitly asks for a squash merge.

## Stacked Pull Request Protocol

- Use stacked pull requests when a task is large enough to split into dependent implementation jobs. The agent must decide whether sharding is appropriate automatically.
- Before editing files on a multi-step task, classify the task as simple or multi-step.
- If the task spans multiple implementation layers, phases, or reviewable milestones, shard it proactively.
- Treat these as mandatory stack triggers:
  - The task changes strategy code, tests, documentation, and generated data mirrors in the same request.
  - The task creates or changes more than one diagnostic, gate family, report family, data contract, or artifact directory.
  - The task includes both implementation and large local artifact generation.
  - The task asks for broad or deep research plus implementation plus documentation.
  - The task is expected to produce more than one coherent review milestone.
- These triggers are binding. Do not treat them as suggestions, and do not continue editing files until the shard plan is reflected in branches and PR targets.
- Cross-layer feature separation is mandatory:
  - Backend DB/data contract, backend API/application code, frontend API types/client wiring, frontend UI, tests, and documentation are separate review milestones when more than one of them is non-trivial.
  - Create stacked branches in dependency order instead of one broad branch.
- Before file edits on any mandatory-stack task, state the shard plan in a brief progress update, including branch name, PR target, and success criteria for each shard.
- Do not create artificial stacks for tiny tasks where one branch and one PR is clearer.

## Stack Branch and PR Convention

- Create the first shard branch from up-to-date `main`, for example `docs/stacked-pr-rules`.
- Open the first shard PR against `main`.
- Create the second shard branch from the first shard branch, not from `main`.
- Open the second shard PR against the first shard branch.
- Continue in dependency order: branch C starts from branch B and PR C targets branch B.
- The branch parent and the GitHub PR base must match the same immediate predecessor.
- Never flatten a stack by branching every shard from `main` or by opening every stacked PR against `main`.
- Before opening or updating a stacked PR, verify its `headRefName` and `baseRefName` preserve the chain.
- If a child PR points at the wrong base, retarget it to the immediate parent branch before continuing.
- Use the same gitflow-style prefixes for stacked branches, choosing the prefix by shard type.
- Preserve logical commit grouping inside every stack branch.
- When a lower stack branch changes, update higher stack branches by rebasing or merging the parent branch into the child branch, resolving only mechanical conflicts without asking.
- Protect the stack dependency graph.
- A branch that is the base of another open pull request must not be deleted, pruned, or auto-deleted after merge until every child pull request has been retargeted away from that branch or merged.
- Before merging or deleting any stacked branch, inspect open pull requests for `baseRefName` and `headRefName` relationships so dependent pull requests are known explicitly.
- If GitHub branch deletion would close or orphan a dependent pull request, disable branch deletion for that merge and keep the parent branch alive until the child pull request is safely retargeted.

## Merge Command Protocol

- When the user says `merge`, treat it as a request to integrate all pull requests for the current task into `main` gracefully.
- Identify every relevant pull request.
- Prefer the PR or PR stack associated with the current branch.
- If there are multiple plausible unrelated PRs, ask the user which task or stack to merge.
- If the task uses a stack, identify the full stack order before merging.
- Treat one user `merge` invocation for one PR stack as one release unit and therefore one `main` update, one immutable version tag, and one GitHub Release.
- Before mutating `main`, inspect every stack PR's status, branch names, bases, reviews, and checks. Stop before the roll-up merge if any required stack PR is blocked.
- Ensure the stack tip contains every lower shard in dependency order, then create or update one release-ready roll-up PR from that fully composed tip to `main`. The roll-up body must link every shard PR and summarize the complete change, reasoning, impact, and observed validation.
- Do not merge lower shard PRs into `main` individually during a stack merge. Merge the roll-up PR once while preserving the stack's logical commits; do not squash unless the user explicitly asks.
- Keep every stack branch alive until the roll-up PR has merged and its release has been verified. Then close the lower shard PRs as incorporated, with a link to the roll-up PR and merge commit; do not misreport those review PRs as individually merged.
- Delete or prune stacked branches only after confirming no open pull request uses the branch as either `baseRefName` or `headRefName`.
- After the roll-up succeeds, switch to `main`, update it from `origin/main`, and report the roll-up PR, every incorporated shard PR, branch, commit range, and single published version.
- If GitHub or Git reports conflicts, resolve them locally when the resolution is mechanical and low-risk.
- If a conflict requires a product, strategy, data, or research judgment, stop and ask the user what to keep instead of guessing.
- If checks are failing or required review is missing anywhere in the stack, report the blocker, leave the roll-up unmerged, and do not force-merge unless the user explicitly instructs that exact action.

## GitHub Versioning and Release Protocol

- Treat the immutable `vMAJOR.MINOR.PATCH` Git tag and corresponding published GitHub Release as the canonical source-project version.
- Every simple PR merged into `main`, or every complete PR stack integrated through one roll-up PR, must produce exactly one version through `.github/workflows/release-on-merge.yml`. Do not disable, bypass, rename, or delete this workflow without an explicit version-migration decision and matching documentation update.
- Keep repository changes on pull requests. A direct push to `main` is a workflow violation, creates no release, and must be corrected through the normal PR path rather than manually inventing a version.
- A simple PR is one release unit. A stack handled by one `merge` command is also one release unit regardless of shard count: merge only its release-ready roll-up PR into `main`, then close the lower shard PRs as incorporated.
- Never implement stack release batching with timing windows, delayed jobs, movable tags, or multiple sequential `main` merges. The single roll-up `main` update is the atomic release boundary.
- While the project remains on the `0.1` source-release line, use `v0.1.<GITHUB_RUN_NUMBER>`. The workflow run number is the patch component so queued merges receive unique deterministic versions and reruns remain idempotent.
- Never move, reuse, overwrite, or delete a published version tag. If publishing is interrupted after tag creation, rerun the same workflow so it completes that tag's missing release.
- Before merging, make the PR title and body release-ready. The body must truthfully state what changed, why, user or developer impact, and observed validation; do not merge placeholder or stale release input.
- Every simple release must identify its merged PR. Every stack release must identify the roll-up PR and every incorporated shard PR. Both must preserve release-ready change details, link the exact merge commit, and compare with the previous source release when one exists.
- After every simple or roll-up merge, verify CI and the release workflow succeeded for the one merge commit, verify the one new tag targets that commit, and inspect the published release details before reporting the task complete.
- Keep GitHub source versions separate from the Xcode `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` until signed binary distribution is designed. Never claim that a source release contains an installable, signed, notarized, or automatically updatable app unless those artifacts were actually produced and verified.
- Record version-line changes, release-automation decisions, alternatives, and recovery procedures in `docs/implementations/github-release-versioning/README.md`; keep this section prescriptive.

## DevBerth Engineering Rules

- Target macOS 14 or newer with SwiftUI and Swift Concurrency. Use AppKit only when a native SwiftUI API cannot provide the required behavior.
- Keep sources compilable with the repository's Xcode 16.4 CI baseline. Do not reference newer-SDK declarations merely behind `#available`; use a baseline declaration or a narrowly reviewed runtime symbol boundary when the underlying macOS 14 capability exists.
- Keep transient runtime models in `DevBerth/Domain` and SwiftData records in `DevBerth/Persistence`; never persist live `Process` objects.
- Keep `ObservedListener` and `ObservedProcess` as operating-system evidence, and `ManagedServiceConfiguration` as durable user-authored intent. Do not make an observation manageable or restartable by adding configuration flags to it.
- Present an exact expected-port match as observed managed-service activity, never as DevBerth control or restart authority. An explicitly confirmed Stop may resolve and route that current observation only after fresh full-fingerprint, listener-edge, and owner-context revalidation; refuse protected processes and unverifiable controller contexts. Start and restart still require the exact verified managed-service definition.
- Project bulk Start must preserve the full dependency graph while launching only stopped definitions; bulk Stop must preserve reverse dependency order while attempting every live DevBerth-controlled runtime and explicitly confirmed observed owner, deduplicated by the exact routed owner. One failed target must not prevent later stop attempts. Publish per-project progress and an exact aggregate terminal result, prevent overlapping actions, and refresh runtime evidence after the attempts finish.
- UI code must depend on service protocols. It must not invoke `Process`, `lsof`, `ps`, `kill`, Docker, or a shell directly.
- Keep the primary product navigation ordered as Runtime, Projects, Sessions, Managed Services, History, Docker, and Settings. Runtime owns the listener/process overview, table and project-grouped modes, saved filters, multi-selection, and contextual inspector; do not reintroduce a separate summary dashboard with conflicting state.
- Every dismissible custom sheet or palette must handle Escape with onExitCommand and expose a cancel/close action using the native cancelAction shortcut. Suppress dismissal only while an in-flight mutation must remain atomic; the mandatory first-run guide is intentionally non-dismissible.
- Treat every hosted test launch as a production-data isolation boundary: use an in-memory SwiftData configuration, skip product-data migration, disable the production control socket, and use empty or test-owned listener/resource fixtures. UI tests inject only static fixtures. Tests must never enumerate, launch, signal, or mutate an unrelated user process or container.
- Invoke trusted tools with an executable URL and discrete argument array through `CommandRunning`. Only explicitly user-authored launch profiles may use a login shell.
- Run trusted tools non-interactively with standard input closed and drain stdout and stderr continuously while they execute. Runtime project inference must remain bounded and metadata-only; never open or parse an observed process's project files during a listener refresh.
- A destructive process action must revalidate the captured `ProcessFingerprint` (PID, UID, executable path and file identity when available, start time, command digest, and parent PID) and the exact listener-to-process edge immediately before every signal. Revalidate again before force escalation; never treat PID existence alone as authority or weaken protected-process checks to make an action succeed.
- Launch every application-managed service in a dedicated POSIX process group with inherited signal masks cleared and termination dispositions restored. Capture its strong leader fingerprint only after it remains mutually identical across a bounded post-spawn stability window; two immediate pre-exec samples are insufficient. Group signals are authorized only by a live managed-runtime registration plus a revalidated known member; never group-signal an externally observed process or an escaped descendant.
- Resolve listener ownership through `RuntimeOwnershipResolving` and route lifecycle requests through `OwnerAwareLifecycleRouting`. A PID, inferred ancestor, executable prefix, parent PID 1, or service-manager resemblance never authorizes a controlling-service action. Until an exact Homebrew formula or launchd domain/label is verified, a strong same-user listener owner may expose only guarded instance Stop/Force Stop with full fingerprint and listener-edge revalidation; it receives no manager-level action or inferred restart authority. Root and protected processes remain refused, and DevBerth must not add privilege elevation to weaken that boundary.
- Authorize a Compose service mutation only from canonical Docker labels for project, service, working directory, configuration files, environment files, and configuration hash; require non-symlink path identities, an exact `docker compose config --hash` match, and exact container membership immediately before mutation. Use explicit `--project-name`, `--project-directory`, repeated `--file`/`--env-file`, and one service argument; never guess context or control a one-off container as a service. If Compose scope verification fails but the Engine association still provides an exact full container ID, Stop and Restart may fall back only to that container; never expose Remove through this fallback or target a host PID.
- A DevBerth-managed Stop sends `SIGTERM` to the revalidated registered process scope, waits for the configured timeout, then captures and revalidates a fresh ownership anchor before any `SIGKILL` escalation. Report failure if the same scope remains live; never signal an escaped descendant or a replacement identity.
- Keep passive Docker and listener refreshes inspection-only: they may read engine container metadata and published ports, but must not perform Compose control-scope verification or block runtime observation on project-file access.
- Every ownership conclusion must retain an explicit confidence, detection method, evidence source, and observation time. Present inferred evidence as inferred, keep lineage traversal bounded and cycle-safe, and cap continuously recorded ownership evidence.
- Store secret values only through `SecretStoring` (Keychain in production). SwiftData may contain opaque secret references, never secret values.
- Treat secret-like environment names as Keychain-only. Profile edits must stage Keychain mutations before persistence, roll them back when validation or persistence fails, remove only references no remaining profile uses, and give duplicated profiles independent references.
- A managed service is verified restartable only when a successful isolated start/readiness/controlled-stop result exists for the exact current `ManagedServiceConfigurationDigest`. All ordinary, project, favorite, menu-bar, and automatic launches must enforce this gate; only the validation runner may bypass it.
- Treat process-running, required-listener-open, service-ready, and service-healthy as separate runtime facts. Never infer health from PID existence, and emit lifecycle evidence only when a source actually observes the transition.
- Route managed launch, stop, exit, health, and automatic-restart transitions through `RuntimeLifecycleObserving`. Lifecycle metadata must be structured, bounded, and secret-safe; a check failure may persist its reviewed failure message, never an HTTP body, command output, or environment value.
- Prune lifecycle base records and V5 context sidecars as one complete bounded set. History presentation must show a stable, explicitly refreshable snapshot of at most the newest 100 records per timeline and only the sidecars for event IDs on that page; do not bind the table directly to high-frequency history writes or keep an empty incident inspector mounted when no related incident is selected.
- Automatic restart must re-check exact restart trust, cancel stale health monitors, apply bounded exponential backoff, and stop after the rolling crash-loop limit. An intentional stop never qualifies for automatic restart.
- Ownership evidence, lifecycle details, discovery metadata, and workspace-session snapshots may store identifiers and redacted explanations, never secret values or raw environment values.
- Run project discovery only against a user-selected root through `ProjectDiscoveryAdapting`. Adapters must be non-recursive, side-effect-free, bounded to regular non-symlink files, and must return unreviewed candidates; discovery must never evaluate or execute project commands.
- Treat `devberth-runtime.json` as a versioned interchange format, not trust evidence. Export no secret values or Keychain reference UUIDs, reject secret-like plaintext environment fields, and require imported definitions to pass the normal review and exact validation gates.
- Workspace sessions may contain only managed-service expectations and redacted evidence. Every restore must re-run fresh listener, definition, Keychain, restart-trust, port, and dependency preflight; start in dependency layers, roll back only services started by that restore, and never stop unmanaged or previously running services as rollback.
- Keep verified process metadata separate from inferred classification or relaunch suggestions in the UI and domain models.
- Add parser fixtures and tests when changing command formats. Tests must use mocks and must never terminate real user processes.
- Collect resource usage through one bounded, batched `ps` reader per runtime refresh. Resource values are transient evidence; unavailable or malformed rows render as unavailable and never affect ownership or lifecycle authority.
- Localize user-facing strings with `String(localized:)` or `LocalizedStringKey`; keep business-logic errors actionable and non-secret.
- Treat `ProductIdentity` and `ProductDataMigrator` as the compatibility boundary for the PortPilot-to-DevBerth rename. Never remove legacy identifiers or reset user storage without a tested migration and an explicit compatibility decision.
- Treat `DevBerthSchemaV1` through `DevBerthSchemaV7` as shipped, immutable schemas. Add a new version and migration stage for later persistence changes, and validate from a previous-version fixture. V5 owns lifecycle context and incident summaries; V6 owns managed-service check sidecars; V7 owns control-plane revisions, organization records, and MCP audit metadata.
- Keep `ApplicationControlPlane` as the sole MCP command/query boundary. The `devberth-mcp` executable is a protocol adapter only: it must not import SwiftUI or SwiftData, run discovery, invoke lifecycle tools directly, read Keychain values, or implement a second domain rule.
- Keep production runtime monitoring, Docker inspection, persistence writes, logs, and secret resolution in the app-owned control host. Local IPC must remain a current-UID Unix socket with a `0700` parent, `0600` socket, bounded length-prefixed frames, deadlines, and matching production/development handshakes; do not add a production network listener.
- MCP mutations must use stable entity IDs and optimistic revisions. Runtime mutations must use stable listener IDs plus fresh fingerprint/ownership evidence. Destructive actions require an unexpired, single-use `operation_preview`; coordinated changes require an unexpired, single-use `change_set_preview`.
- Keep development MCP mode Debug-only, in-memory, and scoped to application-owned fixtures. Release tool discovery and argument parsing must exclude every `dev_*` capability and reject `--development`.
- Treat `DevBerthControlContracts/CapabilityRegistry.swift` as the executable MCP parity contract. Any GUI/control capability, schema, annotation, approval, resource, prompt, error, or build-availability change must update registry tests and the corresponding `Documentation/MCP_*.md` reference.
- Prefer the installed DevBerth MCP resources and tools for runtime, project, service, session, port, Docker, history, and safe-settings work. If a needed MCP capability is absent, unreliable, or awkward, record the exact friction and improve the shared registry/control-plane/helper/docs/tests instead of silently bypassing it with a parallel implementation.
- Regenerate `DevBerth.xcodeproj` with `xcodegen generate` after changing `project.yml`.
- Validate locally with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DevBerth.xcodeproj -scheme DevBerth -destination 'platform=macOS' test`.
- After every code modification and proportionate validation, run `Scripts/build-and-install-app` before handoff. It must refresh the stable `/Applications/DevBerth.app` and `~/Library/Application Support/DevBerth/bin/devberth-mcp` locations from the same Release build; never leave the user pointing at a stale DerivedData bundle.
- Full Disk Access is always user-controlled: DevBerth may open System Settings directly to the Full Disk Access pane, but it must never claim to grant or verify that permission automatically. Use `Scripts/build-and-install-app --open-full-disk-access` when the task explicitly includes the permission handoff.
- Architectural boundary or contract changes require matching updates to this file and `Documentation/ARCHITECTURE.md` (or the relevant `docs/implementations/*/README.md`).
