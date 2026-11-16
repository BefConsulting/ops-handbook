# Git Field Guide

Practical Git commands for day-to-day branch work. Examples assume a feature branch named `test-branch` and a remote named `origin`; replace those with your branch and remote as needed.

## Contents

- [The Basic Model](#the-basic-model)
  - [References and History](#references-and-history)
  - [File States](#file-states)
  - [History and Change Commands](#history-and-change-commands)
- [Check Your Identity](#check-your-identity)
- [Start a Work Session](#start-a-work-session)
- [Commit and Push Changes](#commit-and-push-changes)
  - [Staging and Committing](#staging-and-committing)
- [Fetch and Rebase Workflow](#fetch-and-rebase-workflow)
  - [Rebase vs. Merge](#rebase-vs-merge)
- [Inspect History and Changes](#inspect-history-and-changes)
- [Amend the Latest Commit](#amend-the-latest-commit)
- [Edit Older Commits with Interactive Rebase](#edit-older-commits-with-interactive-rebase)
  - [Add Changes to an Older Commit](#add-changes-to-an-older-commit)
- [Drop Commits](#drop-commits)
- [Undo Commits](#undo-commits)
  - [Commits not pushed yet](#commits-not-pushed-yet)
  - [Commits already pushed](#commits-already-pushed)
  - [Undo the changes to one file](#undo-the-changes-to-one-file)
  - [Recover from a bad reset](#recover-from-a-bad-reset)
- [Resolve Rebase Conflicts](#resolve-rebase-conflicts)
- [Quick Safety Checks](#quick-safety-checks)
- [Tags and GitHub Releases](#tags-and-github-releases)
  - [Create a release from `main`](#create-a-release-from-main)
  - [Create a prerelease from a PR branch](#create-a-prerelease-from-a-pr-branch)

## The Basic Model

### References and History

- A **commit** is a saved snapshot of staged changes. It exists locally until pushed.
- A **branch** is a movable name pointing to a commit.
- `HEAD` identifies the current commit. Usually it points to the tip of the checked-out branch; in detached-HEAD state it points directly to a commit.
- `origin` is the conventional name for a remote repository. `origin/main` is your local record of that remote's `main` branch, updated by `git fetch`.

### File States

- **Tracked**: Git knows the file because it is committed or in the index.
- **Untracked**: a new file Git has not been told to track. `git add` starts tracking it and stages its current contents.
- **Unstaged**: edits to a tracked file that are not in the index yet.
- **Staged**: changes selected in the index for the next commit. Use `git add` to stage and `git restore --staged <file>` to unstage.

### History and Change Commands

- `git log` lists commits; `git show <commit>` displays a commit and its changes.
- `git diff` shows tracked unstaged changes; `git diff --cached` shows staged changes. `git diff <commit-a> <commit-b>` compares two commits.

## Check Your Identity

Git records a name and email on every commit. Check the values that apply in the current repository:

```bash
git config user.name
git config user.email
```

Settings can come from more than one place. A repository-level value overrides the global one. To see each value and the file it comes from:

```bash
git config --list --show-origin | grep user
```

To check or change one scope only:

```bash
git config --global user.email                   # read from ~/.gitconfig
git config --local user.email                    # read from this repo's .git/config
git config --global user.email "you@example.com" # set for all repositories
git config user.email "you@example.com"          # set for the current repository only
```

Changing the config affects only new commits. Commits you already made keep the old identity. To fix the latest commit, run `git commit --amend --reset-author --no-edit`.

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

### Staging and Committing

Staging selects which changes go into the next commit. Committing saves that staged snapshot in your local repository; it does not push it to GitHub.

New untracked files appear in `git status`, but not in regular diffs until added (or compared explicitly with `git diff --no-index`).

```text
Working tree                 Staging area                 Local repository
(edit files) -- git add -->  (selected changes) -- git commit --> [commit]
```

For example, `git status --short` may show:

```text
 M README.md    # tracked, modified, unstaged
A  notes.md     # new file, staged
?? draft.txt    # untracked
```

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

### Rebase vs. Merge

Suppose `feature` and `main` have both advanced from commit `B`:

```text
	D---E  feature
     /
A---B---C    main
```

Rebase replays the feature changes on top of `main`. The rebased commits get new IDs (`D'` and `E'`), and the history is linear:

```text
A---B---C  main
	   \
	    D'---E'  feature
```

Merge combines both histories with a merge commit. The original feature commits remain unchanged:

```text
	D---E----.
     /          \
A---B---C--------M  feature
				^
				main before merge
```

Use rebase to keep your own feature branch current with `main`; use merge when you want to preserve the branch history and record where the histories came together. Avoid rebasing commits that others are already using.

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

## Undo Commits

Which approach to use depends on whether the commits have been pushed.

### Commits not pushed yet

Use `git reset` to move the branch back. The mode decides what happens to the changes from the undone commits:

```bash
git reset --soft HEAD~1   # undo the commit, keep its changes staged
git reset HEAD~1          # undo the commit, keep its changes as unstaged edits
git reset --hard HEAD~1   # undo the commit and discard its changes
```

Use `HEAD~N` to undo the last `N` commits, or a commit hash to reset the branch to that commit. `--hard` also discards any uncommitted work in the working tree, so check `git status` first.

### Commits already pushed

Prefer `git revert`. It adds a new commit that reverses the changes and leaves existing history intact, so it is safe on shared branches such as `main`:

```bash
git revert <commit>
git push
```

On a feature branch that only you use, you can rewrite history instead:

```bash
git reset --hard HEAD~1
git push --force-with-lease origin test-branch
```

### Undo the changes to one file

Restore a file to the version it had before the latest commit, then commit the restored file:

```bash
git restore --source=HEAD~1 -- path/to/file
git commit -m "Revert changes to path/to/file"
```

### Recover from a bad reset

`git reflog` lists every commit `HEAD` has pointed to, including commits that are no longer on any branch. Find the hash from before the reset and move the branch back to it:

```bash
git reflog
git reset --hard <commit>
```

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