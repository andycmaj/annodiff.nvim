#!/usr/bin/env bash
# Live: open.sh --doc on a scratch .md outside git (the "last turn" review), annotate, close 4 ways.
set -u
W="$1"; S="$2"
sock=adproof2
T() { tmux -L $sock "$@"; }
T kill-server 2>/dev/null
rm -rf "$S/xdg-state2" # a note restored from an earlier run would be typed over in normal mode
XDG_CONFIG_HOME="$S/xdg" XDG_STATE_HOME="$S/xdg-state2" XDG_DATA_HOME="$S/xdg-data" REVDIFF_HISTORY_DIR="$S/hist" \
  T -f /dev/null new-session -d -s p -x 160 -y 40 'stty -echo; cat'
pane="$(T display-message -p -t p:0 '#{pane_id}')"
sockpath="$(T display-message -p '#{socket_path}')"
open() { TMUX="$sockpath,0,0" TMUX_PANE="$pane" CLAUDE_PLUGIN_DATA="" "$W/skills/annodiff/scripts/open.sh" "$@" >/dev/null; }
claude() { echo "----- claude pane -----"; T capture-pane -p -t "$pane" | sed '/^$/d'; echo "-----------------------"; }
waitfor() { for _ in $(seq 50); do T capture-pane -p -t annodiff 2>/dev/null | grep -q "$1" && return 0; sleep 0.1; done; echo "(timeout waiting for $1)"; }
for how in draft-then-qa draft-then-backslash-q; do
  T respawn-pane -k -t "$pane" 'stty -echo; cat'; sleep 0.3
  d="$S/scratch-$how"; rm -rf "$d"; mkdir -p "$d"
  printf '# Last answer\n\nSome text.\n\n## Detail\n\nMore text.\n' > "$d/last-answer.md"
  echo; echo "## close via: $how"
  open --doc "$d/last-answer.md"
  waitfor "Detail"; sleep 0.4
  T send-keys -t annodiff ':3' Enter; sleep 0.2
  T send-keys -t annodiff '\a'; sleep 0.5
  T send-keys -t annodiff 'reply note'; sleep 0.3
  T send-keys -t annodiff Escape; sleep 0.2
  case $how in
    draft-then-qa) T send-keys -t annodiff ':qa' Enter; sleep 1.5; T capture-pane -p -t annodiff 2>/dev/null | sed '/^ *$/d' | tail -3 ;;
    draft-then-backslash-q) T send-keys -t annodiff '\\q'; sleep 1.5; T capture-pane -p -t annodiff 2>/dev/null | sed '/^ *$/d' | tail -3 ;;
    q-in-index) T send-keys -t annodiff C-w t; sleep 0.2; T send-keys -t annodiff q; sleep 1.5 ;;
    colon-q-in-doc) T send-keys -t annodiff ':q' Enter; sleep 1.5 ;;
    colon-qa) T send-keys -t annodiff ':qa' Enter; sleep 1.5 ;;
    backslash-q) T send-keys -t annodiff '\q'; sleep 1.5 ;;
  esac
  claude
  T kill-window -t annodiff 2>/dev/null
done
T kill-server
