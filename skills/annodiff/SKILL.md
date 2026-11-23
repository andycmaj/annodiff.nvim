---
name: annodiff
description: Review this branch's diff in Neovim (annodiff.nvim) beside this Claude session; annotations sent with \s (and unsent ones on close) arrive back here as a message. Also reads the latest annodiff annotations for this repo, and answers questions about annodiff's keys and config. Use when the user runs /annodiff, or says "annodiff", "review in annodiff", "review in nvim", "use my latest annodiff annotations", "what did I annotate in annodiff".
argument-hint: 'optional: what to review, e.g. HEAD, --base [branch], --pr [N|URL], main...HEAD, --staged, --inline, docs/plan.md (none: asks)'
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/open.sh:*), Bash(${CLAUDE_SKILL_DIR}/scripts/read-latest.sh:*)
---

# annodiff (Neovim review, notes back to Claude)

Arguments: `$ARGUMENTS`

## Pick the request

- **A question about annodiff** (keys, config, layouts, install): answer from `${CLAUDE_SKILL_DIR}/../../README.md`. Do not open a review.
- **"Use my latest annodiff annotations"**, "what did I annotate", or notes the user sent that never showed up here: run `${CLAUDE_SKILL_DIR}/scripts/read-latest.sh` and handle what it prints as under "When annotations arrive". It prints the newest of this repo's `.git/annodiff/annotations.md` (written on every send and on close) and its revdiff-format history entries. Empty output means nothing was saved.
- **A review** (the usual case, and any `/annodiff` with no arguments or with refs): launch below.

## Launch

With arguments, run them as given; nothing is asked:

```bash
${CLAUDE_SKILL_DIR}/scripts/open.sh <annodiff args>
```

Annodiff args: `HEAD` (uncommitted: staged + unstaged), `--base [branch]` (everything since the branch forked: merge base vs worktree; default branch when omitted; for a stacked branch, the branch below), `--pr [N|URL]` (a GitHub PR; none means this branch's PR), `<ref>` (ref vs worktree), `A..B`, `A...B`, `--staged [ref]`, plus `--inline` / `--split`. A lone PR number, `#N` or PR URL means `--pr` with it. A document instead of a diff (a plan, a spec, a README): `<file.md>` or `--doc <file> [ref]` (path relative to the repo root) opens doc mode, the file in one buffer with its headings as the tree; with a ref, changes since it are marked. Notes on it arrive in the same format, `( )` for its lines.

With no arguments, run `open.sh` with none. Nothing opens; it prints `needs_ask: true` and one `option: <label> | <args> | <description>` line per kind of diff that applies here, the recommended one first. Ask with AskUserQuestion, one question ("Which diff should annodiff review?"), the options in the order printed: label as label, description as description, `(Recommended)` after the first label. Then:

- An option whose args are complete (`HEAD`, `HEAD~1`, `--base main`, `--pr 12`): run `open.sh <args>`.
- "A pull request" (`--pr <number or URL>`) or "A ref or range" (`<ref>`): ask in chat which one, unless the user already typed it in "Other", then run `open.sh --pr <it>` or `open.sh <it>`.
- Free text in "Other": treat it as annodiff args.

After launching:

- Output starts with `error:`: report it and stop.
- Otherwise Neovim is open beside this session and does not block. Tell the user in one line what it shows and: annotate with `\a` (`\A` whole file), send notes here with `\s` (or `O` in the tree, or just close the review), `\c` asks an inline agent without sending anything here. Then end your turn; do not wait or poll. If the review hits an error (no changes, gh failing, unknown ref), Neovim shows it, not this session.

A PR is never checked out: when its head is not this worktree's clean HEAD, annodiff fetches `refs/pull/N/head` and its base into the object store and shows the PR head read-only, so line numbers match the PR but the right side is not the file on disk. Edit files only if the user asks; to work on the PR, `gh pr checkout <N>` first (ask if the tree is dirty), then review again with `--pr`, which then uses the worktree.

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
