#!/usr/bin/env bash
# stdin: annodiff annotation snapshot (revdiff ## format). Pastes it into the Claude pane and submits it.
# usage: deliver.sh <tmux-pane>
# Exits non-zero when the message could not be delivered, so annodiff says "send command
# failed" instead of "sent".
set -uo pipefail
pane="$1"
# an explicit XXXXXX template: GNU mktemp rejects `mktemp -t prefix` (macOS accepts it)
tmp="$(mktemp "${TMPDIR:-/tmp}/annodiff-send.XXXXXX")" || { echo "deliver: mktemp failed" >&2; exit 1; }
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" || { echo "deliver: cannot write $tmp" >&2; exit 1; }
[ -s "$tmp" ] || exit 0
{ printf 'annodiff annotations (from /annodiff nvim):\n\n'; cat "$tmp"; } | tmux load-buffer -b annodiff - || exit 1
tmux paste-buffer -b annodiff -p -d -t "$pane" || exit 1 # -p: bracketed paste
sleep 0.3
tmux send-keys -t "$pane" Enter
