#!/usr/bin/env bash
# Open :Annodiff in Neovim beside the calling Claude pane. Notes sent with \s (or O in
# the tree), and any unsent notes on close, are pasted back into that pane.
# usage: open.sh [annodiff args...]   (default: HEAD, or HEAD~1 when the tree is clean)
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
plugin="$(cd "$dir/../../.." && pwd)" # this repo; loaded after the user's config so it wins
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || { echo "error: not inside tmux" >&2; exit 1; }
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not in a git repo" >&2; exit 1; }
if [ $# -eq 0 ]; then
  if [ -n "$(git -C "$root" status --porcelain)" ]; then set -- HEAD; else set -- HEAD~1; fi
fi
args=""; for a in "$@"; do args+=" $(printf '%q' "$a")"; done
env_prefix="ANNODIFF_SEND_COMMAND=$(printf '%q' "$(printf '%q' "$dir/deliver.sh") $(printf '%q' "$TMUX_PANE")") ANNODIFF_SEND_ON_CLOSE=1"
# inline agent threads fork from this Claude session
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && env_prefix+=" ANNODIFF_AGENT_PARENT_SESSION=$(printf '%q' "claude:$CLAUDE_CODE_SESSION_ID")"
vimcmd="set rtp^=$plugin | runtime plugin/annodiff.lua | Annodiff$args"
cmd="env $env_prefix nvim -c $(printf '%q' "$vimcmd")"
# inside an aug task window: a zoomed split of this window, so it shows in aug's viewer
tools="$(tmux display-message -p -t "$TMUX_PANE" '#{@aug_tools}' 2>/dev/null || true)"
if [ -n "$tools" ]; then
  eval "$tools pane --zoom --cwd $(printf '%q' "$root") -- sh -c $(printf '%q' "$cmd")" >/dev/null
  echo "opened annodiff ($*) in a zoomed split of this aug pane, in $root; notes will be sent to pane $TMUX_PANE"
  exit 0
fi
tmux new-window -n annodiff -c "$root" "$cmd"
echo "opened annodiff ($*) in $root; notes will be sent to pane $TMUX_PANE"
