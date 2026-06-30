#!/usr/bin/env bash
# Installs the wt shell function into ~/.zshrc

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WORKTREES_SCRIPT="$SCRIPT_DIR/git-worktrees.sh"

chmod +x "$WORKTREES_SCRIPT"

ZSHRC="$HOME/.zshrc"

# Check if already installed
if grep -q "git-worktrees" "$ZSHRC" 2>/dev/null; then
  echo "wt is already installed in $ZSHRC"
  exit 0
fi

cat >> "$ZSHRC" <<EOF

# git-worktrees — worktree navigation utility
# https://github.com/dagjomar/git-worktrees
wt() {
  local script="$WORKTREES_SCRIPT"
  local dir
  case "\${1:-}" in
    ls)
      dir=\$("\$script" "\$@") && [ -n "\$dir" ] && cd "\$dir"
      ;;
    add)
      "\$script" "\$@" || return \$?
      dir=\$("\$script" ls "\${2:-}" 2>/dev/null) && [ -n "\$dir" ] && cd "\$dir"
      ;;
    rm)
      local main
      main=\$(command git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)
      "\$script" "\$@"
      # If we just removed the worktree we were standing in, move to main
      [ -d "\$PWD" ] || cd "\$main"
      ;;
    *)
      "\$script" "\$@"
      ;;
  esac
}
EOF

echo "✅ wt installed successfully in $ZSHRC"
echo "Run 'source ~/.zshrc' or open a new terminal to start using it."
echo
echo "Examples:"
echo "  wt --help"
echo "  wt add my-feature"
echo "  wt ls"
