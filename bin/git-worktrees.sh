#!/usr/bin/env bash
# wt — worktree management utility
# -------------------------------------------------------------------------
# A git worktree helper with fzf-powered navigation.
#
# Commands:
#   wt add <name> [<branch>]  Create a new worktree at ../<name>, then run setup automatically.
#                             With <branch> (e.g. origin/feat): checks out that branch directly
#                             (no extra local branch created). Without: creates a new branch <name>.
#   wt init              Create .worktreeinclude and .worktreesymlink config files (main worktree only)
#   wt ls [name]         Print path of worktree <name>, or pick with fzf
#   wt rm [name] [-f]    Delete worktree <name>; without a name: the current
#                        worktree, or pick with fzf when in the main worktree
#   wt setup             Apply .worktreeinclude/.worktreesymlink to the current worktree
#                        (only needed for worktrees not created with `wt add`)
#   wt unsymlink         Remove symlinks created by .worktreesymlink in current worktree
#   wt --help            Show this help
#
# fzf is only a shorthand: `wt ls` / `wt rm` without a name use fzf to pick
# the argument, then run the same code path as the non-interactive form.
#
# Navigation note:
#   Since shell scripts run in a subprocess they cannot cd the parent shell.
#   The global wt function handles cd automatically:
#     wt ls           # navigates to selected worktree
#
# .worktreeinclude — list of files/dirs to copy from main into new worktrees
# .worktreesymlink — list of glob patterns to symlink from main into new worktrees
# -------------------------------------------------------------------------

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
function require_fzf() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "Error: fzf is required for this command."
    echo "Install with: brew install fzf"
    exit 1
  fi
}

function get_main_worktree() {
  git worktree list --porcelain | grep '^worktree' | head -1 | sed 's/^worktree //'
}

# Resolve a worktree name (directory basename) to its absolute path.
# Prints the path and returns 0, or returns 1 if no worktree matches.
function find_worktree_path() {
  local name="$1"
  local path
  while IFS= read -r path; do
    if [ "$(basename "$path")" = "$name" ]; then
      echo "$path"
      return 0
    fi
  done < <(git worktree list --porcelain | grep '^worktree ' | sed 's/^worktree //')
  return 1
}

function run_worktreeinclude() {
  local main="$1"
  local dest="$2"
  local include_file="$main/.worktreeinclude"
  [ -f "$include_file" ] || return 0

  echo -e "${BOLD}Processing .worktreeinclude...${RESET}"
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$entry" in \#*) continue ;; esac
    local src="$main/$entry"
    local dst="$dest/$entry"
    mkdir -p "$dest/$(dirname "$entry")"
    if [ -d "$src" ]; then
      rsync -a "$src/" "$dst/" && echo -e "  ${GREEN}Copied dir${RESET} $entry"
    elif [ -f "$src" ]; then
      cp "$src" "$dst" && echo -e "  ${GREEN}Copied${RESET} $entry"
    else
      echo -e "  ${YELLOW}Skipped (not found):${RESET} $entry"
    fi
  done < "$include_file"
}

function run_worktreesymlink() {
  local main="$1"
  local dest="$2"
  local symlink_file="$main/.worktreesymlink"
  [ -f "$symlink_file" ] || return 0

  echo -e "${BOLD}Processing .worktreesymlink...${RESET}"
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$pattern" in \#*) continue ;; esac
    shopt -s nullglob
    for src in "$main"/$pattern; do
      local rel="${src#$main/}"
      local dst="$dest/$rel"
      if [ -L "$dst" ] || [ -e "$dst" ]; then
        echo -e "  ${YELLOW}Skipped (exists):${RESET} $rel"
      else
        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst" && echo -e "  ${GREEN}Linked${RESET} $rel"
      fi
    done
    shopt -u nullglob
  done < "$symlink_file"
}

