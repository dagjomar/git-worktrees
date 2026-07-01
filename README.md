# git-worktrees

A simple worktree management utility with fzf-powered navigation.

## Why `wt`?

**Starting a new feature:**

| Plain `git worktree` | `wt` |
|---|---|
| `git worktree add -b my-feature ../my-feature` | `wt add my-feature` |
| `cd ../my-feature` | ✅ *auto-navigates* |
| `cp ../my-repo/frontend/.env.local frontend/` | ✅ *ignored files auto-copied* |
| `cd frontend && yarn install` | ✅ *node_modules symlinked — skip this* |
| `yarn dev` | `yarn dev` |
| work, commit, push… | work, commit, push… |
| `cd ../my-repo` | |
| `git worktree remove ../my-feature` | `wt rm` |
| `git branch -d my-feature` | ✅ *prompts to delete branch* |

**Reviewing a remote branch:**

| Plain `git worktree` | `wt` |
|---|---|
| `git fetch origin` | `git fetch origin` |
| `git worktree add -b review ../review origin/feat` | `wt add review origin/feat` |
| `cd ../review` | ✅ *auto-navigates* |
| `cp ../my-repo/frontend/.env.local frontend/` | ✅ *ignored files auto-copied* |
| `cd frontend && yarn install` | ✅ *node_modules symlinked — skip this* |
| `yarn dev` | `yarn dev` |
| review… | review… |
| `cd ../my-repo` | |
| `git worktree remove ../review` | `wt rm` |
| `git branch -d review` | ✅ *prompts to delete branch* |

## Commands

| Command | Description |
|---|---|
| `wt init` | Create `.worktreeinclude` and `.worktreesymlink` config files in the main worktree (skips if they already exist) |
| `wt add <name> [branch]` | Create a new worktree, apply `.worktreeinclude` and `.worktreesymlink`, and navigate to it. Without `branch`: creates a new local branch `<name>`. With `branch` (e.g. `origin/feat`): checks out that branch directly — no extra local branch created |
| `wt ls [name]` | Navigate to a worktree with fzf, or print the path of `<name>` |
| `wt rm [name] [-f]` | Delete worktree `<name>`; without a name: the current worktree, or pick with fzf when run from the main worktree. `-f` skips confirmation |
| `wt setup` | Apply `.worktreeinclude` / `.worktreesymlink` in an existing worktree — only needed for worktrees not created with `wt add` (which runs this automatically) |
| `wt unsymlink` | Remove symlinks created from `.worktreesymlink` |
| `wt --help` | Show help |

fzf is only a shorthand: `wt ls` / `wt rm` without a name use fzf to pick the
argument, then run the same code path as the non-interactive form.

## Configuration files

Both files live in the main worktree's root, one entry per line; lines starting with `#` are comments, blank lines are ignored. They are automatically applied when you run `wt add` (or manually with `wt setup`).

### `.worktreeinclude` — Copy files and directories

Files and directories listed here are *copied* into each new worktree. Use for:
- **Environment files** (`.env.local`, `.env.*.local`) — secrets and local config that vary per developer
- **Hook directories** (e.g. `.husky/_`) — git hooks shared across the repo but with filesystem state
- **Any untracked files** you want each worktree to have independently

Directories are copied with `rsync -a`, so internal symlinks survive (important for tools like husky).

Example:
```
# Environment files
frontend/.env.local
frontend/ikt-skip/.env.local

# Hook directories (internal symlinks preserved)
frontend/.husky/_
```

Missing entries are skipped without error (useful for optional files).

### `.worktreesymlink` — Symlink directories to save disk space

Glob patterns listed here are *symlinked* (not copied) into each new worktree, resolved against the main worktree. Use for:
- **`node_modules` directories** — avoid re-running `yarn install` in every worktree
- **Build artifacts** or other large read-only directories
- **Any directory you want all worktrees to share** (on the same filesystem)

⚠️ **Important:** Do not run `yarn install` (or any package manager) in a worktree with symlinked `node_modules`. If you need to change dependencies:
1. Run `wt unsymlink` to remove the symlinks
2. Run `yarn install` or your package manager
3. When you're done, create a new worktree with `wt add` to get fresh symlinks

Example:
```
# Symlink node_modules to avoid re-running yarn
frontend/node_modules
frontend/*/node_modules
```

The `frontend/*/node_modules` glob will match `frontend/app-a/node_modules`, `frontend/app-b/node_modules`, etc.

## Worktree location

By default, `wt add <name>` creates the worktree as a sibling of the main repo:

```
parent/
  my-repo/        ← main worktree
  my-feature/     ← created by wt add my-feature
```

To use a different location, set `WT_WORKTREE_DIR` in your `~/.zshrc`:

```zsh
# Inside the repo (add to .gitignore):
export WT_WORKTREE_DIR=.worktrees       # → my-repo/.worktrees/my-feature
export WT_WORKTREE_DIR=worktrees        # → my-repo/worktrees/my-feature

# Sibling directory:
export WT_WORKTREE_DIR=../worktrees     # → parent/worktrees/my-feature

# Absolute path:
export WT_WORKTREE_DIR=/tmp/worktrees   # → /tmp/worktrees/my-feature
```

If you use an in-repo location (no leading `../`), add it to `.gitignore`:

```
.worktrees/
```

## Requirements

- [fzf](https://github.com/junegunn/fzf) — `brew install fzf` (only for the interactive picker)
- `rsync` (preinstalled on macOS and most Linux distros)

## Tests

```bash
./bin/git-worktrees_test.sh
```

Creates a throwaway git repository in a temp directory, exercises all commands through their non-interactive forms, and asserts on filesystem state and output. No fzf needed.

## Installation

> **Note:** `install.sh` only supports zsh (writes to `~/.zshrc`). Bash users should follow the manual installation below.

```bash
git clone https://github.com/dagjomar/git-worktrees.git
cd git-worktrees
./bin/install.sh
source ~/.zshrc
```

## Manual installation

Add the following to your `~/.zshrc`:

```zsh
wt() {
  local script="/path/to/git-worktrees/bin/git-worktrees.sh"
  local dir
  case "${1:-}" in
    ls)
      dir=$("$script" "$@") && [ -n "$dir" ] && cd "$dir"
      ;;
    add)
      "$script" "$@" || return $?
      dir=$("$script" ls "${2:-}" 2>/dev/null) && [ -n "$dir" ] && cd "$dir"
      ;;
    rm)
      local main
      main=$(command git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)
      "$script" "$@"
      # If we just removed the worktree we were standing in, move to main
      [ -d "$PWD" ] || cd "$main"
      ;;
    *)
      "$script" "$@"
      ;;
  esac
}
```
