#!/usr/bin/env bash
# Print the newest annodiff annotations for this checkout, for "use my latest annodiff
# annotations" and for notes that never arrived in the session.
# Candidates, newest wins:
#   <git-dir>/annodiff/annotations.md   written on every send and on close (annotations only)
#   revdiff-format history entries      written on close (annotations, agent Q&A, diff)
#     in $REVDIFF_HISTORY_DIR (default ~/.config/revdiff/history)/<repo basename>/,
#     matched on their path: header, as revdiff's read-latest-history.sh does.
# Prints "source: <path>" then the file. Prints nothing (exit 0) when there is none.
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
canonical() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
root_c="$(canonical "$root")"

latest=""
newer() { [ -z "$latest" ] || [ "$1" -nt "$latest" ]; }

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

if [ -n "$latest" ]; then
  echo "source: $latest"
  echo
  cat "$latest"
fi
