---
name: git-work
description: Opinionated git worktree helper that makes worktrees work like branches.
---

# git-work

`git-work` is a CLI that wraps `git worktree` into a branch-per-directory workflow. Each branch lives in its own subdirectory. Context-switching is `cd`, not `git checkout`.

## Layout

```
my-project/
├── .bare/            # bare git repo shared by all worktrees
├── .git              # pointer file: gitdir: ./.bare
├── main/             # worktree for branch main
├── feature-login/    # worktree for branch feature/login
└── fix-typo/         # worktree for branch fix-typo
```

`/` in branch names is replaced with `-` for the directory name. The real branch name is always used in git commands.

## Shell wrapper (`gw`)

The `gw` shell function wraps `git-work` and automatically `cd`s into any path printed to stdout. Set it up once per shell:

```bash
# bash / zsh
eval "$(git-work activate bash)"

# fish
git-work activate fish | source
```

Use `gw <command>` in interactive shells. Call `git-work <command>` directly in scripts (no `cd` side-effect).

## stdout / stderr contract

**stdout** is machine-readable only — directory paths. All human-readable messages, warnings, and errors go to **stderr**. This is what allows `gw` to `cd` reliably.

## Commands

### Start a project

```bash
# Clone a remote repo into git-work layout
gw clone git@github.com:org/repo.git
gw clone https://github.com/org/repo.git my-project

# Convert an existing normal repo in-place (run from inside repo root)
cd ~/projects/my-repo
gw init
```

`clone` creates `<dir>/.bare` (bare repo), writes `<dir>/.git` pointer, and adds a worktree for HEAD.

`init` moves `.git/` → `.bare/`, moves working files into `<root>/<current-branch>/`, wires up worktree linkage, and stashes/restores uncommitted changes. Safe to re-run: repairs state if the layout already exists but is broken.

### Navigate between branches

```bash
gw co main             # switch to existing worktree by name
gw co login            # fuzzy match — resolves to feature-login
gw co -                # switch to previously visited worktree
gw co feature/remote   # auto-create worktree from remote branch (no -b needed)
gw co -b feature/new   # create new worktree + branch
```

Fuzzy matching order:
1. Exact directory name match
2. Substring match (`login` → `feature-login`)
3. Jaro-Winkler similarity, threshold 0.85

Ambiguous matches (multiple candidates pass) exit non-zero and list candidates on stderr.

`gw co <branch>` without `-b` will auto-create a worktree only if a remote branch with that **exact** name exists. Otherwise it errors.

### Remove a worktree

```bash
gw rm feature-login          # prompts for confirmation
gw rm login                  # fuzzy match
gw rm --yes feature-login    # skip confirmation
gw rm --force old-branch     # force-delete (unmerged ok; HEAD branch ok)
```

Removes the worktree directory and runs `git branch -d` (or `-D` with `--force`). Refuses to remove HEAD branch without `--force`. If you run `gw rm` from inside the worktree being removed, the tool prints the HEAD worktree path so the shell wrapper moves you there.

### Sync with remote

```bash
gw sync                # fetch --all --prune, then remove stale local worktrees
gw sync --dry-run      # preview what would be pruned
gw sync --force        # force-delete branches with unmerged changes
```

HEAD branch is never pruned.

### List worktrees

```bash
gw ls
```

Prints a table: directory name, branch name, `*` for current worktree.

## Hooks (mise integration)

On every new worktree creation (`gw co -b` or remote auto-create), git-work fires a post-create hook:

1. If the source worktree is `mise`-trusted, runs `mise trust` in the new worktree.
2. Runs `mise run worktree-setup` in the new worktree if the task exists.

If the task does not exist, a warning is printed and execution continues. If the task exits non-zero, worktree creation is rolled back.

Configure via git config (stored in `.bare`):

```bash
# disable trust propagation
git -C .bare config git-work.hooks.mise.trust false

# use a custom task name
git -C .bare config git-work.hooks.mise.task bootstrap

# disable task execution entirely
git -C .bare config git-work.hooks.mise.task ""
```

## Common patterns for agents

**Determine current worktree and project root:**
```bash
pwd                        # current worktree dir, e.g. /home/user/repo/feature-login
git -C .bare rev-parse --show-toplevel  # not useful; use filesystem layout instead
```
The project root is the parent of the current worktree directory. `.bare/` always lives at the project root.

**Check what worktrees exist:**
```bash
gw ls
# or directly:
git -C ../.bare worktree list
```

**Create a branch and immediately work in it:**
```bash
gw co -b feature/my-task
# shell wrapper cd'd you in; now you are in the new worktree
```

**Clean up after merging:**
```bash
gw rm feature/my-task --yes
# or let sync handle it after remote branch is deleted
gw sync
```

**Check if inside a git-work project:**
A git-work project has `.bare/` at its root (one level up from the current worktree). If `../.bare` is a bare git repo, you are inside a git-work layout.

## Error cases

| Situation | Behavior |
|---|---|
| `gw co <branch>` — no worktree, no remote | exits non-zero, error on stderr |
| `gw co <branch>` — multiple fuzzy matches | exits non-zero, candidates on stderr |
| `gw co -b <branch>` — worktree already exists | exits non-zero |
| `gw rm <head-branch>` without `--force` | exits non-zero |
| mise task exits non-zero | worktree creation rolled back, exits non-zero |
| Not inside a git-work project | exits non-zero |
