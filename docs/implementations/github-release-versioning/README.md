# GitHub source-release versioning

## Decision

Every release unit integrated into `main` publishes one immutable Git tag and one GitHub Release. A simple pull request is one release unit. A complete stacked task handled by one `merge` command is also one release unit regardless of how many review shards it contains.

The automation lives in [`.github/workflows/release-on-merge.yml`](../../../.github/workflows/release-on-merge.yml). A `push` to `main` is used as the trigger because the merged workflow is guaranteed to exist in the resulting default-branch commit and the commit-to-pull-request API works with merge, squash, and rebase strategies.

The workflow deliberately keeps one `main` update as its atomic input. Agents consolidate a stack into one release-ready roll-up PR from the fully composed stack tip to `main`, merge that roll-up once, and close the lower shard PRs as incorporated only after the release succeeds. Lower shards remain review records; they are not represented as separate `main` merges or versions.

## Version format

Versions use `v0.1.<run-number>` while DevBerth remains on its `0.1` source-release line. `GITHUB_RUN_NUMBER` supplies the patch component, so each workflow run has a deterministic version:

- the first successful run is `v0.1.1`;
- a rerun reuses the same version and is idempotent;
- queued merges cannot calculate the same version;
- skipped or failed direct-push runs may leave harmless gaps in patch numbers.

The workflow must not be renamed or deleted without an explicit version-line migration because GitHub owns the run-number sequence. Moving to a new minor or major source-release line requires a reviewed pull request that updates the workflow and this document together.

## Release contents

Each simple GitHub Release contains:

- the merged pull request number, title, link, and complete description;
- the exact merge commit and link;
- a comparison link from the previous published `v0.1.x` release when one exists;
- an explicit statement that the release is source-only.

A stack roll-up description additionally links every incorporated shard PR and summarizes the complete stack's changes, reasoning, impact, and observed validation. The release therefore records the whole stack even though only the roll-up PR crosses the `main` boundary.

PR titles and descriptions therefore form release input, not disposable review text. They must explain what changed, why, user or developer impact, and truthful validation results before merge.

## Safety and failure behavior

The workflow has only `contents: write` and `pull-requests: read` permissions. It does not check out or execute repository code, PR code, or PR-provided commands.

Before publishing, it verifies that the pushed `main` commit is associated with exactly one merged PR. A direct push or an ambiguous multi-PR main update fails visibly and creates no version. A simple task crosses that boundary through its PR; a stack crosses it through one roll-up PR. The workflow creates a lightweight immutable tag at the exact merge commit and refuses to move an existing tag. If tag creation succeeds but release creation is interrupted, rerunning the same workflow completes the missing release instead of allocating another version.

## Stack roll-up procedure

1. Identify the complete dependency order and verify every shard's checks and required reviews before changing `main`.
2. Update the tip branch so it contains every lower shard in dependency order.
3. Create or retarget one roll-up PR from that tip to `main`. Its release-ready body links every shard and contains the complete release notes and validation.
4. Merge the roll-up PR once without squashing unless the user explicitly requested a squash.
5. Verify the one CI run, release workflow, tag target, and published release for the roll-up merge commit.
6. Close lower shard PRs as incorporated with a link to the roll-up PR and merge commit. Delete branches only after no open PR depends on them.

This deliberately trades individual GitHub `MERGED` status on lower review PRs for one auditable source version. Their commits, discussions, checks, and review history remain available through the closed PRs and roll-up links.

## Alternatives considered

- **Release every shard:** rejected because one user-requested stack merge would create several source versions for one logical delivery.
- **Delay releases and coalesce nearby merges:** rejected because a timing window cannot prove that a stack is complete and can leave partial deliveries unversioned.
- **Move or replace tags after the final shard:** rejected because published versions are immutable and recovery would become ambiguous.
- **Single roll-up main update:** selected because it preserves commit history, gives the workflow one exact PR and commit, and makes one stack equal one version without timing assumptions.

## Scope boundary

GitHub source-release versions are separate from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project. DevBerth does not yet publish signed or notarized binaries, so the automation must not imply that a GitHub source release is an installable app update. Binary-version synchronization belongs to a future signed-distribution design.

## Validation and recovery

After every simple or roll-up merge:

1. verify both CI and **Release merged pull request** succeeded for the merge commit;
2. verify the expected tag points at that commit;
3. open the GitHub Release and confirm its PR details and comparison link;
4. if publishing failed, rerun the same workflow rather than creating or moving a tag manually.