function usage() {
  echo -e "${BOLD}wt${RESET} — worktree management utility"
  echo
  echo -e "${BOLD}First-time setup:${RESET}"
  echo -e "  wt ${CYAN}init${RESET}              Create .worktreeinclude and .worktreesymlink config files"
  echo -e "                       (then customize them for your project)"
  echo
  echo -e "${BOLD}Daily usage:${RESET}"
  echo -e "  wt ${CYAN}add${RESET} <name> [branch]  Add a new worktree: runs setup to copy files and symlinks based on"
  echo -e "                       configuration files, and navigates to the worktree"
  echo -e "  wt ${CYAN}rm${RESET}                Use when done with the worktree: removes the current worktree and"
  echo -e "                       navigates back to the main repo"
  echo
  echo -e "${BOLD}All commands:${RESET}"
  echo -e "  wt ${CYAN}init${RESET}              Create .worktreeinclude and .worktreesymlink config files (main worktree only)"
  echo -e "  wt ${CYAN}add${RESET} <name> [branch]  Create a new worktree at ../<name>, optionally checking out an existing"
  echo -e "                         branch (e.g. origin/feat). Without branch: creates a new local branch <name>."
  echo -e "  wt ${CYAN}ls${RESET} [name]         Print path of worktree <name>, or pick with fzf"
  echo -e "  wt ${CYAN}rm${RESET} [name] [-f]    Delete worktree <name>; without a name: the current worktree,"
  echo -e "                       or pick with fzf when run from the main worktree. -f skips confirmation"
  echo -e "  wt ${CYAN}setup${RESET}             Apply .worktreeinclude (copy) and .worktreesymlink (symlink) to the"
  echo -e "                       current worktree — only needed for worktrees not created with 'wt add'"
  echo -e "  wt ${CYAN}unsymlink${RESET}         Remove symlinks created by .worktreesymlink in current worktree"
  echo -e "  wt ${CYAN}--help${RESET}            Show this help"
  echo
  echo -e "${BOLD}Examples:${RESET}"
  echo -e "  wt init              # create .worktreeinclude and .worktreesymlink config files"
  echo -e "  wt add my-feature               # creates branch + worktree (location set by WT_WORKTREE_DIR)"
  echo -e "  wt add review-feat origin/feat  # worktree dir 'review-feat', checks out branch 'feat' from origin"
  echo -e "  wt ls                # navigate to a worktree interactively"
  echo -e "  wt ls my-feature     # print path of the my-feature worktree"
  echo -e "  wt rm my-feature     # delete the my-feature worktree (asks first)"
  echo -e "  wt rm                # inside a worktree: delete it; in main: pick with fzf"
  echo -e "  wt rm my-feature -f  # delete without confirmation, even if dirty"
  echo -e "  wt setup             # apply .worktreeinclude/.worktreesymlink to a worktree made without wt add"
  echo -e "  wt unsymlink         # remove symlinks from current worktree"
}

# ── Commands ──────────────────────────────────────────────────────────────────
function cmd_add() {
  local name="${1:-}"
  local start_point="${2:-}"
  if [ -z "$name" ]; then
    echo "Error: missing worktree name."
    echo "Usage: wt add <name> [<branch>]"
    exit 1
  fi

  local main
  main=$(get_main_worktree)
  local dest
  if [ -n "${WT_WORKTREE_DIR:-}" ]; then
    if [[ "$WT_WORKTREE_DIR" = /* ]]; then
      dest="$WT_WORKTREE_DIR/$name"
    else
      dest="$main/$WT_WORKTREE_DIR/$name"
    fi
  else
    dest=$(cd "$(git rev-parse --show-toplevel)/.." && pwd)/"$name"
  fi

  if [ -n "$start_point" ]; then
    if [[ "$start_point" == */* ]]; then
      # Remote ref (e.g. origin/fare_changelog): derive local branch name and track
      local branch_name="${start_point#*/}"
      git worktree add -b "$branch_name" "$dest" "$start_point"
      git -C "$dest" branch --set-upstream-to="$start_point" "$branch_name" 2>/dev/null || true
    else
      # Local branch: check out directly, no new branch created
      git worktree add "$dest" "$start_point"
    fi
  else
    git worktree add -b "$name" "$dest"
  fi
  local branch
  branch=$(git -C "$dest" branch --show-current 2>/dev/null || echo "$name")
  echo -e "${GREEN}Worktree created:${RESET} $dest  (branch: $branch)"

  run_worktreeinclude "$main" "$dest"
  run_worktreesymlink "$main" "$dest"
}

