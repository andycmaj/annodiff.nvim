#!/usr/bin/env bash
# Live proof: real tmux, real nvim, real open.sh/deliver.sh. Pane %0 runs `cat` in place of Claude.
set -u
W="$1"; S="$2"
repo="$S/proofrepo"; rm -rf "$repo"; mkdir -p "$repo"; cd "$repo"
export GIT_CONFIG_GLOBAL=/dev/null
git init -q -b main; printf 'a\nb\n' > f.txt; git add -A; git -c user.name=t -c user.email=t@t commit -qm init; printf 'a\nB\n' > f.txt
sock=adproof
T() { tmux -L $sock "$@"; }
T kill-server 2>/dev/null
mkdir -p "$S/xdg"
XDG_CONFIG_HOME="$S/xdg" XDG_STATE_HOME="$S/xdg-state" XDG_DATA_HOME="$S/xdg-data" REVDIFF_HISTORY_DIR="$S/hist" \
  T -f /dev/null set -g remain-on-exit off \; new-session -d -s p -x 160 -y 40 -c "$repo" 'stty -echo; cat'
pane="$(T display-message -p -t p:0 '#{pane_id}')"
sockpath="$(T display-message -p '#{socket_path}')"
open() { TMUX="$sockpath,0,0" TMUX_PANE="$pane" CLAUDE_PLUGIN_DATA="" "$W/skills/annodiff/scripts/open.sh" "$@"; }
claude() { echo "----- claude pane ($pane) -----"; T capture-pane -p -t "$pane" | sed '/^$/d'; echo "-------------------------------"; }
nv() { T capture-pane -p -t annodiff | sed '/^ *$/d' | tail -n "${1:-8}"; }
waitfor() { for _ in $(seq 50); do T capture-pane -p -t annodiff 2>/dev/null | grep -q "$1" && return 0; sleep 0.1; done; echo "(timeout waiting for $1)"; }

echo "## 1. open a review, close it with q, no annotations"
open HEAD
waitfor "f.txt"; sleep 0.5
nv 6
T send-keys -t annodiff C-w t; sleep 0.2; T send-keys -t annodiff q; sleep 1.5
nv 3
claude
echo "## 1b. then :q Neovim: no second message (the close already reported)"
T send-keys -t annodiff ':q' Enter; sleep 1.5
claude
T respawn-pane -k -t "$pane" 'stty -echo; cat'; sleep 0.3

echo; echo "## 2. a review that fails to open (bad ref), then :q"
open no-such-ref
sleep 1.5; nv 4
T send-keys -t annodiff ':q' Enter; sleep 1.5
claude
T respawn-pane -k -t "$pane" 'stty -echo; cat'; sleep 0.3

echo; echo "## 3. annotate line 2, then \\q (flush and quit Neovim)"
open HEAD
waitfor "f.txt"; sleep 0.5
T send-keys -t annodiff ':2' Enter; sleep 0.2
T send-keys -t annodiff '\a'; sleep 0.5
T send-keys -t annodiff 'make it lowercase' C-s; sleep 0.5
nv 6
T send-keys -t annodiff Escape '\q'; sleep 2
echo "annodiff window still there? $(T list-windows -F '#W' | grep -c annodiff)"
claude
T kill-server
