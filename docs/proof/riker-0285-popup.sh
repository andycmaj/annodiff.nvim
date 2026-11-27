#!/usr/bin/env bash
# RIKER-0285: open.sh in plain tmux opens annodiff in a tmux popup over the Claude pane,
# and every way out of the popup still reaches the agent. Real tmux, real Neovim.
# Server A holds the "Claude" pane (cat into a file, so pastes can be read back); server B
# runs a client attached to A, so A has a client to draw the popup on and keys typed into
# B's pane reach the popup (send-keys cannot: a popup is no pane).
# usage: riker-0285-popup.sh <annodiff checkout> <scratch dir>
set -u
W="$1"; S="$2"; open="$W/skills/annodiff/scripts/open.sh"
A() { tmux -L ad285a "$@"; }; B() { tmux -L ad285b "$@"; }
A kill-server 2>/dev/null; B kill-server 2>/dev/null
d="$S/p285"; rm -rf "$d"; mkdir -p "$d/xdg" "$d/state"
for n in 1 3 4 5 6 7 8 9 10 11; do printf "# Plan $n\n\nStep one.\nStep two.\n" > "$d/step$n.md"; done
pasted="$d/claude.txt"; : > "$pasted"
XDG_CONFIG_HOME="$d/xdg" XDG_STATE_HOME="$d/state" A -f /dev/null new-session -d -s claude -x 200 -y 50 "stty -echo; exec cat > $pasted"
B -f /dev/null new-session -d -s view -x 200 -y 50 "env -u TMUX tmux -L ad285a attach -t claude"
sleep 0.5
pane="$(A display-message -p -t claude:0 '#{pane_id}')"; sock="$(A display-message -p '#{socket_path}')"
client="$(A list-clients -F '#{client_name}')"
run_open() { TMUX="$sock,0,0" TMUX_PANE="$pane" CLAUDE_PLUGIN_DATA="" "$open" "$@"; }
screen() { B capture-pane -p -t view; }
lock() { A show-options -pqv -t "$pane" "$1"; }
wait_for() { for _ in $(seq 60); do screen | grep -q "$1" && return 0; sleep 0.1; done; return 1; }
off=0
new_paste() { tail -c +$((off + 1)) "$pasted"; }
seen() { new_paste; off=$(wc -c < "$pasted"); }
wait_paste() { for _ in $(seq 60); do new_paste | grep -q "$1" && return 0; sleep 0.1; done; return 1; }
keys() { B send-keys -t view "$@"; sleep 0.3; }
note() { keys ":$2" Enter; keys '\a'; sleep 0.3; keys "$1" C-s; sleep 0.3; }
step() { echo; echo "=== $*"; }

step "1. open: a popup over the Claude pane"
run_open --doc "$d/step1.md"
wait_for "Step one" || echo "!! popup never showed the doc"
echo "windows in the claude session: $(A list-windows -t claude | wc -l | tr -d ' ') (1 = no new window)"
echo "lock: review=[$(lock @annodiff_review)] holder=[$(lock @annodiff_review_pane | sed 's/[0-9]*$/N/')]"
echo "client screen (top 6 lines):"; screen | head -6

step "2. a second open while the popup is up is refused"
run_open --doc "$d/step1.md"; echo "exit $?"

step "3. a note, then \\q (send and quit): notes reach the agent, lock freed"
note "first note" 3; keys '\q'
wait_paste "final set" || echo "!! nothing pasted"
sleep 0.5; seen
echo "lock after: [$(lock @annodiff_review)]; popup gone: $(screen | grep -q 'Step one' && echo no || echo yes)"

step "4. a note, then :qa"
run_open --doc "$d/step4.md" >/dev/null; wait_for "Step one"
note "second note" 3; keys ':qa' Enter
wait_paste "final set" || echo "!! nothing pasted"
sleep 0.5; seen; echo "lock after: [$(lock @annodiff_review)]"

step "5. a note, then the popup killed (display-popup -C)"
run_open --doc "$d/step5.md" >/dev/null; wait_for "Step one"
note "third note" 3; A display-popup -C -c "$client"
wait_paste "annodiff" || echo "!! nothing pasted"
sleep 2.5; seen; echo "lock after: [$(lock @annodiff_review)]"

step "5b. a note saved, then Neovim SIGKILLed (TUI and server): no close can run; the popup job reports the exit"
run_open --doc "$d/step9.md" >/dev/null; wait_for "Step one"
note "fifth note" 3
tui="$(pgrep -f 'Annodiff --doc .*step9.md' | head -1)"; kill -9 $(pgrep -P "$tui") "$tui"
wait_paste "annodiff" || echo "!! nothing pasted"
sleep 2.5; seen; echo "lock after: [$(lock @annodiff_review)]"

step "5c. review closed with :AnnodiffClose but Neovim left up in its popup: the next review opens in a window (a client shows one popup)"
run_open --doc "$d/step11.md" >/dev/null; wait_for "Step one"
keys ':AnnodiffClose' Enter; wait_paste "review closed" || echo "!! no close message"; sleep 0.5; seen
echo "lock after the close: [$(lock @annodiff_review)]; first popup still up: $(screen | grep -q 'annodiff: step11.md' && echo yes || echo no)"
run_open --doc "$d/step10.md"; sleep 1.5
echo "windows: $(A list-windows -t claude -F '#{window_name}' | tr '\n' ' ')"
echo "lock: review=[$(lock @annodiff_review)] holder=[$(lock @annodiff_review_pane | sed 's/[0-9]*$/N/')]"
A kill-window -t claude:annodiff; wait_paste "step10" || echo "!! no exit message for step10"; sleep 0.5; seen
keys ':qa' Enter; sleep 2.5; echo "after quitting the first popup's Neovim, pasted: [$(new_paste)]"; seen >/dev/null

step "6. ANNODIFF_POPUP=0: a new window, as before"
ANNODIFF_POPUP=0 run_open --doc "$d/step6.md"
sleep 1; echo "windows: $(A list-windows -t claude -F '#{window_name}' | tr '\n' ' ')"
A kill-window -t claude:annodiff; sleep 2.5; seen >/dev/null

step "7. a note, then the client detaches (the popup goes with it)"
run_open --doc "$d/step7.md" >/dev/null; wait_for "Step one"
note "fourth note" 3; A detach-client -t "$client"
wait_paste "annodiff" || echo "!! nothing pasted"
sleep 2.5; seen; echo "lock after: [$(lock @annodiff_review)]"

step "8. no client looking at the Claude pane's window: a new window"
B kill-server 2>/dev/null; B -f /dev/null new-session -d -s view -x 200 -y 50 "env -u TMUX tmux -L ad285a attach -t claude"
A new-window -d -t claude: -n other 'sleep 600'; A select-window -t claude:other; sleep 0.5
echo "clients: $(A list-clients -F '#{window_name}') (looking at 'other', not the Claude pane's window)"
run_open --doc "$d/step8.md"
sleep 1; echo "windows: $(A list-windows -t claude -F '#{window_name}' | tr '\n' ' ')"

A kill-server 2>/dev/null; B kill-server 2>/dev/null; true
