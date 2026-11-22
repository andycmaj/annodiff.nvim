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
2. **Slice 2: annotations.** `a` float on a line or visual range, extmark +
   `virt_lines` + sign, anchored on whichever side the cursor is (old side
   annotations record `side = "old"`), quickfix list, `:AnnodiffExport` in
   revdiff `##` format.
3. **Slice 3: persistence + re-anchoring** in `.git/annodiff/`, reviewed marks
   in the tree, tree filter, history markdown.
4. **Slice 4: agent.** 4a `:AnnodiffSend` (export on stdin to a configured
   command, e.g. the aug / Claude handoff). 4b ask on a line/range with
   `claude -p`, answer inline as an `answer` annotation.
5. **Slice 5:** blame, untracked files toggle, word-diff tuning (native
   `diffopt` mostly covers it), async file loading with stale-load drop.
6. Later: jj / hg sources, compare mode, markdown TOC.

## Code layout

```
plugin/annodiff.lua      commands (:Annodiff, :AnnodiffClose, :AnnodiffRefresh)
lua/annodiff/init.lua    setup(opts), open/close/refresh API
lua/annodiff/config.lua  defaults
lua/annodiff/git.lua     spec parsing, sides, changed files, show (pure parts unit-tested)
lua/annodiff/tree.lua    build + render file tree (pure, unit-tested)
lua/annodiff/view.lua    sessions, tab layout, diff windows, navigation
tests/                   dependency-free runner: nvim --clean --headless -l tests/run.lua
```

## Known limits of slice 1

- Untracked files are not listed (same as `git diff`).
- File loads are synchronous (`vim.system():wait()`); fine for single files.
- Navigation maps live on the real file buffer while it is shown in the
  review; they are removed when the review moves to another file or closes.
- Tested on Neovim 0.12.5; 0.10 compatibility is by API choice, not by CI.
