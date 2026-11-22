# annodiff.nvim plan (final, v2)

Neovim port of the revdiff fork (andycmaj/revdiff). Draft v1 lives in the aug
task AUG-0191 (`revdiff-nvim-plan.md`); this version folds in the owner
interview from AUG-0196 (2026-11-21).

## Decisions from the interview

| Question | Answer | Consequence |
|---|---|---|
| Why nvim over the TUI? | Real LSP / treesitter / editing while reviewing | **Native diff mode (`:diffthis`, approach B)**, not a custom-rendered unified buffer. The new side is the real file buffer whenever it is the worktree, so LSP, treesitter, gitsigns, and edits all work and the diff updates live |
| Edit from the review view? | Yes (follows from above) | Worktree side is editable. Read-only scratch buffers only for git revisions and the index |
| Agent ask | Both, handoff first | Slice 4a: `:AnnodiffSend` pipes the export to a configured command (like revdiff `O` post-flush). Slice 4b: ask on a line/range, answer shown inline as `virt_lines` |
| Storage / format | Per-clone under `.git/`, `##` compatible | Annotations in `.git/annodiff/<ref-key>.json`; export byte-compatible with revdiff `FormatOutput()` so existing skills keep working |
| Repo | New repo `andycmaj/annodiff.nvim` (private) | Plugin name annodiff, command `:Annodiff`, module `require("annodiff")` |
| VCS | Git only to start (default) | `git.lua` keeps sides abstract (`rev` / `index` / `worktree`) so jj can follow |
| Neovim | 0.10+ (owner runs 0.12) | `vim.system`, `vim.fs`, extmarks; no required dependencies |

## Diff model

A review is a pair of **sides** plus the `git diff` arguments that list the
changed files:

| Invocation | Left side | Right side | `git diff` args |
|---|---|---|---|
| `:Annodiff` | index | worktree | (none), same as revdiff with no ref |
| `:Annodiff <ref>` | `<ref>` | worktree | `<ref>` |
| `:Annodiff --staged [ref]` | `<ref>` or `HEAD` | index | `--cached [ref]` |
| `:Annodiff A..B` | `A` | `B` | `A..B` |
| `:Annodiff A...B` | `merge-base(A, B)` | `B` | `A...B` |

File list: `git diff --name-status -M -z <args>` (port of revdiff
`ChangedFiles` / `parseNameStatusEntries`; renames keep their old path so the
left side reads `rev:old_path`).

Contents: `git show <rev>:<path>` (`:0:<path>` for the index) into a scratch
buffer (`buftype=nofile`, `nomodifiable`, filetype from the real path). The
worktree side is `:edit <file>` on the real file. Missing side (added/deleted)
is an empty scratch buffer. Binary on either side shows a placeholder, no diff.

## Layout

One tab page per review:

```
| tree (35 cols, winfixwidth) | old (scratch) | new (real file or scratch) |
```

Closing the tab, `q` in the tree or a scratch buffer, `:AnnodiffClose`, or
closing any of the three windows ends the review.

## Slices

1. **Slice 1 (this task): `:Annodiff [ref]`.** git source, tree split, native
   diff windows, file and hunk navigation, refresh. Read-only for revisions,
   editable worktree.
   - Tree: directories (single-child chains compressed, collapsible), status
     letter, rename origin, current file highlighted.
   - Keys (configurable, `false` disables):
     - `<Tab>` / `<S-Tab>` next / previous file (tree and diff windows)
     - `]c` / `[c` next / previous hunk; at the last / first hunk it moves to
       the next / previous file (revdiff cross-file motion). Native `]c`
       inside a file
     - tree: `<CR>` / `o` open file or toggle directory, `R` refresh, `q` close
     - `q` also closes from read-only scratch buffers (never mapped on real
       file buffers so macros still work)
   - Not using `]f` / `]h`: LazyVim maps those (treesitter functions,
     gitsigns hunks).
2. **Slice 2: annotations (done).** Keys under `<localleader>` (owner's call,
   2026-11-21: plain `a` / `A` / `d` are editing keys on the real buffer):
   `a` line / visual range / edit, `A` file-level, `d` delete, `l` picker
   (`vim.ui.select`, not quickfix: quickfix jumps would break the review
   layout), `n` / `N` next / previous across files. Records use revdiff's
   model (`+` new-side number, `-` old-side number, ` ` context with the
   new-side number from either window, file-level, ranges, the "hunk" keyword
   widening). Classification comes from `vim.diff` with options mirrored from
   `'diffopt'`. Extmarks track edits in the real buffer; diff mode ignores
   virtual lines, so each annotation gets blank padding at the counterpart
   line in the other window. `:AnnodiffExport [path]` (default
   `.git/annodiff/annotations.md`, also written on close), checked
   byte-identical against revdiff's Go `Parse` + `FormatOutput`. Store is
   in memory per review; loading it back is slice 3.
