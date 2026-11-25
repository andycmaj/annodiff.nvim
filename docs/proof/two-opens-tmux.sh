#!/usr/bin/env bash
# Live proof for "a second open.sh from the same Claude pane opens over a review still in
# progress": real tmux, real nvim, real open.sh/deliver.sh. Pane %0 runs `cat` in place of
# Claude, so what annodiff pastes there shows up in it.
# usage: two-opens-tmux.sh <checkout> <scratch dir>
set -u
W="$1"; S="$2"
docs="$S/docs"; rm -rf "$docs"; mkdir -p "$docs"
printf '# Round 3\n\nQ: which way?\n' > "$docs/grill-round-3.md"
printf '# One-pager\n\nThe design.\n' > "$docs/one-pager.md"
sock=adproof2
T() { tmux -L $sock "$@"; }
T kill-server 2>/dev/null
mkdir -p "$S/xdg"
XDG_CONFIG_HOME="$S/xdg" XDG_STATE_HOME="$S/xdg-state" XDG_DATA_HOME="$S/xdg-data" REVDIFF_HISTORY_DIR="$S/hist" \
  T -f /dev/null set -g remain-on-exit off \; new-session -d -s p -x 160 -y 40 -c "$docs" 'stty -echo; cat'
pane="$(T display-message -p -t p:0 '#{pane_id}')"
sockpath="$(T display-message -p '#{socket_path}')"
open() { TMUX="$sockpath,0,0" TMUX_PANE="$pane" CLAUDE_PLUGIN_DATA="" "$W/skills/annodiff/scripts/open.sh" "$@"; echo "(exit $?)"; }
claude() { echo "----- claude pane ($pane) -----"; T capture-pane -p -t "$pane" | sed '/^$/d'; echo "-------------------------------"; }
reviews() { echo "annodiff windows: $(T list-windows -F '#W' | grep -c annodiff)"; }

echo "## 1. open grill round 3 (doc mode)"
open --doc "$docs/grill-round-3.md"
sleep 1.5; reviews

echo; echo "## 2. while it is still open, open the one-pager from the same pane"
open --doc "$docs/one-pager.md" 2>&1
sleep 1.5; reviews

echo; echo "## 3. annotate round 3 line 3 in the first review, \\q (send and quit)"
first="$(T list-windows -F '#{window_id} #W' | awk '$2=="annodiff"{print $1; exit}')"
T send-keys -t "$first" ':3' Enter; sleep 0.2
T send-keys -t "$first" '\a'; sleep 0.5
T send-keys -t "$first" 'the second way' C-s; sleep 0.5
T send-keys -t "$first" Escape '\q'; sleep 2
reviews
claude

echo; echo "## 4. now open the one-pager"
open --doc "$docs/one-pager.md" 2>&1
sleep 1.5; reviews
T kill-server
