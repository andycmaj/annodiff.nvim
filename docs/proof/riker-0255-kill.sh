#!/usr/bin/env bash
# Neovim SIGKILLed after a note is saved (no send, no close, no VimLeavePre): read-latest.sh still finds it.
set -u
W="$1"; S="$2"; sock=adkill; T() { tmux -L $sock "$@"; }; T kill-server 2>/dev/null
state="$S/kill-state"; rm -rf "$state"; d="$S/kill-scratch"; rm -rf "$d"; mkdir -p "$d"
printf '# Last answer\n\nSome text.\n' > "$d/turn.md"
XDG_CONFIG_HOME="$S/xdg" XDG_STATE_HOME="$state" T -f /dev/null new-session -d -s p -x 160 -y 40 'stty -echo; cat'
pane="$(T display-message -p -t p:0 '#{pane_id}')"; sockpath="$(T display-message -p '#{socket_path}')"
TMUX="$sockpath,0,0" TMUX_PANE="$pane" CLAUDE_PLUGIN_DATA="" "$W/skills/annodiff/scripts/open.sh" --doc "$d/turn.md" >/dev/null
for _ in $(seq 50); do T capture-pane -p -t annodiff | grep -q "Last answer" && break; sleep 0.1; done; sleep 0.4
T send-keys -t annodiff ':3' Enter; sleep 0.2; T send-keys -t annodiff '\a'; sleep 0.5
T send-keys -t annodiff 'saved, never sent' C-s; sleep 0.6
pid="$(T display-message -p -t annodiff '#{pane_pid}')"; tui="$(pgrep -P "$pid" nvim)"; server="$(pgrep -P "$tui")"
case "${3:-all}" in
  tui) echo "kill -9 the nvim TUI only (pid $tui; its --embed server $server is left to exit)"; kill -9 $tui ;;
  all) echo "kill -9 the nvim TUI and its --embed server (pids $tui $server): no close can run"; kill -9 $server $tui ;;
esac
sleep 3
echo "claude pane got: [$(T capture-pane -p -t "$pane" | sed '/^$/d')]"
T kill-server 2>/dev/null
echo "read-latest.sh:"; (cd "$d" && XDG_STATE_HOME="$state" REVDIFF_HISTORY_DIR="$S/kill-hist" "$W/skills/annodiff/scripts/read-latest.sh")
