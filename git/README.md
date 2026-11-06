# Git Field Guide

Practical Git commands for day-to-day branch work. Examples assume a feature branch named `test-branch` and a remote named `origin`; replace those with your branch and remote as needed.

## The Basic Model

- A **commit** is a snapshot with a parent commit (or parents).
- A **branch** is a movable name pointing to a commit.
- `HEAD` identifies the commit currently checked out. Usually it points to the tip of the current branch; in a detached-HEAD state it points directly to a commit instead.
- The **working tree** contains your checked-out files. The **index** (staging area) contains the changes that will go into the next commit.
- `origin/main` is your local reference to the latest `main` branch state fetched from `origin`. It does not update until you fetch.

## Start a Work Session

Check your branch and working tree before changing anything:

```bash
git status -sb
git branch --show-current
```

For example:

```text
## main...origin/main
?? git/
```

`## main...origin/main` means the current local branch is `main` and it tracks `origin/main`. With no ahead/behind counts, the branches are aligned based on the last fetch; run `git fetch origin` to check the latest remote state. `?? git/` means the `git/` directory is untracked and has not been added to Git.

Fetch remote updates, then check whether your feature branch is ahead of or behind its upstream:

```bash
git fetch origin
git status -sb
```

In the status output:

- `ahead N` means you have commits not on the upstream branch.
- `behind N` means the upstream branch has commits you do not have locally.
- No ahead/behind counts means the branch and its upstream are in sync.

If the feature branch is behind `origin/main`, replay its commits on top of the latest main:

```bash
git rebase origin/main
```

This assumes your feature branch should be based on `main`. If it tracks a different base branch, rebase onto that branch instead. Rebasing rewrites your feature commits; do not rebase a branch that other people are actively using without coordinating.

## Commit and Push Changes

```bash
git status --short          # see changed files
git diff                    # review unstaged changes
git add -p                  # interactively stage selected hunks
git diff --cached           # review staged changes
git commit -m "Describe the change"
git push -u origin test-branch # first push sets the upstream
```

On later pushes, `git push` is usually enough. If you have amended or rebased commits that were already pushed, update the remote branch with:

```bash
git push --force-with-lease origin test-branch
```

`--force-with-lease` protects against overwriting remote changes you have not fetched. Fetch and inspect the branch first if the push is rejected. A rebase or amend does **not** require a force-push when the rewritten commits have never been pushed; use a normal push in that case.

## Fetch and Rebase Workflow

```bash
git fetch origin
git status -sb
git rebase origin/main
git log --oneline origin/main..HEAD
git log --oneline HEAD..origin/main
git status -sb
```

- `git log origin/main..HEAD` shows commits on your current branch that are not in `origin/main`.
- `git log HEAD..origin/main` shows commits in `origin/main` that are not in your current branch. After rebasing onto the latest `origin/main`, this should be empty.
- Before pushing a rewritten branch, `git status -sb` should show it ahead of its upstream and not behind.
- If the rewritten commits were already pushed, push with `--force-with-lease`; otherwise use a normal push.

To make `git pull` rebase instead of merge by default, configure the current repository:

```bash
git config pull.rebase true
```

Use `--global` to apply the setting to all repositories for your user. You can also choose rebase for a single pull with `git pull --rebase`.

## Inspect History and Changes

```bash
git log --oneline --graph --decorate --all
git log --oneline main..HEAD
git show <commit>
```

`git log --oneline main..HEAD` lists commits reachable from `HEAD` but not from `main`. Fetch first if you need an up-to-date `origin/main` reference.

Useful `git diff` comparisons:

```bash
git diff                    # working tree versus staged index
git diff --cached           # staged index versus HEAD
git diff HEAD               # all uncommitted changes versus HEAD
git diff <commit-a>..<commit-b>
git diff --stat <commit-a>..<commit-b>
```

## Amend the Latest Commit

Stage the changes that belong in the latest commit, then amend it:

```bash
git add -p
git commit --amend --no-edit
```

Omit `--no-edit` to change the commit message. Amending creates a replacement commit with a new hash. If the original commit was already pushed, update the branch with `git push --force-with-lease`.

## Edit Older Commits with Interactive Rebase

Start an interactive rebase covering the last `N` commits:

```bash
git rebase -i HEAD~N
```

The todo list is ordered oldest to newest. Change `pick` to:

| Action | Result |
| --- | --- |
| `reword` | Keep the changes and edit the commit message. |
| `edit` | Pause at the commit so you can change its contents or message. |
| `squash` | Combine the commit with the previous commit and edit the combined message. |
| `fixup` | Combine with the previous commit and discard this commit's message. |
| `drop` | Remove the commit and its changes from the rebased branch. |

