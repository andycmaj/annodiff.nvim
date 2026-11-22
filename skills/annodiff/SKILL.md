---
name: annodiff
description: Review this branch's diff in Neovim (annodiff.nvim) beside this Claude session; annotations sent with \s (and unsent ones on close) arrive back here as a message. Also reads the latest annodiff annotations for this repo, and answers questions about annodiff's keys and config. Use when the user runs /annodiff, or says "annodiff", "review in annodiff", "review in nvim", "use my latest annodiff annotations", "what did I annotate in annodiff".
argument-hint: 'optional: annodiff args, e.g. main, HEAD~3, --staged, --inline, main...HEAD (default: picked like revdiff)'
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/open.sh:*), Bash(${CLAUDE_SKILL_DIR}/scripts/read-latest.sh:*)
---

# annodiff (Neovim review, notes back to Claude)

Arguments: `$ARGUMENTS`

## Pick the request

- **A question about annodiff** (keys, config, layouts, install): answer from `${CLAUDE_SKILL_DIR}/../../README.md`. Do not open a review.
- **"Use my latest annodiff annotations"**, "what did I annotate", or notes the user sent that never showed up here: run `${CLAUDE_SKILL_DIR}/scripts/read-latest.sh` and handle what it prints as under "When annotations arrive". It prints the newest of this repo's `.git/annodiff/annotations.md` (written on every send and on close) and its revdiff-format history entries. Empty output means nothing was saved.
- **A review** (the usual case, and any `/annodiff` with no arguments or with refs): launch below.

## Launch

Run, with the arguments as given (none is fine):

```bash
${CLAUDE_SKILL_DIR}/scripts/open.sh [annodiff args]
```

Annodiff args: `<ref>` (ref vs worktree), `--staged [ref]`, `A..B`, `A...B`, `--inline` / `--split`. With none, `open.sh` picks like revdiff: on the main branch, uncommitted changes (`HEAD`) or else the last commit (`HEAD~1`); on a clean feature branch, the branch against main (merge base vs worktree).

- Output starts with `error:`: report it and stop.
- Output contains `needs_ask: true` (feature branch with uncommitted changes): nothing opened yet. Ask with AskUserQuestion: "Uncommitted only" or "Branch vs <main_branch>". Then run `open.sh HEAD` for uncommitted, or `open.sh <branch_args>` for the branch.
- Otherwise Neovim is open beside this session and does not block. Tell the user in one line: annotate with `\a` (`\A` whole file), send notes here with `\s` (or `O` in the tree, or just close the review), `\c` asks an inline agent without sending anything here. Then end your turn; do not wait or poll.

To review a GitHub PR that is not this branch: `gh pr checkout <N>`, then `open.sh <base>...HEAD`. annodiff reads local git only; it has no patch or `--stdin` mode.

## When annotations arrive

They arrive as a user message starting with `annodiff annotations (from /annodiff nvim):`, in revdiff's format:

```
## file.go:43 (+)
comment text
```

`(+)` added line, `(-)` removed line (old-side number), `( )` unchanged context line, `:N-M` a range, `(file-level)` whole-file note. Each send is the full current set, so skip notes you already handled from an earlier send.

- Notes containing `??` or starting with explain/what/how/why/clarify/describe/remind: answer in chat, no code change.
- Everything else: a change directive. Make the change.

The right-hand side of the review is the real file, so the user sees your edits live. Tell them to press `R` in the tree if files were added or removed. Do not relaunch. When they close the review without sending anything new, the review is done.