3. **Slice 3: persistence + re-anchoring (done).** JSON per review at
   `.git/annodiff/reviews/<label>.json` (records + anchor text + reviewed
   paths), written on every change, restored on open. Re-anchoring on first
   draw of each file: same line, else nearest line with the anchor text; new
   side records are reclassified (`+` may now be context); not found =
   orphan, kept and flagged, never moved by later syncs. Reviewed marks
   (`<Space>` in the tree as in revdiff, `\r` in diff windows), tree filters
   `f` (annotated) / `F` (unreviewed) as in revdiff, `<Tab>` skips hidden
   files. History in revdiff's exact layout and directory
   (`$REVDIFF_HISTORY_DIR` or `~/.config/revdiff/history/<repo>/`) so the
   revdiff skill's `read-latest-history.sh` returns annodiff reviews;
   checked live. `:AnnodiffClear[!]`. Later: reset a reviewed mark when the
   file's diff changes after it was marked.
4. **Slice 4: agent (done).**
   - 4a `:AnnodiffSend` (`\s`, `O` in the tree): revdiff's `O` flush +
     post-flush command (`send_command`, `$ANNODIFF_SEND_COMMAND`,
     `$REVDIFF_POST_FLUSH_COMMAND`), snapshot on stdin and to the export file;
     `send_on_close`. `skills/annodiff` mirrors the owner's `/revdiff` skill
     (open beside the Claude pane, paste sends back). VimLeavePre now
     finishes open reviews.
   - 4b ask-agent, ported from the revdiff fork's `feat/ask-agent` rather
     than redesigned: same hermetic read-only `claude -p` args, prompt on
     stdin, stream-json parser (checked against revdiff's recorded fixtures),
     fork from a tagged parent session, resume for follow-ups, stall / idle
     handling, process-group cancel. Threads are separate from annotations
     (not exported or sent; `## Agent Q&A` in history). Inline preview = last
     4 answer rows + `+N more`; thread window with follow-up / retry /
     promote / cancel / delete. Keys `\c` / `\C` (revdiff `c`, under
     `<localleader>` like the other keys). Change from the draft: answers
     are threads, not an `answer` annotation kind, because the fork already
     settled that.
5. **Slice 5: inline layout (done, owner ask 2026-11-21).** One window over
   the new side (real file when worktree), added lines highlighted, removed
   lines as ghost virtual rows; deleted files show old content all removed.
   `--inline` / `layout` / `\i` / `:AnnodiffLayout`. Hunk navigation computed
   from `vim.diff` (no diff mode); a picker reaches removed lines for
   `\a` / `\c` / `\d`; their notes and threads render under their ghost row.
   Sides are now buffers (`buf_old`, `buf_new`) rather than windows, so the
   old side can exist without being shown.
6. **Slice 6:** blame, untracked files toggle, intra-line highlights in the
   inline layout, async file loading with stale-load drop.
7. Later: jj / hg sources, compare mode, markdown TOC.

**Backlog (owner: keep on the back burner):** a custom-rendered unified view,
revdiff-style: one read-only buffer with `-` and `+` lines interleaved. Closest
to revdiff, but no LSP / editing in that view and a bigger build than the
inline overlay.

## Code layout

```
plugin/annodiff.lua      commands (:Annodiff, :AnnodiffClose, :AnnodiffRefresh)
lua/annodiff/init.lua    setup(opts), open/close/refresh API
lua/annodiff/config.lua  defaults
lua/annodiff/git.lua     spec parsing, sides, changed files, show (pure parts unit-tested)
lua/annodiff/tree.lua    build + render file tree (pure, unit-tested)
lua/annodiff/view.lua    sessions, tab layout, diff windows, navigation
lua/annodiff/hunks.lua   line classification (+ / - / context), counterpart rows (pure)
lua/annodiff/annotations.lua  store, revdiff ## format + parse (pure)
lua/annodiff/annotate.lua     float input, extmarks, padding, picker, jumps, export, re-anchoring
lua/annodiff/persist.lua      review state JSON, atomic writes, revdiff history entries
tests/                   dependency-free runner: nvim --clean --headless -l tests/run.lua
```

## Known limits of slice 1

- Untracked files are not listed (same as `git diff`).
- File loads are synchronous (`vim.system():wait()`); fine for single files.
- Navigation maps live on the real file buffer while it is shown in the
  review; they are removed when the review moves to another file or closes.
- Tested on Neovim 0.12.5; 0.10 compatibility is by API choice, not by CI.
