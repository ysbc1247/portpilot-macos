# GitHub source-release versioning

## Decision

Every pull request merged into `main` publishes one immutable Git tag and one GitHub Release. The tag and release are the canonical version of the source project on GitHub.

The automation lives in [`.github/workflows/release-on-merge.yml`](../../../.github/workflows/release-on-merge.yml). A `push` to `main` is used as the trigger because the merged workflow is guaranteed to exist in the resulting default-branch commit and the commit-to-pull-request API works with merge, squash, and rebase strategies.

## Version format

Versions use `v0.1.<run-number>` while DevBerth remains on its `0.1` source-release line. `GITHUB_RUN_NUMBER` supplies the patch component, so each workflow run has a deterministic version:

- the first successful run is `v0.1.1`;
- a rerun reuses the same version and is idempotent;
- queued merges cannot calculate the same version;
- skipped or failed direct-push runs may leave harmless gaps in patch numbers.

The workflow must not be renamed or deleted without an explicit version-line migration because GitHub owns the run-number sequence. Moving to a new minor or major source-release line requires a reviewed pull request that updates the workflow and this document together.

## Release contents

Each GitHub Release contains:

- the merged pull request number, title, link, and complete description;
- the exact merge commit and link;
- a comparison link from the previous published `v0.1.x` release when one exists;
- an explicit statement that the release is source-only.

PR titles and descriptions therefore form release input, not disposable review text. They must explain what changed, why, user or developer impact, and truthful validation results before merge.

## Safety and failure behavior

The workflow has only `contents: write` and `pull-requests: read` permissions. It does not check out or execute repository code, PR code, or PR-provided commands.

Before publishing, it verifies that the pushed `main` commit is associated with exactly one merged PR. A direct push or a batched multi-PR main update fails visibly and creates no version. PRs must therefore merge sequentially as separate main updates. The workflow creates a lightweight immutable tag at the exact merge commit and refuses to move an existing tag. If tag creation succeeds but release creation is interrupted, rerunning the same workflow completes the missing release instead of allocating another version.

## Scope boundary

GitHub source-release versions are separate from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project. DevBerth does not yet publish signed or notarized binaries, so the automation must not imply that a GitHub source release is an installable app update. Binary-version synchronization belongs to a future signed-distribution design.

## Validation and recovery

After every merge:

1. verify both CI and **Release merged pull request** succeeded for the merge commit;
2. verify the expected tag points at that commit;
3. open the GitHub Release and confirm its PR details and comparison link;
4. if publishing failed, rerun the same workflow rather than creating or moving a tag manually.
