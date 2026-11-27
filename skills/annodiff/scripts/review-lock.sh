#!/usr/bin/env bash
# One review at a time per Claude pane. open.sh does not block, so without this an agent
# can launch a second review over one the user is still in: two stacked splits, notes
# from both pasted into the same pane. The lock lives in tmux pane options on the Claude
# pane, so it goes away with that pane and needs no files:
#   @annodiff_review        what is open (the label notes carry), set by `take`
#   @annodiff_review_since  epoch seconds of `take`
#   @annodiff_review_pane   who holds it, set by `attach` once the review starts: the
#                           review's own pane, or pid:<n> for a review in a tmux popup
#                           (a popup is no pane: its launcher shell, alive until the
#                           popup closes and the exit is reported, stands for it)
# The holder is $ANNODIFF_REVIEW_OWNER when set (open.sh sets it for a popup), else $TMUX_PANE.
# A lock is stale (ignored) when its holder is gone, or when it never attached
# within $ANNODIFF_LOCK_GRACE seconds (default 15: the launch failed).
#
# usage: review-lock.sh check   <claude-pane>          exit 1 and print the label if busy
#        review-lock.sh take    <claude-pane> <label>
#        review-lock.sh attach  <claude-pane>          in the review (its holder, as above)
#        review-lock.sh release <claude-pane>          only the review that holds it
set -uo pipefail
cmd="${1:-}" pane="${2:-}"
[ -n "$cmd" ] && [ -n "$pane" ] || { echo "usage: review-lock.sh check|take|attach|release <pane> [label]" >&2; exit 2; }

get() { tmux show-options -pqv -t "$pane" "$1" 2>/dev/null; }
set_opt() { tmux set-option -pq -t "$pane" "$1" "$2" 2>/dev/null; }
unset_all() {
  local o
  for o in @annodiff_review @annodiff_review_since @annodiff_review_pane; do
    tmux set-option -pqu -t "$pane" "$o" 2>/dev/null
  done
}
holder="${ANNODIFF_REVIEW_OWNER:-${TMUX_PANE:-}}"
alive() {
  case "$1" in
    pid:*) kill -0 "${1#pid:}" 2>/dev/null ;;
    *) [ "$(tmux display-message -p -t "$1" '#{pane_dead}' 2>/dev/null)" = 0 ] ;;
  esac
}

case "$cmd" in
  check)
    label="$(get @annodiff_review)"
    [ -n "$label" ] || exit 0
    owner="$(get @annodiff_review_pane)"
    if [ -n "$owner" ]; then
      alive "$owner" && { printf '%s\t%s\n' "$label" "$owner"; exit 1; }
    else
      since="$(get @annodiff_review_since)"
      now="$(date +%s)"
      if [ -n "$since" ] && [ $((now - since)) -lt "${ANNODIFF_LOCK_GRACE:-15}" ] 2>/dev/null; then
        printf '%s\t%s\n' "$label" "starting"
        exit 1
      fi
    fi
    unset_all # stale: its review is gone
    exit 0
    ;;
  take)
    unset_all
    set_opt @annodiff_review_since "$(date +%s)"
    set_opt @annodiff_review "${3:-a review}"
    ;;
  attach)
    [ -n "$holder" ] && set_opt @annodiff_review_pane "$holder"
    ;;
  release)
    # Only the review holding the lock frees it: a late exit of an older review must not
    # free a newer one (whose holder differs, or is not attached yet).
    [ -n "$holder" ] && [ "$(get @annodiff_review_pane)" = "$holder" ] && unset_all
    ;;
  *)
    echo "review-lock.sh: unknown command: $cmd" >&2
    exit 2
    ;;
esac
exit 0
