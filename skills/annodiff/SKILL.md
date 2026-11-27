---
name: annodiff
description: Review this branch's diff in Neovim (annodiff.nvim) beside this Claude session; annotations sent with \s (and unsent ones on close) arrive back here as a message. Also opens a document or one of your own messages (the last answer, a grill question) in annodiff's doc mode to annotate, reads the latest annodiff annotations for this repo, and answers questions about annodiff's keys and config. Use when the user runs /annodiff, or says "annodiff", "review in annodiff", "review in nvim", "annotate that in annodiff", "annodiff the last turn", "use my latest annodiff annotations", "what did I annotate in annodiff".
argument-hint: 'optional: what to review, e.g. HEAD, --base [branch], --pr [N|URL], main...HEAD, --staged, --inline, docs/plan.md, src/app.ts (none: asks)'
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/open.sh:*), Bash(${CLAUDE_SKILL_DIR}/scripts/read-latest.sh:*)
---

# annodiff (Neovim review, notes back to Claude)

Arguments: `$ARGUMENTS`

## Pick the request

- **A question about annodiff** (keys, config, layouts, install): answer from `${CLAUDE_SKILL_DIR}/../../README.md`. Do not open a review.
- **"Use my latest annodiff annotations"**, "what did I annotate", or notes the user sent that never showed up here: run `${CLAUDE_SKILL_DIR}/scripts/read-latest.sh` and handle what it prints as under "When annotations arrive". It prints the newest of this repo's `.git/annodiff/annotations.md` (written on every send and on close), its revdiff-format history entries, and the notes on any document reviewed outside a repo (kept under Neovim's state dir; the `source:` path names it). For a document you opened in doc mode (one of your own messages, a file outside this repo), run `read-latest.sh --doc <absolute path>` instead: a file outside any git repo keeps its notes under Neovim's state dir, the plain form returns them only when they are the newest of all. Empty output means nothing was saved.
- **One of your own messages** ("the last turn", "your last answer", "the grilling question", "this plan"): write that message's text verbatim, as markdown with its headings, to a new `.md` file named for its subject (your scratchpad directory if you have one, else `$TMPDIR`; no git repo needed), then run `open.sh --doc <absolute path>`. Its notes arrive as `## <name>.md:N ( )`, line N of that file: replies to your message (an answer to a question you asked, a correction, a question back). Answer them in chat; change code only if a note asks for it.
- **A document or any one file** (a plan, spec or README, a source file to annotate): `open.sh <file>` or `open.sh --doc <file> [ref]`, see below.
- **A review** (the usual case, and any `/annodiff` with no arguments or with refs): launch below.

## Launch

With arguments, run them as given; nothing is asked:

```bash
${CLAUDE_SKILL_DIR}/scripts/open.sh <annodiff args>
```

