# git-work

**Stop juggling branches. Give each one its own directory.**

git-work wraps `git worktree` into a simple CLI that keeps one directory per branch. Switching branches means switching directories -- no more stashing, no more rebuilding, no interrupted dev servers.

```
my-project/
├── .bare/              # bare git repo (shared by all worktrees)
├── main/               # worktree for main
├── feature-login/      # worktree for feature/login
└── fix-typo/           # worktree for fix-typo
```

## Install

```bash
brew tap beeemT/tap && brew install git-work
```

## Quick Start

**Clone a new repo:**

```bash
gw clone git@github.com:you/repo.git
cd repo/main
```

**Or convert an existing repo in-place:**

```bash
cd my-project
gw init
# your working tree moves into my-project/<branch>/
```

**Switch branches:**

```bash
gw checkout feature-login   # switch to existing worktree
gw checkout feat             # fuzzy match existing worktree
gw checkout -b new-feature   # create new worktree for branch
```

## Shell Integration

git-work prints paths to stdout. The `gw` shell function wraps the binary and `cd`s into the output automatically. Add one of these to your shell config:

```bash
# bash / zsh
eval "$(git-work activate bash)"    # or zsh

# fish
git-work activate fish | source
```

Then use `gw` instead of `git-work` for seamless directory switching.

## Commands

| Command | Description |
|---|---|
| `gw clone <url> [dir]` | Clone a repo into the worktree layout |
| `gw init` | Convert the current repo in-place |
| `gw checkout [-b] <branch>` | Switch to a branch (use -b to create new worktree) |
| `gw rm [--force] <branch>` | Remove a worktree and delete the branch |
| `gw sync [--dry-run] [--force]` | Fetch and prune worktrees for deleted remote branches |
| `gw list` | List all worktrees |
| `gw activate <shell>` | Print the shell wrapper function |

### `clone <url> [directory]`

Clones a repo as a bare repo in `.bare/`, sets up the directory structure, and adds a worktree for the default branch.

```bash
gw clone git@github.com:you/repo.git
gw clone git@github.com:you/repo.git my-project
```

### `init`

Converts the current repository in-place. Your `.git/` directory becomes `.bare/`, and your working files move into a subdirectory named after the current branch. Uncommitted changes are stashed and restored automatically.

```bash
cd existing-repo
gw init
```

### `checkout <branch>`

Switches to an existing worktree. Supports fuzzy matching -- a partial branch name works as long as it's unambiguous.

```bash
gw checkout main               # exact match
gw checkout feat               # fuzzy: matches "feature-login"
```

To create a new worktree for a branch (existing or new), use `-b`:

```bash
gw checkout -b new-feature     # create new worktree + branch
gw checkout -b feature-login   # create new worktree for existing branch
```

If multiple branches match, git-work lists the candidates and exits with an error so you can be more specific.

### `rm [--force] <branch>`

Removes a worktree and deletes its branch. The HEAD branch (usually `main`) is protected unless `--force` is passed. If you're inside the worktree being removed, `gw` moves you to the HEAD branch worktree.

```bash
gw rm feature-login
gw rm --force stale-experiment
```

### `sync [--dry-run] [--force]`

Fetches all remotes, then removes worktrees whose tracking branch no longer exists on the remote. The HEAD branch is never pruned.

```bash
gw sync              # fetch + prune stale worktrees
gw sync --dry-run    # preview what would be pruned
gw sync --force      # force-remove worktrees with unmerged changes
```

### `list`

Lists all worktrees (thin wrapper around `git worktree list`).

```bash
gw list
```

## Design

- **stdout is for paths only.** All human-facing messages go to stderr. This is what makes the `gw` shell wrapper work -- it `cd`s into stdout when it's a directory.
- **No config files, no database, no state.** Everything is derived from git and the filesystem at runtime.
- **Branch-to-directory mapping:** `/` in branch names becomes `-` in directory names. `feature/login` lives in `feature-login/`. The real branch name is always used in git commands.
- **Fuzzy matching** tries substring match first, then Jaro-Winkler similarity (threshold 0.85). A single match wins; ambiguous matches are reported as errors.

## Why?

`git worktree` is powerful but verbose. Setting up a bare-repo-based layout requires several manual steps and knowledge of git internals. git-work handles all of that so you can just think in terms of branches and directories.

Common benefits:
- Run a dev server on `main` while working on a feature branch in another terminal
- Keep IDE state, build caches, and `node_modules` per branch
- Review PRs without disrupting your current work
- Never lose uncommitted changes to an accidental checkout

## Development

```bash
mise install                      # install Elixir + Erlang
mix deps.get && mix compile       # compile
mix test                          # run tests
mix escript.build                 # build the binary
./git_work --help                 # run it
```

## License

MIT
