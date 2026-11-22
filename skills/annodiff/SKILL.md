---
name: annodiff
description: Open this branch's diff in Neovim (annodiff.nvim) beside this Claude session; annotations sent with \s (and unsent ones on close) arrive back here as a message. Use when the user runs /annodiff.
argument-hint: 'optional: annodiff args, e.g. main, HEAD~3, --staged, main...HEAD (default: HEAD, or HEAD~1 if clean)'
allowed-tools: Bash(~/.claude/skills/annodiff/scripts/open.sh:*)
---

# annodiff (Neovim review, notes back to Claude)

## Launch

!`~/.claude/skills/annodiff/scripts/open.sh $ARGUMENTS 2>&1`

## Your task

If the launch output above starts with `error:`, report it and stop.

Otherwise Neovim is open with the review and does not block. Tell the user in one line: annotate with `\a` (`\A` whole file), send notes here with `\s` (or `O` in the tree, or just close the review), `\c` asks an inline agent without sending anything here. Then end your turn; do not wait or poll.

## When annotations arrive

They arrive as a user message starting with `annodiff annotations (from /annodiff nvim):`, in revdiff's format:

```
## file.go:43 (+)
comment text
```

`(+)` added line, `(-)` removed line (old-side number), `( )` unchanged context line, `:N-M` a range, `(file-level)` whole-file note. Each send is the full current set, so skip notes you already handled from an earlier send.

- Notes containing `??` or starting with explain/what/how/why/clarify: answer in chat, no code change.
- Everything else: a change directive. Make the change.

The right-hand side of the review is the real file, so the user sees your edits live. Tell them to press `R` in the tree if files were added or removed. Do not relaunch.
