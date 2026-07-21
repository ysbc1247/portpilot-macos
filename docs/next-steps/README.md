# Current handoff — stacked release and save command

## Timestamp

- Captured: 2026-07-22 05:52:18 KST (+0900)
- Handoff point: after the rule changes and review PRs were published, before the separately requested roll-up merge

## Git state

- Repository: `/Users/theokim/Documents/github/portpilot-macos`
- Branch: `docs/loosen-save-command`
- HEAD: `2e4837e4c07d320c535e4b240a05b35ba703f902` (`docs: accept combined save commands`)
- Base commit on `main`: `0f82c82a70d8d056dc0e82e32456b80c93e84d0c`
- Parent task commit: `f09be010315cfce542153f64dd944013b1b2a5af` (`docs: make stacked merges one release`)
- Latest published source release before this merge: `v0.1.4`
- Pull requests:
  - [#17](https://github.com/ysbc1247/portpilot-macos/pull/17) `docs/stacked-release-version` → `main`; CI passed and PR is clean/mergeable.
  - [#18](https://github.com/ysbc1247/portpilot-macos/pull/18) `docs/loosen-save-command` → `docs/stacked-release-version`; CI was in progress at capture time.

## Concise project state

This is a documentation-only two-PR stack. It changes the durable agent workflow so one user-requested stack merge produces one roll-up `main` update and one source version, and so actionable combined commands such as `save and merge` run both actions in the requested order. No DevBerth production code, Xcode project setting, persistence schema, MCP contract, or installed binary changed.

The current save was invoked by the user's actionable combined command. This handoff intentionally records the pre-merge state; the same message separately authorizes the roll-up merge after the handoff is committed and validated.

## Completed work

- `AGENTS.md`
  - Replaced sequential per-shard `main` merges with one release-ready roll-up PR for a complete stack.
  - Defined one stack merge command as one release unit, one `main` update, one immutable tag, and one GitHub Release.
  - Broadened `save` invocation to actionable combined commands while keeping discussion and quotation non-operative.
- `docs/implementations/github-release-versioning/README.md`
  - Recorded the roll-up decision, exact procedure, consequences, alternatives, and recovery behavior.
- `docs/implementations/agent-workflow/README.md`
  - Recorded operative and non-operative save examples, combined-command ordering, reasoning, and authorization boundary.
- `docs/README.md`
  - Added the agent-workflow decision record to the documentation index.
- `docs/next-steps/README.md`
  - Rewritten as this canonical handoff.
- `docs/next-steps/history/2026-07-22-0552-stacked-release-save-command.md`
  - Archived this same handoff.

## Observed validation

- `git diff --check` passed for both documentation commits.
- A repository search confirmed `AGENTS.md` and both implementation records use the same release-unit, roll-up, actionable-save, and combined-command model.
- PR #17 GitHub CI completed successfully.
- PR #18 GitHub CI was still running at 2026-07-22 05:51 KST; do not merge until it succeeds.
- No new local `xcodebuild` run was performed because this stack changes Markdown only.
- Product baseline from the immediately preceding `v0.1.4` task: the complete local suite passed 187/187, the final `main` CI run succeeded, and the Release build was installed successfully.
- Installed versions observed during this save:
  - `/Applications/DevBerth.app`: `0.1.0`
  - `~/Library/Application Support/DevBerth/bin/devberth-mcp`: `0.1.0`

## Runtime and service state

DevBerth's production MCP was used for this snapshot.

- DevBerth app: running as PID 44234.
- Monitoring: enabled at a two-second interval.
- MCP: enabled, production mode, protocol/schema version 1, 82 production tools.
- Runtime snapshot: 41 listeners.
- Configured projects: Cloud Computing, Pharmacy Project, Postgres Consistency Lab, and Theokim Blog.
- Managed-service definitions: 11.
- Workspace sessions: none.
- Docker: available, version 29.3.0.
- Docker containers: seven running.
- Verified Compose projects:
  - `pharmacy-local`: two of two service contexts verified.
  - `postgres-consistency-lab`: one of one service contexts verified.
  - `sanggwon-cloud-backend`: two of two service contexts verified.

### Current project endpoints

| Project/service | URL or port | Observed state |
| --- | --- | --- |
| Cloud backend API | `http://127.0.0.1:8081` | Running `sanggwon-api` container |
| Cloud PostgreSQL | `127.0.0.1:5433` | Running `sanggwon-postgres` container |
| Cloud frontend | `http://127.0.0.1:5176` | Node listener observed |
| Cloud same-origin gateway | `http://127.0.0.1:4173` | Node listener observed |
| Pharmacy backend | `http://127.0.0.1:18080` | Healthy Compose container |
| Pharmacy PostgreSQL | `127.0.0.1:15432` | Healthy Compose container |
| Pharmacy frontend | `http://127.0.0.1:15173` | Node listener observed |
| Pharmacy Mobile Metro | `http://127.0.0.1:18081` | Node listener observed |
| Consistency Lab PostgreSQL | `127.0.0.1:54329` | Healthy Compose container |
| Consistency Lab API expectation | `http://127.0.0.1:8080` | Port is held by unassociated `thirsty_knuth`; not confirmed as the managed API |
| Consistency Lab dashboard expectation | `http://127.0.0.1:5173` | Port is held by unassociated `mystifying_jackson`; not confirmed as the managed dashboard |
| Theokim analytics dashboard | `http://127.0.0.1:5174` | Node listener observed |
| Theokim tech blog | `http://127.0.0.1:5175` | Node listener observed |

### Databases and credential sources

- PostgreSQL listeners are present on ports 5433, 15432, and 54329 as listed above.
- Managed profiles currently expose no opaque secret references; no credential values were read or recorded.
- DevBerth production secret values, when configured, are sourced through Keychain-backed `SecretStoring`, never SwiftData or this handoff.
- Compose/project credentials remain owned by their project configuration outside DevBerth; this task did not inspect them.
- GitHub CLI authentication is sourced from the local macOS keyring; no token value is recorded.

## Working-tree state

Immediately before writing this handoff:

- staged changes: none;
- unstaged changes: none;
- untracked changes: none;
- the branch matched `origin/docs/loosen-save-command`.

This save creates the canonical and archived handoff files listed above. They are the only save-generated working-tree changes and must be committed on the current branch before the authorized roll-up merge.

## Decisions and reasoning

1. **One stack equals one version.** A fully composed stack tip crosses `main` through one roll-up PR. This preserves commits while giving the existing release workflow one exact PR and commit.
2. **Do not coalesce releases by time.** Delays cannot prove stack completeness and can leave partial work unversioned.
3. **Lower shard PRs close as incorporated.** They retain checks, reviews, discussions, and commit history but are not falsely reported as individually merged.
4. **Actionable intent invokes save.** `save and merge` and equivalent imperative combinations run the handoff; discussion and quotation do not.
5. **Combined-command order is binding.** This handoff is captured before the merge because the user requested save, then merge.
6. **No product rebuild for Markdown-only changes.** The installed app remains the already validated `v0.1.4`-era Release build.

## Known bugs, risks, and incomplete areas

- PR #18 CI must finish successfully before roll-up.
- The previous task exposed an intermittent CI harness issue:
  `ApplicationControlPlaneTests.testDevelopmentAcceptanceSuiteExecutesAllIsolatedScenarios` hung during an extra historical-commit replay until the 20-minute job timeout. The original PR checks and final `main` CI succeeded; no production failure was observed.
- Ports 8080 and 5173 are occupied by unassociated Docker containers, so Consistency Lab API/dashboard activity is not confirmed as the reviewed managed definitions.
- The roll-up model intentionally means PR #17 will be closed as incorporated rather than receiving GitHub's `MERGED` state.
- No service was started, stopped, or mutated for this documentation task.
- Arbitrary observed processes still require a reviewed launch definition for reliable restart; exact stop authority does not invent a restart command.

## Exact next tasks

1. Validate these two handoff files are identical and `git diff --check` passes.
2. Commit the save artifacts on `docs/loosen-save-command` and push the branch.
3. Update PR #18's body to include the save validation and wait for its CI check to succeed.
4. Convert PR #18 into the one release-ready roll-up:
   - ensure its tip contains PR #17;
   - retarget it to `main`;
   - update its body to link and summarize PRs #17 and #18;
   - verify it is clean, mergeable, and green.
5. Merge PR #18 once with merge-commit history preserved.
6. Update local `main`, verify exactly one new release workflow run and tag target the roll-up merge commit, and inspect the release notes.
7. Comment on and close PR #17 as incorporated into the roll-up merge; do not claim it was individually merged.
8. Confirm no open PR depends on either stack branch before optional branch cleanup.

## Exact resume, validation, and stop commands

### Resume

```bash
cd /Users/theokim/Documents/github/portpilot-macos
git switch docs/loosen-save-command
git pull --ff-only origin docs/loosen-save-command
git status --short --branch
gh pr view 17 --json number,state,headRefName,baseRefName,mergeable,mergeStateStatus,statusCheckRollup,url
gh pr view 18 --json number,state,headRefName,baseRefName,mergeable,mergeStateStatus,statusCheckRollup,url
```

### Validate

```bash
git diff --check main...HEAD
rg -n -i 'one release unit|roll-up PR|save and merge|actionable command|combined commands' AGENTS.md docs/implementations
gh pr checks 17
gh pr checks 18
cmp docs/next-steps/README.md docs/next-steps/history/2026-07-22-0552-stacked-release-save-command.md
```

### Prepare and perform the authorized roll-up merge

```bash
gh pr edit 18 --base main
gh pr view 18 --json number,state,headRefName,baseRefName,mergeable,mergeStateStatus,statusCheckRollup,url
gh pr merge 18 --merge
git switch main
git pull --ff-only origin main
```

Update PR #18's release-ready body before running the merge command. After the release succeeds, comment on and close PR #17 as incorporated.

### Stop services

This task started no service or database, so there is no task-owned service to stop. Do not terminate the unrelated project services listed above. To stop only the DevBerth application if explicitly desired:

```bash
osascript -e 'tell application "DevBerth" to quit'
```

To reopen it:

```bash
open -a DevBerth
```

## Ready-to-paste prompt for the next Codex session

> Resume the DevBerth stacked-release/save-command task from `docs/loosen-save-command`. Read `AGENTS.md`, `docs/next-steps/README.md`, and the two implementation decision records. Confirm the save files are committed and pushed, wait for PR #18 CI, then use PR #18 as the single roll-up PR to `main`. Its release body must link PRs #17 and #18. Merge PR #18 exactly once, verify one new tag and GitHub Release target its merge commit, then comment on and close PR #17 as incorporated. Do not merge PR #17 separately. Keep the working tree clean and report the known historical MCP acceptance-test replay timeout truthfully.

