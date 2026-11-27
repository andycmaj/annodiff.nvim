#!/usr/bin/env bash
# Open :Annodiff in Neovim over or beside the calling Claude pane: a zoomed split in a Riker
# task window, else a tmux popup over this pane (as revdiff opens), else a new tmux window.
# env: ANNODIFF_POPUP=0 never opens a popup (a new window instead);
#      ANNODIFF_POPUP_WIDTH / ANNODIFF_POPUP_HEIGHT size it (tmux sizes: 90% default, or cells).
# Notes sent with \s (or O in the tree), and any unsent notes on close, are pasted back
# into that pane; every close
# (and a Neovim exit with no review closed) pastes a line saying so, notes or not.
# One review at a time per Claude pane: a second open.sh is refused until the first closes.
# usage: open.sh [annodiff args...]
#   No args: nothing opens; "needs_ask: true" is printed with the kinds of diff that
#   apply here (see choices below), for the skill to ask which one.
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
# One review per Claude pane: refuse while one opened from this pane is still open, before
# anything is asked or opened (review-lock.sh; a close or Neovim exit frees it).
if ! busy="$("$dir/review-lock.sh" check "$TMUX_PANE")"; then
  label="${busy%%$'\t'*}" where="${busy#*$'\t'}"
  case "$where" in starting) where="still starting" ;; pid:*) where="in a tmux popup" ;; *) where="pane $where" ;; esac
  echo "error: a review opened from this pane is still open ($label, $where): wait for its close message (the user sends notes and closes it, or \\q sends and quits), then open this one" >&2
  exit 1
fi
# A document instead of a diff: `--doc <file> [ref]`, or an existing file as the first
# argument (optionally followed by a ref): a markdown file always, any other file unless
# its name resolves as a commit (a real ref wins), as doc.parse_args decides. The file can
# be anywhere, in a repo or not (an agent's message written to a scratch dir); Neovim runs
# from its repo, else from its directory.
doc=""
for a in "$@"; do [ "$a" = --doc ] && doc=1; done
if [ -z "$doc" ] && [ $# -ge 1 ] && [ -f "$1" ]; then
  case "$1" in
    *.md | *.markdown | *.mdx | *.mkd | *.mdown) doc=1 ;;
    *) git rev-parse --verify --quiet --end-of-options "$1^{commit}" >/dev/null 2>&1 || doc=1 ;;
  esac
fi
if [ -n "$doc" ]; then
  file="" ref=""
  for a in "$@"; do
    case "$a" in
      --doc | --inline | --split) ;;
      --*) echo "error: --doc takes a file and a ref, not $a" >&2; exit 1 ;;
      *) if [ -z "$file" ]; then file="$a"; elif [ -z "$ref" ]; then ref="$a"; fi ;;
    esac
  done
  [ -n "$file" ] && [ -f "$file" ] || { echo "error: not a file: ${file:-(none given)}" >&2; exit 1; }
  file="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
  root="$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null)" || root="$(dirname "$file")"
  doc_args=(--doc "$file")
  [ -n "$ref" ] && doc_args+=("$ref")
else
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not in a git repo" >&2; exit 1; }
fi

# The default branch, as annodiff's --base and Plannotator pick it: origin's default
# (origin/HEAD) when fetched, else origin/main, main, origin/master, master.
default_branch() {
  local ref
  if ref="$(git -C "$root" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" \
    && git -C "$root" show-ref --verify -q "$ref"; then
    echo "${ref#refs/remotes/}"
    return
  fi
  for ref in refs/remotes/origin/main refs/heads/main refs/remotes/origin/master refs/heads/master; do
    if git -C "$root" show-ref --verify -q "$ref"; then
      ref="${ref#refs/remotes/}"
      echo "${ref#refs/heads/}"
      return
    fi
  done
}

