#!/usr/bin/env bash
# stdin: annodiff annotation snapshot (revdiff ## format). Pastes it into the Claude pane and submits it.
# usage: deliver.sh <tmux-pane>
set -uo pipefail
pane="$1"
tmp="$(mktemp -t annodiff-send)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
[ -s "$tmp" ] || exit 0
{ printf 'annodiff annotations (from /annodiff nvim):\n\n'; cat "$tmp"; } | tmux load-buffer -b annodiff -
tmux paste-buffer -b annodiff -p -d -t "$pane" # -p: bracketed paste
sleep 0.3
tmux send-keys -t "$pane" Enter
