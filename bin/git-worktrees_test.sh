#!/usr/bin/env bash
#
# git-worktrees_test.sh - Integration tests for the wt worktree utility
#
# Creates a sandbox git repository in a temp directory and exercises the
# non-interactive command forms (wt add <name>, wt ls <name>, wt rm <name>).
# The fzf-based interactive forms are just shorthands for picking the same
# argument, so they are not covered here and fzf is not required to run tests.
#
# Usage:
#   ./git-worktrees_test.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$SCRIPT_DIR/git-worktrees.sh"

# ── Assertion helpers ─────────────────────────────────────────────────────────
function fail() {
  echo "❌ Test failed: $1"
  exit 1
}

function assert_equals() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" = "$actual" ]; then
    echo "✅ $message"
  else
    echo "❌ $message"
    echo "  Expected: '$expected'"
    echo "  Got:      '$actual'"
    exit 1
  fi
}

function strip_ansi() {
  sed $'s/\033\\[[0-9;]*m//g'
}

function assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  if echo "$haystack" | strip_ansi | grep -qF "$needle"; then
    echo "✅ $message"
  else
    echo "❌ $message"
    echo "  Expected to find: '$needle'"
    echo "  In:               '$haystack'"
    exit 1
  fi
}

function assert_file() {
  local path="$1" message="$2"
  [ -f "$path" ] && echo "✅ $message" || fail "$message (missing file: $path)"
}

function assert_dir() {
  local path="$1" message="$2"
  [ -d "$path" ] && echo "✅ $message" || fail "$message (missing dir: $path)"
}

function assert_symlink_to() {
  local path="$1" target="$2" message="$3"
  if [ ! -L "$path" ]; then
    fail "$message (not a symlink: $path)"
  fi
  local actual
  actual=$(readlink "$path")
  assert_equals "$target" "$actual" "$message"
}

function assert_not_exists() {
  local path="$1" message="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    fail "$message (unexpectedly exists: $path)"
  else
    echo "✅ $message"
  fi
}

