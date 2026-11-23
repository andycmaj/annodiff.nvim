#!/usr/bin/env bash
# Print the newest annodiff annotations for this checkout, for "use my latest annodiff
# annotations" and for notes that never arrived in the session.
# usage: read-latest.sh [--doc <file>]
#   --doc <file>  annotations on that document (doc mode) instead of this checkout. A file
#                 outside any git repo keeps its review under Neovim's state dir, not a
#                 .git dir: $XDG_STATE_HOME/${NVIM_APPNAME:-nvim}/annodiff/docs/<hash>-<name>/
#                 (default XDG_STATE_HOME ~/.local/state), as annodiff's view.lua names it.
# Candidates, newest wins:
#   <git-dir>/annodiff/annotations.md   written on every send and on close (annotations only)
#   revdiff-format history entries      written on close (annotations, agent Q&A, diff)
#     in $REVDIFF_HISTORY_DIR (default ~/.config/revdiff/history)/<repo basename>/,
#     matched on their path: header, as revdiff's read-latest-history.sh does.
#   <state dir>/annotations.md          --doc on a file outside a git repo (no history there)
# Prints "source: <path>" then the file. Prints nothing (exit 0) when there is none.
set -uo pipefail

canonical() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
# Neovim's vim.uv.fs_realpath: the file's real path, symlinks resolved
realfile() {
  realpath "$1" 2>/dev/null || printf '%s/%s\n' "$(canonical "$(dirname "$1")")" "$(basename "$1")"
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else openssl dgst -sha256 -r | cut -d' ' -f1
  fi
}

doc=""
if [ "${1:-}" = "--doc" ]; then
  [ -n "${2:-}" ] || { echo "usage: read-latest.sh [--doc <file>]" >&2; exit 2; }
  doc="$(realfile "$2")"
fi

latest=""
newer() { [ -z "$latest" ] || [ "$1" -nt "$latest" ]; }

if [ -n "$doc" ]; then
  root="$(git -C "$(dirname "$doc")" rev-parse --show-toplevel 2>/dev/null)"
else
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

if [ -n "$root" ]; then
  root_c="$(canonical "$root")"
  if gitdir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)"; then
    f="$gitdir/annodiff/annotations.md"
    [ -s "$f" ] && latest="$f"
  fi

  hist="${REVDIFF_HISTORY_DIR:-${HOME:-}/.config/revdiff/history}/$(basename "$root")"
  header_path() { awk 'NR > 1 && $0 == "" {exit} /^path: / {sub(/^path: /, ""); print; exit}' "$1" 2>/dev/null; }
  for f in "$hist"/*.md; do
    [ -e "$f" ] || continue
    p="$(header_path "$f")"
    case "$p" in /*) ;; *) continue ;; esac
    [ "$(canonical "$p")" = "$root_c" ] || continue
    newer "$f" && latest="$f"
  done
else
  # doc outside a git repo: view.lua's state_dir
  state="${XDG_STATE_HOME:-${HOME:-}/.local/state}/${NVIM_APPNAME:-nvim}"
  hash="$(printf '%s' "$doc" | sha256 | cut -c1-12)"
  f="$state/annodiff/docs/$hash-$(basename "$doc")/annotations.md"
  [ -s "$f" ] && latest="$f"
fi

if [ -n "$latest" ]; then
  echo "source: $latest"
  echo
  cat "$latest"
fi