Annodiff args: `HEAD` (uncommitted: staged + unstaged), `--base [branch]` (everything since the branch forked: merge base vs worktree; default branch when omitted; for a stacked branch, the branch below), `--pr [N|URL]` (a GitHub PR; none means this branch's PR), `<ref>` (ref vs worktree), `A..B`, `A...B`, `--staged [ref]`, plus `--inline` / `--split`. A lone PR number, `#N` or PR URL means `--pr` with it. A document instead of a diff (a plan, a spec, a README, a source file, a message you wrote to a file): `<file> [ref]` or `--doc <file> [ref]` opens doc mode (an existing file path opens it whatever its extension, unless the name also resolves as a commit; `--doc` forces it), the file in one buffer with its headings as the tree; with a ref (only in a git repo), changes since it are marked. The file may be anywhere, in a repo or not. Notes on it arrive in the same format, `( )` for its lines.

With no arguments, run `open.sh` with none. Nothing opens; it prints `needs_ask: true` and one `option: <label> | <args> | <description>` line per kind of diff that applies here, the recommended one first. Ask with AskUserQuestion, one question ("Which diff should annodiff review?"), the options in the order printed: label as label, description as description, `(Recommended)` after the first label. Then:

- An option whose args are complete (`HEAD`, `HEAD~1`, `--base main`, `--pr 12`): run `open.sh <args>`.
- "A pull request" (`--pr <number or URL>`) or "A ref or range" (`<ref>`): ask in chat which one, unless the user already typed it in "Other", then run `open.sh --pr <it>` or `open.sh <it>`.
- Free text in "Other": treat it as annodiff args.

After launching:

- Output starts with `error: a review opened from this pane is still open (<review>, ...)`: one review at a time per session. Do not retry or work around it. Tell the user in one line that `<review>` is still open and you will open the new one once it closes (they send their notes and close it, or `\q`), then end your turn. Open it after that review's close message arrives (see "When the review closes").
- Any other `error:`: report it and stop.
- Otherwise Neovim is open beside this session and does not block. Tell the user in one line what it shows and: annotate with `\a` (`\A` whole file), send notes here with `\s` (or `O` in the tree), `\q` sends what is unsent and quits Neovim, `\c` asks an inline agent without sending anything here. Then end your turn; do not wait or poll. Closing the review always sends a message here (see below), so you hear when it ends. Open one review at a time: when you have several to show (grill rounds, then a write-up), launch the next only after the last one's close message arrives, never while it is open; `open.sh` refuses a second review from this session until then. Notes mid-review (`\s`) do not end it. If the review hits an error (no changes, gh failing, unknown ref), Neovim shows it, not this session; quitting Neovim then sends an "annodiff exited" message.

A PR is never checked out: when its head is not this worktree's clean HEAD, annodiff fetches `refs/pull/N/head` and its base into the object store and shows the PR head read-only, so line numbers match the PR but the right side is not the file on disk. Edit files only if the user asks; to work on the PR, `gh pr checkout <N>` first (ask if the tree is dirty), then review again with `--pr`, which then uses the worktree.

## When annotations arrive

They arrive as a user message starting with `annodiff annotations (from /annodiff nvim, review: <review>` (`):` while the review is open, `; the review is closed, ...):` for the final set), in revdiff's format. `<review>` names which review they came from: the document's file name (and ref) in doc mode, the diff args (`HEAD`, `--base main`, `--pr 12`) otherwise. Every close and exit message below names it the same way.

```
## file.go:43 (+)
comment text
```

`(+)` added line, `(-)` removed line (old-side number), `( )` unchanged context line, `:N-M` a range, `(file-level)` whole-file note. Each send is the full current set, so skip notes you already handled from an earlier send.

- Notes containing `??` or starting with explain/what/how/why/clarify/describe/remind: answer in chat, no code change.
- Everything else: a change directive. Make the change.

The right-hand side of the review is the real file, so the user sees your edits live. Tell them to press `R` in the tree if files were added or removed. Do not relaunch.

## When the review closes

Every close sends one message here, notes or not, and frees this session to open the next review (one you held back, see "After launching"):

- `annodiff annotations (from /annodiff nvim, review: <review>; the review is closed, this is the final set):` then notes: unsent notes at close. Handle them as above; the review is over, so do not wait for more.
- `annodiff review closed (from /annodiff nvim, review: <review>): no annotations, so no edits or suggestions. ...`: the user looked and had nothing to say. Make no changes. Say in one line that the review came back clean, then carry on with whatever you were doing before the review (or end your turn if that was the last step).
- `annodiff review closed (from /annodiff nvim, review: <review>): nothing new since the last send; ...`: everything was already sent and handled. Nothing more to do; carry on.
- `annodiff exited (from /annodiff nvim, review: <review>) without closing a review ...`: Neovim quit before a review closed (usually it failed to open). No notes; say so in one line and carry on.
- `annodiff exited (from /annodiff nvim, review: <review>) before the review closed ...; these notes were saved during it but never sent:` then `source:` and notes: Neovim was killed mid-review. Handle the notes as above.