# ── Sandbox setup ─────────────────────────────────────────────────────────────
# Layout: $TEST_DIR/main-repo is the main worktree; `wt add` creates sibling
# worktrees inside $TEST_DIR, so everything is cleaned up together.
function setup_sandbox() {
  TEST_DIR=$(mktemp -d)
  # Resolve symlinks (on macOS /var is a symlink to /private/var) so path
  # assertions match what git reports.
  TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
  MAIN="$TEST_DIR/main-repo"
  mkdir "$MAIN"
  cd "$MAIN"

  git init -q -b main
  git config --local user.email "test@example.com"
  git config --local user.name "Test User"

  # Committed project structure
  mkdir -p frontend/app-a frontend/app-b
  echo "# main repo" > README.md
  echo "console.log('a')" > frontend/app-a/index.js
  echo "console.log('b')" > frontend/app-b/index.js

  cat > .worktreeinclude <<'EOF'
# Files and directories to copy into new worktrees

frontend/.env.local
frontend/.husky/_
missing/file.txt
EOF

  cat > .worktreesymlink <<'EOF'
# Glob patterns to symlink into new worktrees

frontend/node_modules
frontend/*/node_modules
EOF

  git add .
  git commit -qm "Initial commit"

  # Untracked artifacts that .worktreeinclude / .worktreesymlink reference
  echo "SECRET=hunter2" > frontend/.env.local

  # Husky-style hook dir containing a self-referencing symlink, which makes
  # plain `cp -r` fail with a cycle error — must be copied with rsync.
  mkdir -p frontend/.husky/_
  echo "#!/bin/sh" > frontend/.husky/_/pre-commit
  ln -s . "frontend/.husky/_/_"

  # node_modules dirs with marker files so we can verify symlink targets
  mkdir -p frontend/node_modules frontend/app-a/node_modules frontend/app-b/node_modules
  echo "root" > frontend/node_modules/marker.txt
  echo "app-a" > frontend/app-a/node_modules/marker.txt
  echo "app-b" > frontend/app-b/node_modules/marker.txt
}

# ── Tests ─────────────────────────────────────────────────────────────────────
function test_init_creates_config_files() {
  echo
  echo "── test: wt init creates .worktreeinclude and .worktreesymlink ──"
  local test_repo="$TEST_DIR/init-test-repo"
  mkdir "$test_repo"
  cd "$test_repo"
  git init -qb main
  git config --local user.email "test@example.com"
  git config --local user.name "Test User"
  touch README.md && git add . && git commit -qm "init"

  "$WT" init

  assert_file "$test_repo/.worktreeinclude" "Init created .worktreeinclude"
  assert_file "$test_repo/.worktreesymlink" "Init created .worktreesymlink"
  assert_contains "$(cat "$test_repo/.worktreeinclude")" "# Example entries" ".worktreeinclude has example entries"
  assert_contains "$(cat "$test_repo/.worktreesymlink")" "# Example entries" ".worktreesymlink has example entries"
}

function test_init_idempotent() {
  echo
  echo "── test: wt init is idempotent (second run skips existing files) ──"
  cd "$TEST_DIR/init-test-repo"
  local output
  output=$("$WT" init)
  assert_contains "$output" "Skipped (exists):" "Existing files skipped"
  assert_contains "$output" "Configuration files already exist." "Idempotent message shown"
}

function test_init_only_in_main_worktree() {
  echo
  echo "── test: wt init only works in main worktree, not branch worktrees ──"
  cd "$MAIN"
  "$WT" add wt-init-guard > /dev/null
  cd "$TEST_DIR/wt-init-guard"

  local output
  if output=$("$WT" init 2>&1); then
    fail "wt init should fail in a branch worktree"
  fi
  assert_contains "$output" "must be run from the main worktree" "Error message shown"

  cd "$MAIN"
  "$WT" rm wt-init-guard --force < /dev/null > /dev/null
}

function test_add_creates_worktree_and_branch() {
  echo
  echo "── test: wt add creates worktree + branch ──"
  cd "$MAIN"
  "$WT" add wt-feature

  assert_dir "$TEST_DIR/wt-feature" "Worktree directory created at ../wt-feature"
  local branch
  branch=$(git -C "$TEST_DIR/wt-feature" rev-parse --abbrev-ref HEAD)
  assert_equals "wt-feature" "$branch" "Worktree is on branch wt-feature"
  assert_file "$TEST_DIR/wt-feature/README.md" "Tracked files checked out in worktree"
}

function test_add_processes_worktreeinclude() {
  echo
  echo "── test: wt add copies .worktreeinclude entries ──"
  local wt="$TEST_DIR/wt-feature"

  assert_file "$wt/frontend/.env.local" "Untracked .env.local copied into worktree"
  assert_equals "SECRET=hunter2" "$(cat "$wt/frontend/.env.local")" ".env.local contents intact"

  assert_dir "$wt/frontend/.husky/_" "Directory entry copied into worktree"
  assert_file "$wt/frontend/.husky/_/pre-commit" "File inside copied directory present"
  [ -L "$wt/frontend/.husky/_/_" ] || fail "Self-referencing symlink copied as symlink (rsync, no cp cycle)"
  echo "✅ Self-referencing symlink copied as symlink (rsync, no cp cycle)"
}

function test_add_skips_missing_include_entry() {
  echo
  echo "── test: missing .worktreeinclude entry is skipped, not fatal ──"
  cd "$MAIN"
  local output
  output=$("$WT" add wt-missing-check)
  assert_contains "$output" "Skipped (not found): missing/file.txt" "Missing entry reported as skipped"
  assert_contains "$output" "Copied" "Other entries still processed"
}

function test_add_processes_worktreesymlink_globs() {
  echo
  echo "── test: wt add symlinks .worktreesymlink globs against main ──"
  local wt="$TEST_DIR/wt-feature"

  assert_symlink_to "$wt/frontend/node_modules" "$MAIN/frontend/node_modules" \
    "Literal pattern: frontend/node_modules links to main"
  assert_symlink_to "$wt/frontend/app-a/node_modules" "$MAIN/frontend/app-a/node_modules" \
    "Glob pattern: app-a/node_modules links to main"
  assert_symlink_to "$wt/frontend/app-b/node_modules" "$MAIN/frontend/app-b/node_modules" \
    "Glob pattern: app-b/node_modules links to main"
  assert_equals "app-a" "$(cat "$wt/frontend/app-a/node_modules/marker.txt")" \
    "Symlinked node_modules resolves to main worktree contents"
}

function test_comments_and_blank_lines_ignored() {
  echo
  echo "── test: comments/blank lines in config files are ignored ──"
  cd "$MAIN"
  local output
  output=$("$WT" add wt-comments)
  # A comment line would surface as "Skipped (not found): # ..." if processed
  if echo "$output" | grep -q "#"; then
    fail "Comment lines should not be processed as entries"
  fi
  echo "✅ Comment lines not processed as entries"
}

function test_setup_in_existing_worktree() {
  echo
  echo "── test: wt setup applies config in an existing worktree ──"
  cd "$MAIN"
  # Create a bare worktree without running setup, using plain git
  git worktree add -q -b wt-manual "../wt-manual"
  local wt="$TEST_DIR/wt-manual"

  assert_not_exists "$wt/frontend/.env.local" "Plain git worktree has no include files yet"

  cd "$wt"
  "$WT" setup

  assert_file "$wt/frontend/.env.local" "wt setup copied include files"
  assert_symlink_to "$wt/frontend/node_modules" "$MAIN/frontend/node_modules" "wt setup created symlinks"
}

function test_setup_is_idempotent() {
  echo
  echo "── test: wt setup is idempotent (second run skips symlinks) ──"
  cd "$TEST_DIR/wt-manual"
  local output
  output=$("$WT" setup)
  assert_contains "$output" "Skipped (exists): frontend/node_modules" "Existing symlinks skipped on re-run"
  assert_contains "$output" "Setup complete" "Setup still completes successfully"
}

function test_setup_noop_in_main_worktree() {
  echo
  echo "── test: wt setup is a no-op in the main worktree ──"
  cd "$MAIN"
  local output
  output=$("$WT" setup)
  assert_contains "$output" "Already in main worktree, nothing to do." "Main worktree guard works for setup"
}

function test_symlink_skips_existing_real_dir() {
  echo
  echo "── test: existing real dir is not clobbered by symlinking ──"
  cd "$MAIN"
  git worktree add -q -b wt-existing "../wt-existing"
  local wt="$TEST_DIR/wt-existing"

  # Simulate a real yarn install in this worktree before setup runs
  mkdir -p "$wt/frontend/node_modules"
  echo "local install" > "$wt/frontend/node_modules/marker.txt"

  cd "$wt"
  local output
  output=$("$WT" setup)
  assert_contains "$output" "Skipped (exists): frontend/node_modules" "Real dir reported as skipped"
  [ -L "$wt/frontend/node_modules" ] && fail "Real dir must not be replaced by a symlink"
  assert_equals "local install" "$(cat "$wt/frontend/node_modules/marker.txt")" "Real dir contents untouched"
}

function test_unsymlink_removes_only_symlinks() {
  echo
  echo "── test: wt unsymlink removes symlinks but never real dirs ──"
  local wt="$TEST_DIR/wt-existing"
  cd "$wt"
  # State from previous test: app-a/app-b are symlinks, frontend/node_modules is real
  "$WT" unsymlink

  assert_not_exists "$wt/frontend/app-a/node_modules" "Symlink removed (app-a)"
  assert_not_exists "$wt/frontend/app-b/node_modules" "Symlink removed (app-b)"
  assert_dir "$wt/frontend/node_modules" "Real directory survives unsymlink"
  assert_equals "local install" "$(cat "$wt/frontend/node_modules/marker.txt")" "Real dir contents untouched"

  # Main worktree contents must be untouched
  assert_file "$MAIN/frontend/app-a/node_modules/marker.txt" "Main worktree node_modules untouched"
}

function test_unsymlink_noop_in_main_worktree() {
  echo
  echo "── test: wt unsymlink is a no-op in the main worktree ──"
  cd "$MAIN"
  local output
  output=$("$WT" unsymlink)
  assert_contains "$output" "Already in main worktree, nothing to do." "Main worktree guard works for unsymlink"
  assert_dir "$MAIN/frontend/node_modules" "Main node_modules untouched"
}

function test_ls_with_name() {
  echo
  echo "── test: wt ls <name> prints worktree path non-interactively ──"
  cd "$MAIN"
  local output
  output=$("$WT" ls wt-feature)
  assert_equals "$TEST_DIR/wt-feature" "$output" "wt ls <name> prints the worktree path"

  # Works from inside another worktree too
  cd "$TEST_DIR/wt-manual"
  output=$("$WT" ls wt-feature)
  assert_equals "$TEST_DIR/wt-feature" "$output" "wt ls <name> works from inside another worktree"
}

function test_ls_unknown_name_errors() {
  echo
  echo "── test: wt ls <unknown> exits 1 with error ──"
  cd "$MAIN"
  local output
  if output=$("$WT" ls no-such-worktree 2>&1); then
    fail "wt ls should exit non-zero for unknown worktree"
  fi
  assert_contains "$output" "no worktree named 'no-such-worktree'" "Error message names the missing worktree"
}

function test_rm_with_name_confirmed() {
  echo
  echo "── test: wt rm <name> deletes after y confirmation ──"
  cd "$MAIN"
  # wt-comments worktree is clean (only symlinks/includes); remove its links
  # first so `git worktree remove` sees it as clean... actually includes make
  # it dirty, so confirm both prompts (delete + force).
  local output
  output=$(printf "y\ny\n" | "$WT" rm wt-comments)
  assert_contains "$output" "Force removed:" "wt rm reports removal"
  assert_not_exists "$TEST_DIR/wt-comments" "Worktree directory deleted"
  if git -C "$MAIN" worktree list | grep -q "wt-comments"; then
    fail "Worktree should be gone from git worktree list"
  fi
  echo "✅ Worktree gone from git worktree list"
}

function test_rm_with_name_aborts_on_no() {
  echo
  echo "── test: wt rm <name> aborts on n ──"
  cd "$MAIN"
  local output
  output=$(echo "n" | "$WT" rm wt-missing-check)
  assert_contains "$output" "Aborted." "wt rm reports abort"
  assert_dir "$TEST_DIR/wt-missing-check" "Worktree still exists after abort"
}

function test_rm_force_skips_prompts() {
  echo
  echo "── test: wt rm <name> --force removes dirty worktree without prompts ──"
  cd "$MAIN"
  echo "uncommitted" > "$TEST_DIR/wt-missing-check/dirty.txt"
  local output
  output=$("$WT" rm wt-missing-check --force < /dev/null)
  assert_contains "$output" "Removed:" "Force removal reported"
  assert_not_exists "$TEST_DIR/wt-missing-check" "Dirty worktree deleted with --force"
}

function test_rm_without_name_inside_worktree() {
  echo
  echo "── test: wt rm without name inside a worktree removes that worktree ──"
  cd "$MAIN"
  "$WT" add wt-rm-self > /dev/null
  cd "$TEST_DIR/wt-rm-self"

  local output
  # The worktree is dirty (includes/symlinks), so confirm both prompts
  output=$(printf "y\ny\n" | "$WT" rm)
  assert_contains "$output" "$TEST_DIR/wt-rm-self" "Defaulted to the current worktree without fzf"
  assert_not_exists "$TEST_DIR/wt-rm-self" "Current worktree removed"
}

function test_rm_without_name_inside_worktree_subdir() {
  echo
  echo "── test: wt rm without name works from a subdirectory of the worktree ──"
  cd "$MAIN"
  "$WT" add wt-rm-subdir > /dev/null
  cd "$TEST_DIR/wt-rm-subdir/frontend"

  local output
  output=$("$WT" rm --force < /dev/null)
  assert_contains "$output" "$TEST_DIR/wt-rm-subdir" "Resolved current worktree from subdirectory"
  assert_not_exists "$TEST_DIR/wt-rm-subdir" "Worktree removed from within its subdirectory"
}

function test_rm_without_name_abort_keeps_worktree() {
  echo
  echo "── test: wt rm without name aborts on n and keeps the worktree ──"
  cd "$MAIN"
  "$WT" add wt-rm-abort > /dev/null
  cd "$TEST_DIR/wt-rm-abort"

  local output
  output=$(echo "n" | "$WT" rm)
  assert_contains "$output" "Aborted." "Abort reported"
  assert_dir "$TEST_DIR/wt-rm-abort" "Worktree kept after abort"

  cd "$MAIN"
  "$WT" rm wt-rm-abort --force < /dev/null > /dev/null
}

function test_rm_unknown_name_errors() {
  echo
  echo "── test: wt rm <unknown> exits 1 with error ──"
  cd "$MAIN"
  local output
  if output=$("$WT" rm no-such-worktree 2>&1 < /dev/null); then
    fail "wt rm should exit non-zero for unknown worktree"
  fi
  assert_contains "$output" "no worktree named 'no-such-worktree'" "Error message names the missing worktree"
}

function test_add_without_name_errors() {
  echo
  echo "── test: wt add without name exits 1 with usage ──"
  cd "$MAIN"
  local output
  if output=$("$WT" add 2>&1); then
    fail "wt add without name should exit non-zero"
  fi
  assert_contains "$output" "missing worktree name" "Error message shown"
  assert_contains "$output" "Usage: wt add <name>" "Usage hint shown"
}

function test_unknown_command_errors() {
  echo
  echo "── test: unknown command exits 1 ──"
  cd "$MAIN"
  local output
  if output=$("$WT" frobnicate 2>&1); then
    fail "Unknown command should exit non-zero"
  fi
  assert_contains "$output" "Unknown command: frobnicate" "Unknown command reported"
}

function test_add_from_subdirectory() {
  echo
  echo "── test: wt add from a subdirectory still creates worktree next to repo root ──"
  cd "$MAIN/frontend/app-a"
  "$WT" add wt-from-subdir

  assert_dir "$TEST_DIR/wt-from-subdir" "Worktree created as sibling of repo root, not of subdirectory"
  assert_not_exists "$MAIN/frontend/wt-from-subdir" "No worktree created inside the repo"
  assert_symlink_to "$TEST_DIR/wt-from-subdir/frontend/node_modules" "$MAIN/frontend/node_modules" \
    "Symlinks applied when adding from subdirectory"
}

function test_add_in_repo_without_config_files() {
  echo
  echo "── test: wt add works in a repo with no .worktreeinclude/.worktreesymlink ──"
  local plain="$TEST_DIR/plain-repo"
  mkdir "$plain"
  cd "$plain"
  git init -q -b main
  git config --local user.email "test@example.com"
  git config --local user.name "Test User"
  echo "plain" > README.md
  git add . && git commit -qm "init"

  "$WT" add wt-plain
  assert_dir "$TEST_DIR/wt-plain" "Worktree created without config files present"
  local branch
  branch=$(git -C "$TEST_DIR/wt-plain" rev-parse --abbrev-ref HEAD)
  assert_equals "wt-plain" "$branch" "Branch created without config files present"
}

# ── Run ───────────────────────────────────────────────────────────────────────
echo "Setting up sandbox..."
setup_sandbox
echo "Sandbox: $TEST_DIR"

test_add_creates_worktree_and_branch
test_add_processes_worktreeinclude
test_add_skips_missing_include_entry
test_add_processes_worktreesymlink_globs
test_comments_and_blank_lines_ignored
test_setup_in_existing_worktree
test_setup_is_idempotent
test_setup_noop_in_main_worktree
test_symlink_skips_existing_real_dir
test_unsymlink_removes_only_symlinks
test_unsymlink_noop_in_main_worktree
test_ls_with_name
test_ls_unknown_name_errors
test_rm_with_name_confirmed
test_rm_with_name_aborts_on_no
test_rm_force_skips_prompts
test_rm_without_name_inside_worktree
test_rm_without_name_inside_worktree_subdir
test_rm_without_name_abort_keeps_worktree
test_rm_unknown_name_errors
test_init_creates_config_files
test_init_idempotent
test_init_only_in_main_worktree
test_add_without_name_errors
test_unknown_command_errors
test_add_from_subdirectory
test_add_in_repo_without_config_files

echo
echo "🎉 All tests passed!"

echo "Cleaning up sandbox..."
cd / && rm -rf "$TEST_DIR"
