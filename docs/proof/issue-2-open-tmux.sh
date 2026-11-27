#!/usr/bin/env bash
# Live proof for issue #2: `/annodiff src/app.ts` (a non-markdown file) opens doc mode
# with the review keys, and a name that resolves as a commit is still a diff. Real tmux,
# real nvim, real open.sh/deliver.sh. Pane %0 runs `cat` in place of Claude, so what
# annodiff pastes there shows up in it.
# usage: issue-2-open-tmux.sh <checkout> <scratch dir>
set -u
W="$1"; S="$2"
repo="$S/repo"; rm -rf "$repo"; mkdir -p "$repo/src"
git -C "$repo" init -q -b main
printf 'export const a = 1;\nexport const b = 2;\n' > "$repo/src/app.ts"
printf 'a file named like a branch\n' > "$repo/release"
git -C "$repo" add -A; git -C "$repo" -c user.name=p -c user.email=p@p commit -q -m init
git -C "$repo" branch release
printf 'export const a = 1;\nexport const b = 3;\n' > "$repo/src/app.ts"
sock=adproof-issue2
T() { tmux -L $sock "$@"; }
T kill-server 2>/dev/null
mkdir -p "$S/xdg"
XDG_CONFIG_HOME="$S/xdg" XDG_STATE_HOME="$S/xdg-state" XDG_DATA_HOME="$S/xdg-data" REVDIFF_HISTORY_DIR="$S/hist" \
  T -f /dev/null set -g remain-on-exit off \; new-session -d -s p -x 160 -y 40 -c "$repo" 'stty -echo; cat'
pane="$(T display-message -p -t p:0 '#{pane_id}')"
sockpath="$(T display-message -p '#{socket_path}')"
open() { (cd "$repo" && TMUX="$sockpath,0,0" TMUX_PANE="$pane" CLAUDE_PLUGIN_DATA="" "$W/skills/annodiff/scripts/open.sh" "$@"); echo "(exit $?)"; }
claude() { echo "----- claude pane ($pane) -----"; T capture-pane -p -t "$pane" | sed '/^$/d'; echo "-------------------------------"; }
review() { T list-windows -F '#{window_id} #W' | awk '$2=="annodiff"{print $1; exit}'; }
screen() { echo "----- annodiff window -----"; T capture-pane -p -t "$(review)" | sed '/^ *$/d' | head -12; echo "---------------------------"; }

echo "## 1. open.sh src/app.ts (no --doc)"
open src/app.ts
sleep 2; screen

echo; echo "## 2. annotate line 2 with \\a, then \\q (send and quit)"
w="$(review)"
T send-keys -t "$w" ':2' Enter; sleep 0.2
T send-keys -t "$w" '\a'; sleep 0.5
T send-keys -t "$w" 'why 3?' C-s; sleep 0.5
T send-keys -t "$w" Escape '\q'; sleep 2
claude

echo; echo "## 3. open.sh release (a branch and a file of that name: the ref wins, a diff)"
open release
sleep 2; screen
T send-keys -t "$(review)" ':qa!' Enter; sleep 1
T kill-server