function cmd_setup() {
  local dest
  dest=$(git rev-parse --show-toplevel)
  local main
  main=$(get_main_worktree)

  if [ "$main" = "$dest" ]; then
    echo "Already in main worktree, nothing to do."
    exit 0
  fi

  run_worktreeinclude "$main" "$dest"
  run_worktreesymlink "$main" "$dest"
  echo -e "${GREEN}Setup complete.${RESET}"
}

function cmd_init() {
  local dest
  dest=$(git rev-parse --show-toplevel)
  local main
  main=$(get_main_worktree)

  if [ "$main" != "$dest" ]; then
    echo "Error: wt init must be run from the main worktree, not a branch worktree."
    exit 1
  fi

  local include_file="$dest/.worktreeinclude"
  local symlink_file="$dest/.worktreesymlink"
  local created=0

  if [ ! -f "$include_file" ]; then
    cat > "$include_file" <<'EOF'
# .worktreeinclude — Files and directories to copy into new worktrees
# One entry per line. Comments start with #. Blank lines are ignored.
# Missing entries are skipped without error.
#
# Use for environment files (.env.local), hook directories (.husky/_),
# or any untracked files you want each worktree to have independently.

# Example entries (uncomment and customize):
# .env.local
# frontend/.env.local
# frontend/.husky/_
EOF
    echo -e "  ${GREEN}Created${RESET} $include_file"
    created=1
  else
    echo -e "  ${YELLOW}Skipped (exists):${RESET} $(basename "$include_file")"
  fi

  if [ ! -f "$symlink_file" ]; then
    cat > "$symlink_file" <<'EOF'
# .worktreesymlink — Glob patterns to symlink into new worktrees
# One pattern per line. Comments start with #. Blank lines are ignored.
# Patterns are resolved against the main worktree's root directory.
#
# Use for node_modules, build artifacts, or other large read-only directories
# you want all worktrees to share (saves disk space).
#
# ⚠️  Do not run yarn install in a worktree with symlinked node_modules.

# Example entries (uncomment and customize):
# node_modules
# frontend/node_modules
# frontend/*/node_modules
EOF
    echo -e "  ${GREEN}Created${RESET} $symlink_file"
    created=1
  else
    echo -e "  ${YELLOW}Skipped (exists):${RESET} $(basename "$symlink_file")"
  fi

  if [ $created -eq 1 ]; then
    echo -e "${GREEN}Init complete.${RESET} Edit the config files and customize for your project."
  else
    echo "Configuration files already exist."
  fi
}

function cmd_unsymlink() {
  local dest
  dest=$(git rev-parse --show-toplevel)
  local main
  main=$(get_main_worktree)
  local symlink_file="$main/.worktreesymlink"

  if [ "$main" = "$dest" ]; then
    echo "Already in main worktree, nothing to do."
    exit 0
  fi

  [ -f "$symlink_file" ] || { echo "No .worktreesymlink found."; exit 0; }

  echo -e "${BOLD}Removing symlinks...${RESET}"
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$pattern" in \#*) continue ;; esac
    shopt -s nullglob
    for src in "$main"/$pattern; do
      local rel="${src#$main/}"
      local dst="$dest/$rel"
      if [ -L "$dst" ]; then
        rm "$dst" && echo -e "  ${GREEN}Removed${RESET} $rel"
      fi
    done
    shopt -u nullglob
  done < "$symlink_file"
}

