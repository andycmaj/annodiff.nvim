#!/usr/bin/env bash
# Repro: last-turn review (open.sh --doc <scratch .md> outside git) whose paste to Claude fails;
# then "use my latest annodiff annotations" (read-latest.sh) cannot find the notes.
# Real tmux (own server), real nvim (empty config, isolated state dir), real skill scripts.
set -u
W="$1"; S="$2"
sock=adrepro; T() { tmux -L $sock "$@"; }; T kill-server 2>/dev/null
state="$S/repro-state"; rm -rf "$state"
session_cwd="$S/repro-session-repo"; rm -rf "$session_cwd"; mkdir -p "$session_cwd"
( cd "$session_cwd" && GIT_CONFIG_GLOBAL=/dev/null git init -q -b main && echo x > a && git add a \
  && git -c user.name=t -c user.email=t@t commit -qm init )
scratch="$S/repro-scratch"; rm -rf "$scratch"; mkdir -p "$scratch"
printf '# Grill round\n\nQ1: Should X run automatically?\n\nRecommended: yes.\n' > "$scratch/grill-round.md"
XDG_CONFIG_HOME="$S/xdg" XDG_STATE_HOME="$state" REVDIFF_HISTORY_DIR="$S/repro-hist" \
  T -f /dev/null new-session -d -s p -x 160 -y 40 'stty -echo; cat'
pane="$(T display-message -p -t p:0 '#{pane_id}')"
sockpath="$(T display-message -p '#{socket_path}')"
echo "== 1. Claude (pane $pane, cwd = a git repo) opens its last turn in annodiff:"
echo "\$ open.sh --doc $scratch/grill-round.md"
( cd "$session_cwd" && TMUX="$sockpath,0,0" TMUX_PANE="$pane" CLAUDE_PLUGIN_DATA="" REVDIFF_HISTORY_DIR="$S/repro-hist" \
  "$W/skills/annodiff/scripts/open.sh" --doc "$scratch/grill-round.md" )
for _ in $(seq 50); do T capture-pane -p -t annodiff | grep -q "Grill" && break; sleep 0.1; done; sleep 0.4
echo; echo "== 2. the Claude pane goes away (session restarted / pane moved), then the owner annotates line 3 and closes the review"
T kill-pane -t "$pane"
T send-keys -t annodiff ':3' Enter; sleep 0.2
T send-keys -t annodiff '\a'; sleep 0.5
T send-keys -t annodiff 'no need. commands are fine here' C-s; sleep 0.5
T send-keys -t annodiff Escape C-w t; sleep 0.2
T send-keys -t annodiff q; sleep 1.5
echo "annodiff says:"; T capture-pane -p -t annodiff | sed '/^ *$/d' | grep -E "annodiff:|failed" | tail -3
T kill-server 2>/dev/null
echo; echo "== 3. the notes are on disk, in annodiff's state folder:"
find "$state/nvim/annodiff" -type f | sed "s#$S#\$SCRATCH#"
f="$(find "$state/nvim/annodiff" -name annotations.md | head -1)"; echo "--- $(basename "$f"):"; cat "$f"
echo; echo "== 4. owner: \"use my latest annodiff annotations\" -> skill runs read-latest.sh"
echo "-- from the Claude session's cwd (a git repo):"
out="$(cd "$session_cwd" && REVDIFF_HISTORY_DIR="$S/repro-hist" XDG_STATE_HOME="$state" "$W/skills/annodiff/scripts/read-latest.sh")"; echo "stdout: [${out}]"
echo "-- from the scratch dir itself:"
out="$(cd "$scratch" && REVDIFF_HISTORY_DIR="$S/repro-hist" XDG_STATE_HOME="$state" "$W/skills/annodiff/scripts/read-latest.sh")"; echo "stdout: [${out}]"
echo "-- revdiff history dir (no entry: history is off outside a repo):"; ls -A "$S/repro-hist" 2>/dev/null || echo "(does not exist)"
echo; echo "Result: notes saved under stdpath(\"state\")/annodiff/docs/, read-latest.sh prints nothing."
