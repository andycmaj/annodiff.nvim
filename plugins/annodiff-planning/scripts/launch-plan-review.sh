#!/usr/bin/env bash
# Open a plan review in Neovim (annodiff.nvim) and block until Neovim exits.
# usage: launch-plan-review.sh <plan-repo>
#   <plan-repo>: a git repo whose HEAD holds the previous revision of plan.md (empty on the
#   first round) and whose worktree holds the new one. The review is `:Annodiff HEAD`, so
#   later rounds show what changed since the last revision, and plan.md is editable.
# Prints the annotations (revdiff ## format) to stdout. Exit 10 = annotations captured,
# 0 = none, anything else = the review did not happen (the hook fails open).
# Same contract as revdiff-planning's launch-plan-review.sh, so it can be overridden the
# same way: an executable $CLAUDE_PLUGIN_DATA/scripts/launch-plan-review.sh wins.
set -euo pipefail

repo="${1:?usage: launch-plan-review.sh <plan-repo>}"
[ -d "$repo/.git" ] || { echo "error: not a plan repo: $repo" >&2; exit 2; }
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || { echo "error: not inside tmux" >&2; exit 2; }
command -v nvim >/dev/null 2>&1 || { echo "error: nvim not found in PATH" >&2; exit 2; }

# Where annodiff.nvim's Lua lives. This plugin is installed from a subdirectory, so it
# does not ship lua/ itself. First found: $ANNODIFF_RTP, the repo this script sits in
# (a checkout, or --plugin-dir), the newest installed annodiff Claude plugin. Else rely
# on the user's own Neovim config having annodiff.nvim.
rtp="${ANNODIFF_RTP:-}"
if [ -z "$rtp" ]; then
  here="$(cd "$(dirname "$0")/../../.." && pwd -P)"
  if [ -f "$here/lua/annodiff/init.lua" ]; then
    rtp="$here"
  else
    for d in "${HOME:-}"/.claude/plugins/cache/*/annodiff/*/; do
      [ -f "$d/lua/annodiff/init.lua" ] || continue
      if [ -z "$rtp" ] || [ "$d" -nt "$rtp" ]; then rtp="${d%/}"; fi
    done
  fi
fi
vimcmd="Annodiff HEAD"
[ -n "$rtp" ] && vimcmd="set rtp^=$rtp | runtime plugin/annodiff.lua | $vimcmd"
# Plan notes go back through this hook, not to the user's send command.
cmd="env -u ANNODIFF_SEND_COMMAND -u REVDIFF_POST_FLUSH_COMMAND ANNODIFF_SEND_ON_CLOSE=0 nvim -c $(printf '%q' "$vimcmd")"

out="$repo/.git/annodiff/annotations.md"
rm -f "$out"

tools="$(tmux display-message -p -t "$TMUX_PANE" '#{@riker_tools}' 2>/dev/null || true)"
[ -n "$tools" ] || tools="$(tmux display-message -p -t "$TMUX_PANE" '#{@aug_tools}' 2>/dev/null || true)"
if [ -n "$tools" ]; then
  # a riker task window: a zoomed split of this window, waited on
  eval "$tools pane --zoom --wait --cwd $(printf '%q' "$repo") -- sh -c $(printf '%q' "$cmd")" >/dev/null || true
else
  pane="$(tmux new-window -P -F '#{pane_id}' -n plan-review -c "$repo" "$cmd")"
  # poll rather than `tmux wait-for`: a killed window must not leave us waiting
  while tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane"; do sleep 0.5; done
fi

if [ -s "$out" ]; then
  cat "$out"
  exit 10
fi
exit 0