function cmd_ls() {
  local name="${1:-}"

  if [ -n "$name" ]; then
    local path
    if ! path=$(find_worktree_path "$name"); then
      echo "Error: no worktree named '$name'" >&2
      exit 1
    fi
    echo "$path"
    return 0
  fi

  require_fzf
  git worktree list | \
    fzf --no-mouse --no-sort | \
    awk '{print $1}'
}

function maybe_delete_branch() {
  local branch="$1"
  local main="$2"
  [ -z "$branch" ] && return 0
  local main_branch
  main_branch=$(git -C "$main" branch --show-current 2>/dev/null || echo "")
  [ "$branch" = "$main_branch" ] && return 0
  printf "Also delete branch '%s'? [y/N] " "$branch"
  read -r branch_answer || true
  if [[ "$branch_answer" =~ ^[Yy]$ ]]; then
    if git branch -d "$branch" 2>/dev/null; then
      echo -e "${GREEN}Deleted branch:${RESET} $branch"
    else
      printf "Branch has unmerged changes. Force delete? [y/N] "
      read -r force_branch
      if [[ "$force_branch" =~ ^[Yy]$ ]]; then
        git branch -D "$branch"
        echo -e "${GREEN}Force deleted branch:${RESET} $branch"
      fi
    fi
  fi
}

function remove_worktree() {
  local selected="$1"
  local force="${2:-0}"

  # Capture branch before removing (porcelain output is still valid after cd)
  local branch
  branch=$(git worktree list --porcelain | grep -A3 "^worktree $selected$" | grep '^branch ' | sed 's|branch refs/heads/||')
  local main
  main=$(get_main_worktree)

  if [ "$force" = "1" ]; then
    git worktree remove --force "$selected"
    echo -e "${GREEN}Removed:${RESET} $selected"
    return 0
  fi

  echo -e "${YELLOW}Delete worktree:${RESET} $selected"
  printf "Are you sure? [y/N] "
  read -r answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    if ! git worktree remove "$selected" 2>/dev/null; then
      echo -e "${YELLOW}Worktree has modified or untracked files.${RESET}"
      printf "Force remove anyway? [y/N] "
      read -r force_answer
      if [[ "$force_answer" =~ ^[Yy]$ ]]; then
        git worktree remove --force "$selected"
        echo -e "${GREEN}Force removed:${RESET} $selected"
      else
        echo "Aborted."
        return 0
      fi
    else
      echo -e "${GREEN}Removed:${RESET} $selected"
    fi
    maybe_delete_branch "$branch" "$main"
  else
    echo "Aborted."
  fi
}

function cmd_rm() {
  local name=""
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1 ;;
      *) name="$1" ;;
    esac
    shift
  done

  local main
  main=$(get_main_worktree)
  local current
  current=$(git rev-parse --show-toplevel)

  local selected
  if [ -n "$name" ]; then
    if ! selected=$(find_worktree_path "$name"); then
      echo "Error: no worktree named '$name'" >&2
      exit 1
    fi
  elif [ "$current" != "$main" ]; then
    # Inside a worktree: default to removing the one we're standing in
    selected="$current"
  else
    require_fzf
    selected=$(git worktree list | fzf --no-mouse --no-sort | awk '{print $1}')
    [ -z "$selected" ] && exit 0
  fi

  # git refuses to remove the worktree containing the cwd — step out first
  if [ "$current" = "$selected" ]; then
    cd "$main"
  fi

  remove_worktree "$selected" "$force"
}

# ── Main ──────────────────────────────────────────────────────────────────────
# Only dispatch when executed directly — sourcing the script (e.g. from tests)
# just loads the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    init)
      cmd_init
      ;;
    add)
      shift
      cmd_add "$@"
      ;;
    setup)
      cmd_setup
      ;;
    unsymlink)
      cmd_unsymlink
      ;;
    ls)
      shift
      cmd_ls "$@"
      ;;
    rm)
      shift
      cmd_rm "$@"
      ;;
    --help|-h|help)
      usage
      ;;
    "")
      usage
      ;;
    *)
      echo "Unknown command: $1"
      echo "Run 'wt --help' for usage."
      exit 1
      ;;
  esac
fi