# No args: nothing opens. Print the kinds of diff that apply here, most likely first,
# for the skill to ask about (as Plannotator's review offers them):
#   uncommitted changes (HEAD vs worktree)        open.sh HEAD   (clean tree: the last commit, HEAD~1)
#   everything since the base branch              open.sh --base <branch>
#   a pull request (this branch's, or any)        open.sh --pr [N|URL]
#   any ref or range                              open.sh <ref> | A..B | A...B | --staged
choices() {
  git -C "$root" rev-parse --verify -q HEAD >/dev/null || { echo "error: no commits yet" >&2; exit 1; }
  local branch base="" mb="" ahead=0 dirty="" files pr="" opts=()
  branch="$(git -C "$root" rev-parse --abbrev-ref HEAD)"
  base="$(default_branch)"
  files="$(git -C "$root" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  [ "$files" -gt 0 ] && dirty=1
  if [ -n "$base" ] && [ "$branch" != HEAD ] && [ "$branch" != "$base" ] && [ "origin/$branch" != "$base" ] \
    && mb="$(git -C "$root" merge-base "$base" HEAD 2>/dev/null)"; then
    ahead="$(git -C "$root" rev-list --count "$mb..HEAD")"
  else
    mb=""
  fi
  if [ -n "$mb" ] && { [ "$ahead" -gt 0 ] || [ -n "$dirty" ]; }; then
    local what="$ahead commit(s) on $branch"
    [ -n "$dirty" ] && what+=" plus uncommitted changes"
    [ "$ahead" -eq 0 ] && what="no commits on $branch yet, so the uncommitted changes"
    opts+=("Everything since $base | --base $base | $what: the merge base $(git -C "$root" rev-parse --short "$mb") vs the worktree")
  fi
  if [ -n "$dirty" ]; then
    opts+=("Uncommitted changes | HEAD | $files file(s), staged and unstaged: HEAD vs the worktree")
  elif git -C "$root" rev-parse --verify -q HEAD~1 >/dev/null; then
    opts+=("Last commit | HEAD~1 | nothing uncommitted; $(git -C "$root" log -1 --format=%s | tr '|' '/')")
  fi
  if command -v gh >/dev/null 2>&1; then
    [ "$branch" != HEAD ] && pr="$(cd "$root" && gh pr view --json number,baseRefName,headRefOid,title \
      --jq '[.number, .baseRefName, .headRefOid, .title] | @tsv' 2>/dev/null || true)"
    if [ -n "$pr" ]; then
      local num pbase phead ptitle where
      IFS=$'\t' read -r num pbase phead ptitle <<<"$pr"
      if [ "$phead" = "$(git -C "$root" rev-parse HEAD)" ] && [ -z "$dirty" ]; then
        where="checked out here, so edits show live"
      else
        where="fetched read-only: its pushed head, not this worktree"
      fi
      opts+=("PR #$num: $(printf '%s' "$ptitle" | tr '|' '/' | cut -c1-60) | --pr $num | the PR as GitHub shows it, head vs the merge base with $pbase; $where")
    else
      opts+=("A pull request | --pr <number or URL> | ask which PR; it is fetched read-only (nothing checked out) and diffed against its base")
    fi
  fi
  opts+=("A ref or range | <ref> | ask which: a ref vs the worktree (HEAD~3, main), A..B, A...B, or --staged [ref]")
  echo "needs_ask: true"
  echo "branch: $branch"
  [ -n "$base" ] && echo "base_branch: $base"
  echo "Ask which diff to review (first option recommended), then run open.sh with the chosen option's args:"
  local o; for o in "${opts[@]}"; do echo "option: $o"; done
  exit 0
}

