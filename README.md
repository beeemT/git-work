# git-work

**Stop juggling branches. Give each one its own directory.**

git-work wraps `git worktree` into a practical CLI for branch-per-directory workflows. Instead of `git checkout`, each branch gets its own worktree directory, so switching context is just switching directories.

```
my-project/
|- .bare/              # bare git repo (shared by all worktrees)
|- main/               # worktree for main
|- feature-login/      # worktree for feature/login
`- fix-typo/           # worktree for fix-typo
```

## Install

```bash
brew tap beeemT/tap && brew install git-work
```

## Shell integration (`gw`)

git-work prints machine-readable paths to stdout. The `gw` shell function wraps `git-work` and `cd`s into returned paths automatically.

```bash
# bash / zsh
# add to ~/.bashrc or ~/.zshrc
eval "$(git-work activate bash)"

# fish
# add to ~/.config/fish/config.fish
git-work activate fish | source
```

After this, use `gw` commands (examples below).

## Quick start

Clone into git-work layout:

```bash
gw clone git@github.com:you/repo.git
cd repo/main
```

Or convert an existing repo in place:

```bash
cd my-project
gw init
```

Switch/create worktrees:

```bash
gw co main                # checkout existing worktree
gw co login               # fuzzy match, e.g. feature-login
gw co -b feature/new-ui   # create new worktree
```

Jump back to previous worktree:

```bash
gw co -
```

## Commands (with shorthands)

| Command | Alias | Description |
|---|---|---|
| `gw activate <shell>` | - | Print shell wrapper function (`bash`, `zsh`, `fish`) |
| `gw clone <url> [dir]` | `gw cl` | Clone repo into `.bare/` + initial worktree |
| `gw init` | - | Convert current repo to git-work layout |
| `gw checkout <branch>` | `gw co` | Switch to existing worktree (supports fuzzy matching) |
| `gw checkout -` | `gw co -` | Switch to previously visited worktree |
| `gw checkout -b <branch>` | `gw co -b` | Create a worktree for branch |
| `gw rm [--force] [--yes] <branch>` | - | Remove worktree + delete branch (fuzzy + confirmation) |
| `gw sync [--dry-run] [--force]` | `gw s` | Fetch + prune stale worktrees |
| `gw list` | `gw ls` | List worktrees |

## Command details

### `gw clone` / `gw cl`

- Creates `<dir>/.bare` as a bare repository
- Writes `<dir>/.git` pointer file (`gitdir: ./.bare`)
- Adds an initial worktree for the HEAD branch

Examples:

```bash
gw cl git@github.com:you/repo.git
gw clone https://github.com/you/repo.git my-project
```

### `gw init`

Converts a normal repo in place:

1. Moves `.git/` to `.bare/`
2. Moves working files into `<root>/<current-branch>/`
3. Creates worktree metadata/pointers
4. Restores stashed uncommitted changes

If `gw init` is run again in an existing git-work root, it repairs workspace state (for example, rewriting `.git` pointer/config and recreating the HEAD worktree directory if missing).

### `gw checkout` / `gw co`

```bash
gw co <branch>
gw co -
gw co -b <branch>
```

Behavior:

- `gw co <branch>`: switch to existing worktree by exact/fuzzy match
- `gw co -`: switch to previous worktree
- `gw co -b <branch>`: create new worktree (existing local branch, remote branch, or new branch)
- If no local worktree matches but a remote branch with exact name exists, `gw co <branch>` auto-creates a tracking worktree

Fuzzy matching order:

1. Exact directory match
2. Substring match
3. Jaro-Winkler similarity (threshold 0.85)

Ambiguous matches exit non-zero and list candidates.

### `gw rm`

```bash
gw rm [--force] [--yes] <branch>
```

Behavior:

- Supports fuzzy matching of the branch/worktree argument
- Prompts for confirmation before deleting
- `--yes` skips the confirmation prompt
- Refuses to remove the HEAD branch unless `--force` is passed
- If run from inside the removed worktree, returns the HEAD worktree path so `gw` can move you safely

Examples:

```bash
gw rm feature-login
gw rm login
gw rm --yes feature-login
gw rm --force old-branch
```

### `gw sync` / `gw s`

```bash
gw sync [--dry-run] [--force]
```

Behavior:

- Runs `git fetch --all --prune`
- Removes local worktrees whose tracking remote branch no longer exists
- Never prunes HEAD branch
- `--dry-run` previews removals
- `--force` force-removes stale worktrees/branches

### `gw list` / `gw ls`

Shows a formatted worktree table:

- directory name
- branch name
- `*` marker for current worktree

## Hooks and mise integration

When creating a new worktree (`gw co -b ...` or remote auto-create), git-work runs a post-create hook with mise integration.

- If `mise` is not installed, hook is skipped
- By default, git-work attempts:
  - trust propagation (`mise trust`) when source worktree is trusted
  - task execution: `mise run worktree:setup`

Configuration (stored in repo git config under `.bare`):

```bash
# disable trust propagation
git -C .bare config git-work.hooks.mise.trust false

# choose custom setup task
git -C .bare config git-work.hooks.mise.task bootstrap

# disable task execution
git -C .bare config git-work.hooks.mise.task ""
```

If the configured task does not exist, git-work logs a warning and continues. If the task fails, worktree creation is rolled back.

## Design notes

- stdout is reserved for machine-readable output (paths)
- human-readable messages/warnings/errors go to stderr
- no state files: behavior is derived from git + filesystem
- branch-to-directory mapping replaces `/` with `-`

## Development

```bash
mise install
mix deps.get && mix compile
mix test
mix escript.build
./git_work --help
```

## License

MIT
