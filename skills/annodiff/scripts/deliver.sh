#!/usr/bin/env bash
# Pastes an annodiff message into the Claude pane and submits it.
# usage: deliver.sh <tmux-pane>
# Exits non-zero when the message could not be delivered, so annodiff says "send command
# failed" instead of "sent".
# stdin: the annotation snapshot (revdiff ## format), empty when there is nothing new.
# env (set by annodiff's send command and by open.sh):
#   ANNODIFF_SEND_REASON      send (\s, O), close (a review closed: annodiff runs this on
#                             every close, so the agent always hears the review ended) or
#                             exit (Neovim exited; open.sh runs this after nvim returns)
#   ANNODIFF_ANNOTATION_COUNT annotations in the review, sent or not
#   ANNODIFF_CLOSED_MARK      a file touched on close, so exit says nothing after a close
#   ANNODIFF_REVIEW_LABEL     which review this is (a document's name, or the diff args),
#                             named in every header so notes from two reviews never mix
# close and exit also free this pane's review lock (review-lock.sh), so the agent can
# open the next review once it hears this one ended.
set -uo pipefail
dir="$(cd "$(dirname "$0")" && pwd -P)"
pane="$1"
label="${ANNODIFF_REVIEW_LABEL:-}"
src="from /annodiff nvim${label:+, review: $label}"
reason="${ANNODIFF_SEND_REASON:-send}"
count="${ANNODIFF_ANNOTATION_COUNT:-0}"
mark="${ANNODIFF_CLOSED_MARK:-}"
# an explicit XXXXXX template: GNU mktemp rejects `mktemp -t prefix` (macOS accepts it)
tmp="$(mktemp "${TMPDIR:-/tmp}/annodiff-send.XXXXXX")" || { echo "deliver: mktemp failed" >&2; exit 1; }
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" || { echo "deliver: cannot write $tmp" >&2; exit 1; }

case "$reason" in close | exit) "$dir/review-lock.sh" release "$pane" ;; esac

case "$reason" in
  close)
    [ -n "$mark" ] && : > "$mark"
    if [ -s "$tmp" ]; then
      header="annodiff annotations ($src; the review is closed, this is the final set):"
    elif [ "$count" -gt 0 ] 2>/dev/null; then
      header="annodiff review closed ($src): nothing new since the last send; the $count annotation(s) already sent are the final set. The review is done."
    else
      header="annodiff review closed ($src): no annotations, so no edits or suggestions. The review is done; nothing to change."
    fi
    ;;
  exit)
    # a review already said it closed: nothing to add
    if [ -n "$mark" ] && [ -e "$mark" ]; then
      rm -f "$mark"
      rmdir "$(dirname "$mark")" 2>/dev/null
      exit 0
    fi
    [ -n "$mark" ] && rmdir "$(dirname "$mark")" 2>/dev/null
    header="annodiff exited ($src) without closing a review (it may have failed to open: no changes, a bad ref): no annotations, so no edits or suggestions. Nothing to change."
    ;;
  *)
    [ -s "$tmp" ] || exit 0
    header="annodiff annotations ($src):"
    ;;
esac

{
  printf '%s\n' "$header"
  if [ -s "$tmp" ]; then
    printf '\n'
    cat "$tmp"
  fi
} | tmux load-buffer -b annodiff - || exit 1
tmux paste-buffer -b annodiff -p -d -t "$pane" || exit 1 # -p: bracketed paste
sleep 0.3
tmux send-keys -t "$pane" Enter