args=("$@")
[ -n "$doc" ] && args=("${doc_args[@]}")
[ $# -eq 0 ] && choices
# a bare PR number (#12, 12) or PR URL is shorthand for --pr
if [ $# -eq 1 ] && [[ "$1" =~ ^#?[0-9]+$ || "$1" =~ ^https?://[^/]+/[^/]+/[^/]+/pull/[0-9]+ ]]; then
  args=(--pr "${1#\#}")
fi
case " ${args[*]} " in *" --pr "* | *" --pr="*)
  command -v gh >/dev/null 2>&1 || { echo "error: --pr needs the GitHub CLI (gh) in PATH" >&2; exit 1; } ;;
esac

argstr=""; for a in "${args[@]}"; do argstr+=" $(printf '%q' "$a")"; done
# What notes and close messages name as their review, so two reviews in a row never mix:
# the document's file name (and ref), else the diff args.
if [ -n "$doc" ]; then label="$(basename "$file")${ref:+ $ref}"; else label="${args[*]}"; fi
deliver="$(printf '%q' "$dir/deliver.sh") $(printf '%q' "$TMUX_PANE")"
# always: every close runs deliver.sh, notes or not, so this session hears the review
# ended (no annotations = no edits or suggestions) instead of waiting on nothing
env_prefix="ANNODIFF_SEND_COMMAND=$(printf '%q' "$deliver") ANNODIFF_SEND_ON_CLOSE=always ANNODIFF_REVIEW_LABEL=$(printf '%q' "$label")"
# inline agent threads fork from this Claude session
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && env_prefix+=" ANNODIFF_AGENT_PARENT_SESSION=$(printf '%q' "claude:$CLAUDE_CODE_SESSION_ID")"
vimcmd="set rtp^=$plugin | runtime plugin/annodiff.lua | Annodiff$argstr"
# When Neovim exits without any review having closed (it failed to open: no changes, a
# bad ref), deliver.sh says so too; the mark tells it a close already reported.
mark="$(mktemp -d "${TMPDIR:-/tmp}/annodiff-closed.XXXXXX")/closed"
# The review pane attaches itself to this pane's lock as it starts; deliver.sh frees the
# lock when the review closes or Neovim exits.
attach="$(printf '%q' "$dir/review-lock.sh") attach $(printf '%q' "$TMUX_PANE")"
cmd="export ANNODIFF_CLOSED_MARK=$(printf '%q' "$mark") ANNODIFF_REVIEW_LABEL=$(printf '%q' "$label"); $attach; env $env_prefix nvim -c $(printf '%q' "$vimcmd"); ANNODIFF_SEND_REASON=exit $deliver </dev/null"
"$dir/review-lock.sh" take "$TMUX_PANE" "$label"
# inside a riker (formerly aug) task window: a zoomed split of this window, so it shows in its viewer
tools="$(tmux display-message -p -t "$TMUX_PANE" '#{@riker_tools}' 2>/dev/null || true)"
[ -n "$tools" ] || tools="$(tmux display-message -p -t "$TMUX_PANE" '#{@aug_tools}' 2>/dev/null || true)"
if [ -n "$tools" ]; then
  eval "$tools pane --zoom --cwd $(printf '%q' "$root") -- sh -c $(printf '%q' "$cmd")" >/dev/null
  echo "opened annodiff (${args[*]}) in a zoomed split of this pane, in $root; notes will be sent to pane $TMUX_PANE"
  exit 0
fi

# Plain tmux: a popup over this pane, so this Claude session stays in view behind the
# review. It shows on the client looking at this pane's window (the most recently active
# one when several are), never on a client elsewhere; with none, a tmux older than 3.3,
# or ANNODIFF_POPUP=0, a new window as before.
popup_client() {
  case "${ANNODIFF_POPUP:-1}" in 0 | false | no | off) return 1 ;; esac
  [[ "$(tmux -V 2>/dev/null)" =~ ([0-9]+)\.([0-9]+) ]] || return 1
  [ "${BASH_REMATCH[1]}" -gt 3 ] || { [ "${BASH_REMATCH[1]}" -eq 3 ] && [ "${BASH_REMATCH[2]}" -ge 3 ]; } || return 1
  local win
  win="$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)" && [ -n "$win" ] || return 1
  # control-mode clients (iTerm2 -CC) cannot draw a popup
  tmux list-clients -F '#{client_activity}	#{client_control_mode}	#{window_id}	#{client_name}' 2>/dev/null \
    | sort -rn | awk -F '\t' -v w="$win" '$2 != 1 && $3 == w { print $4; found = 1; exit } END { exit !found }'
}
if client="$(popup_client)"; then
  # A popup blocks whoever opens it until it closes, so a tmux job opens it, not this
  # script: the agent gets its answer now, and the job outlives this shell. When the popup
  # closes (any way: \q, :qa, killed) the job reports the exit as the window's shell does,
  # after Neovim. The job's shell holds the review lock for the popup (a popup is no
  # pane); the review inside learns it through -e, so its close frees the lock.
  # A client shows one popup at a time and tmux drops a second one without a word: when an
  # earlier review's Neovim is still up in one (its review closed, so the lock is free),
  # the popup never runs and this review opens in a new window, as without a popup.
  # The job is a script file because run-shell expands #{formats} in its command.
  q() { printf '%q' "$1"; }
  job="$(mktemp "${TMPDIR:-/tmp}/annodiff-popup.XXXXXX")"
  started="$(dirname "$mark")/started"
  inner="export ANNODIFF_CLOSED_MARK=$(q "$mark") ANNODIFF_REVIEW_LABEL=$(q "$label"); : > $(q "$started"); exec env $env_prefix nvim -c $(q "$vimcmd")"
  {
    echo "rm -f $(q "$job")"
    echo "export ANNODIFF_REVIEW_OWNER=pid:\$\$ ANNODIFF_CLOSED_MARK=$(q "$mark") ANNODIFF_REVIEW_LABEL=$(q "$label")"
    echo "$attach"
    echo "$(q "$(command -v tmux)") display-popup -E -c $(q "$client") -w $(q "${ANNODIFF_POPUP_WIDTH:-90%}")" \
      "-h $(q "${ANNODIFF_POPUP_HEIGHT:-90%}") -d $(q "$root") -T $(q " annodiff: ${label//#/##} ")" \
      "-e ANNODIFF_REVIEW_OWNER=\$ANNODIFF_REVIEW_OWNER -- sh -c $(q "$inner")"
    echo "if [ -e $(q "$started") ]; then"
    echo "  rm -f $(q "$started")"
    echo "  ANNODIFF_SEND_REASON=exit $deliver </dev/null"
    echo "else"
    echo "  $(q "$(command -v tmux)") new-window -n annodiff -c $(q "$root") $(q "$cmd")"
    echo "fi"
    echo "exit 0"
  } > "$job"
  # quiet: run-shell shows a job's output (or a failure) over the pane it targets
  tmux run-shell -b -t "$TMUX_PANE" "$(q "$BASH" | sed 's/#/##/g') $(q "$job" | sed 's/#/##/g') >/dev/null 2>&1"
  echo "opened annodiff (${args[*]}) in a tmux popup over this pane (a new window if a popup is already up there), in $root; notes will be sent to pane $TMUX_PANE"
  exit 0
fi
tmux new-window -n annodiff -c "$root" "$cmd"
echo "opened annodiff (${args[*]}) in a new tmux window, in $root; notes will be sent to pane $TMUX_PANE"