To edit more than one commit, mark each target line `edit`, save, and close the editor. At each pause, make the desired changes, stage them, amend, and continue:

```bash
git add -p
git commit --amend --no-edit
git rebase --continue
```

Repeat at each `edit` stop. To change only a message, run `git commit --amend` without changing the files. To abandon the whole rebase and return to the original branch state, run `git rebase --abort`.

### Add Changes to an Older Commit

For a single selected target commit, create a fixup commit and autosquash it into the target. `<base>` must be the commit immediately before the oldest commit being rewritten:

```bash
git add -p
git commit --fixup=<target-commit>
GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash <base>
```

For changes intended for different commits, stage and fix up each set separately:

```bash
git add -p
git commit --fixup=<target-commit-1>

git add -p
git commit --fixup=<target-commit-2>

GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash <base>
```

Review `git status --short` and `git log --oneline <base>..HEAD` before and after the operation to ensure each change landed in the intended commit.

## Drop Commits

To drop one or more commits from the recent history, start an interactive rebase that includes them and change their `pick` lines to `drop` (or remove those lines):

```bash
git rebase -i HEAD~N
```

Save and close the editor to replay the remaining commits. Dropping a commit removes its changes from the branch history and may cause conflicts in later commits. Use `git rebase --abort` to cancel if the result is not right. If the dropped commits were already pushed, use `git push --force-with-lease` after reviewing the new history.

## Resolve Rebase Conflicts

When a rebase stops on a conflict:

1. Run `git status` to see which files need resolution.
2. Open each conflicted file. Resolve the `<<<<<<<`, `=======`, and `>>>>>>>` sections, keeping the intended final content.
3. Stage each resolved file with `git add <file>`.
4. Continue with `git rebase --continue`.
5. Repeat until the rebase completes, then inspect the history and run the relevant tests.

Useful commands while resolving:

```bash
git diff                    # inspect unresolved changes
git diff --check            # find whitespace errors
git rebase --continue       # continue after staging resolutions
git rebase --skip           # omit the current commit only when its changes are not needed
git rebase --abort          # cancel the rebase and restore the pre-rebase branch
```

Do not use `git rebase --skip` as a generic conflict fix: it drops the entire commit currently being replayed.

## Quick Safety Checks

Before rewriting history or pushing:

```bash
git status -sb
git log --oneline --graph --decorate -15
git diff origin/main...HEAD
```

Confirm the branch, commits, and final file changes are the ones you intend. Use `--force-with-lease` only for a branch you own or are authorized to update.

## Tags and GitHub Releases

A **tag** is a name attached to a specific commit. Use version tags such as `v1.2.3` to identify a stable point in history for deployments, rollbacks, or reproducible builds. Prefer annotated tags (`git tag -a`), which include a message and tag metadata. Avoid moving or reusing a published version tag.

A **GitHub Release** is a GitHub page associated with a tag. It can include release notes and downloadable assets; workflows may also use the tag to trigger builds or deployments. A pull request is not itself a release: releasing from its branch tags the branch's current commit, whether or not the PR has been merged.

### Create a release from `main`

For a normal production release, create the version tag on the reviewed commit in `main`:

```bash
git fetch origin
git switch main
git pull --ff-only origin main
git log -1 --oneline             # confirm the commit to release
git tag -a v1.2.3 -m "Release v1.2.3"
git push origin v1.2.3
gh release create v1.2.3 --verify-tag --title "v1.2.3" --generate-notes
```

Replace `v1.2.3` with the next version. The GitHub CLI (`gh`) must be installed and authenticated. `--verify-tag` makes the release command fail if the tag was not pushed.

### Create a prerelease from a PR branch

Use this when reviewers or testers need to try the exact code on a PR branch before it is merged. Mark it as a prerelease so it is not mistaken for the stable release:

```bash
git fetch origin
gh release create v1.2.3-rc.1 \
	--target test-branch \
	--prerelease \
	--title "v1.2.3-rc.1" \
	--generate-notes
```

`--target` selects the branch commit for the new tag. Replace `test-branch` with the PR's branch name. After the PR is merged and approved for production, create a new stable version tag from `main`; do not move the prerelease tag to a different commit.

You can also create a release in GitHub: open **Releases**, choose **Draft a new release**, select or create the tag, choose its target branch, add notes, and mark **Set as a pre-release** when appropriate. For a stable production release, use a reviewed commit from `main`.