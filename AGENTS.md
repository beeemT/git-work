# AGENTS.md

## Project Overview

**git-work** is an Elixir CLI tool (escript) that wraps `git worktree` to
provide a branch-per-directory workflow. Instead of `git checkout`, users get
one directory per branch under a project root that holds a bare repo in `.bare/`.

See `PLAN.md` for full design, command specs, and acceptance criteria.

## Tech Stack

- **Language**: Elixir (escript for distribution)
- **Tooling**: mise (`.mise.toml` manages Elixir + Erlang versions)
- **Build**: `mix escript.build`
- **Tests**: ExUnit, integration tests against real local git repos in tmp dirs
- **No external dependencies** unless strictly necessary — use stdlib

## Repo Layout

```
lib/
├── git_work.ex                # escript entrypoint (main/1)
├── git_work/
│   ├── cli.ex                 # argument parsing + command dispatch
│   ├── commands/
│   │   ├── clone.ex
│   │   ├── checkout.ex
│   │   ├── init.ex
│   │   ├── sync.ex
│   │   ├── rm.ex
│   │   └── list.ex
│   ├── project.ex             # project root discovery, path helpers, branch name sanitization
│   ├── fuzzy.ex               # fuzzy matching (substring then Jaro-Winkler)
│   ├── git.ex                 # thin wrapper around System.cmd("git", ...)
│   └── shell_hook.ex          # generates the shell wrapper function
test/
├── test_helper.exs
├── git_work/
│   ├── commands/
│   │   ├── clone_test.exs
│   │   ├── checkout_test.exs
│   │   ├── init_test.exs
│   │   ├── sync_test.exs
│   │   ├── rm_test.exs
│   │   └── list_test.exs
│   ├── project_test.exs
│   └── fuzzy_test.exs
```

## Build & Test

```bash
# Install tooling
mise install

# Compile
mix deps.get && mix compile

# Run tests
mix test

# Build the escript binary
mix escript.build

# Run the binary
./git_work --help
```

## Architecture Rules

1. **Stdout is for machine-readable output only** (paths). All human-facing
   messages, warnings, and errors go to **stderr**. The shell wrapper function
   (`gw`) relies on this contract — it `cd`s into stdout if it's a directory.

2. **All git interaction goes through `GitWork.Git`**. No direct
   `System.cmd("git", ...)` calls elsewhere. This module handles error
   checking (non-zero exit) and returns `{:ok, output} | {:error, message}`.

3. **Commands return `{:ok, output} | {:error, message}`**. The CLI top-level
   in `cli.ex` handles the result: prints output or writes errors to stderr
   and sets the exit code.

4. **No state files**. Everything is derived from git and the filesystem. No
   config files, no database, no lockfile.

5. **Branch-to-directory mapping**: `/` in branch names is replaced with `-`.
   `feature/login` becomes directory `feature-login`. The real branch name is
   always used in git commands.

## Testing Conventions

- Integration tests create real git repos in `System.tmp_dir!()` during setup
  and clean up in `on_exit`. No mocking of git.
- Use `@tag :tmp_dir` or create temp dirs manually in setup blocks.
- Test both the happy path and error cases (already initialized, missing
  worktree, ambiguous fuzzy match, etc.).
- Verify filesystem state (dirs exist, `.git` file contents) and git state
  (`git worktree list`, `git branch`) after operations.

## Key Design Decisions

- **Bare repo in `.bare/`** at project root — worktrees are sibling dirs.
- **Fuzzy checkout**: substring match first, then `String.jaro_distance/2`
  with 0.7 threshold. Single match is used; multiple matches exit non-zero
  with candidates listed on stderr.
- **`init` command** converts a normal repo in-place: moves `.git/` to
  `.bare/`, relocates working files into a branch subdir, wires up worktree
  linkage. Stashes uncommitted changes and restores after.
- **`sync` command** runs `git fetch --all --prune` then removes worktrees
  whose remote tracking branch no longer exists. Never prunes HEAD branch.
  Supports `--dry-run` and `--force`.
- **Shell integration** via `eval "$(git-work --shell-hook)"` which defines a
  `gw` shell function that wraps the binary and `cd`s into path output.
