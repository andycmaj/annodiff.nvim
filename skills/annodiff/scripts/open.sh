#!/usr/bin/env bash
# Open :Annodiff in Neovim beside the calling Claude pane. Notes sent with \s (or O in
# the tree), and any unsent notes on close, are pasted back into that pane.
# usage: open.sh [annodiff args...]
#   No args: pick the review like revdiff's detect-ref.sh (see detect_args below).
#   When that is ambiguous, nothing opens and "needs_ask: true" is printed with the choices.
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd -P)" # physical: the skill may be a symlink into this repo

# User override, as in revdiff's launcher chain: an executable
# $CLAUDE_PLUGIN_DATA/scripts/open.sh replaces this one. No project-level layer:
# a repo must not be able to run code when the skill starts.
override="${CLAUDE_PLUGIN_DATA:-}/scripts/open.sh"
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -f "$override" ] && [ -x "$override" ] \
  && [ "$(cd "$(dirname "$override")" && pwd)" != "$dir" ] && [ -z "${ANNODIFF_OPEN_OVERRIDDEN:-}" ]; then
  ANNODIFF_OPEN_OVERRIDDEN=1 exec "$override" "$@"
fi

plugin="$(cd "$dir/../../.." && pwd)" # this repo; loaded after the user's config so it wins
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || { echo "error: not inside tmux" >&2; exit 1; }
command -v nvim >/dev/null 2>&1 || { echo "error: nvim not found in PATH" >&2; exit 1; }
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not in a git repo" >&2; exit 1; }

# revdiff's detect-ref.sh decision table, in annodiff's terms. annodiff's right side is
# the worktree unless a range is given, so "uncommitted" is `HEAD` (staged + unstaged)
# and "branch vs main" is the merge base against the worktree (commits + uncommitted).
detect_args() {
  git -C "$root" rev-parse --verify -q HEAD >/dev/null || { echo "error: no commits yet" >&2; exit 1; }
  local branch main="" remote_head base dirty=""
  branch="$(git -C "$root" rev-parse --abbrev-ref HEAD)"
  if remote_head="$(git -C "$root" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)"; then
    main="${remote_head##refs/remotes/origin/}"
  elif git -C "$root" show-ref --verify -q refs/heads/main; then
    main=main
  elif git -C "$root" show-ref --verify -q refs/heads/master; then
    main=master
  fi
  [ -n "$(git -C "$root" status --porcelain)" ] && dirty=1
  if [ -z "$main" ] || [ "$branch" = "$main" ] || [ "$branch" = HEAD ]; then
    if [ -n "$dirty" ]; then args=(HEAD); else args=(HEAD~1); fi
    return
  fi
  base="$(git -C "$root" merge-base "$main" HEAD 2>/dev/null \
    || git -C "$root" merge-base "origin/$main" HEAD 2>/dev/null || true)"
  if [ -z "$base" ]; then
    if [ -n "$dirty" ]; then args=(HEAD); else args=(HEAD~1); fi
    return
  fi
  base="$(git -C "$root" rev-parse --short "$base")"
  if [ -z "$dirty" ]; then
    args=("$base")
    return
  fi
  echo "branch: $branch"
  echo "main_branch: $main"
  echo "needs_ask: true"
  echo "uncommitted_args: HEAD"
  echo "branch_args: $base"
  echo "Feature branch with uncommitted changes: ask whether to review only the uncommitted changes (open.sh HEAD) or the whole branch against $main, uncommitted included (open.sh $base)."
  exit 0
}

args=("$@")
[ $# -eq 0 ] && detect_args

argstr=""; for a in "${args[@]}"; do argstr+=" $(printf '%q' "$a")"; done
env_prefix="ANNODIFF_SEND_COMMAND=$(printf '%q' "$(printf '%q' "$dir/deliver.sh") $(printf '%q' "$TMUX_PANE")") ANNODIFF_SEND_ON_CLOSE=1"
# inline agent threads fork from this Claude session
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && env_prefix+=" ANNODIFF_AGENT_PARENT_SESSION=$(printf '%q' "claude:$CLAUDE_CODE_SESSION_ID")"
vimcmd="set rtp^=$plugin | runtime plugin/annodiff.lua | Annodiff$argstr"
cmd="env $env_prefix nvim -c $(printf '%q' "$vimcmd")"
# inside a riker (formerly aug) task window: a zoomed split of this window, so it shows in its viewer
tools="$(tmux display-message -p -t "$TMUX_PANE" '#{@riker_tools}' 2>/dev/null || true)"
[ -n "$tools" ] || tools="$(tmux display-message -p -t "$TMUX_PANE" '#{@aug_tools}' 2>/dev/null || true)"
if [ -n "$tools" ]; then
  eval "$tools pane --zoom --cwd $(printf '%q' "$root") -- sh -c $(printf '%q' "$cmd")" >/dev/null
  echo "opened annodiff (${args[*]}) in a zoomed split of this pane, in $root; notes will be sent to pane $TMUX_PANE"
  exit 0
fi
tmux new-window -n annodiff -c "$root" "$cmd"
echo "opened annodiff (${args[*]}) in a new tmux window, in $root; notes will be sent to pane $TMUX_PANE"
