# annodiff.nvim

Review git diffs inside Neovim: a changed-file tree beside native diff windows,
with the worktree side as your real, editable file (LSP, treesitter, gitsigns
all work). Neovim port of [revdiff](https://github.com/andycmaj/revdiff).
Annotate lines, ranges and files; export in revdiff's `##` format so the
revdiff agent skills read it unchanged. Annotations and reviewed marks persist
per review and follow the code when it moves. Agent handoff comes next (see
[docs/plan.md](docs/plan.md)).

Neovim 0.10+, no dependencies.

## Install

lazy.nvim:

```lua
{ "andycmaj/annodiff.nvim", cmd = { "Annodiff" }, opts = {} }
```

## Use

| Command | Left | Right |
|---|---|---|
| `:Annodiff` | index | worktree |
| `:Annodiff <ref>` | `<ref>` | worktree |
| `:Annodiff --staged [ref]` | `<ref>` (default `HEAD`) | index |
| `:Annodiff A..B` | `A` | `B` |
| `:Annodiff A...B` | merge base of `A` and `B` | `B` |

`:AnnodiffClose`, `:AnnodiffRefresh`, `:AnnodiffExport [path]`, `:AnnodiffSend` and
`:AnnodiffClear[!]` (drop annotations and reviewed marks; `!` skips the prompt)
act on the review in the current tab.
Each review opens in its own tab: `tree | old | new`.

### Keys

| Key | Where | Action |
|---|---|---|
| `<Tab>` / `<S-Tab>` | everywhere | next / previous file |
| `]c` / `[c` | diff windows | next / previous hunk; past the last / first hunk moves to the next / previous file |
| `<CR>` / `o` | tree | open file, or collapse / expand directory |
| `R` | tree | refresh the file list |
| `q` | tree, read-only buffers | close the review (not mapped on your real file buffers) |
| `<localleader>a` | diff windows (normal / visual) | annotate the line or range; on an annotated line, edit it (save empty to delete) |
| `<localleader>A` | everywhere | file-level annotation |
| `<localleader>d` | diff windows | delete the annotation under the cursor |
| `<localleader>l` | everywhere | pick an annotation (`vim.ui.select`) and jump to it |
| `<localleader>n` / `<localleader>N` | everywhere | next / previous annotation, across files |
| `<Space>` | tree | mark the file under the cursor reviewed (✓) |
| `<localleader>r` | diff windows | mark the open file reviewed |
| `f` / `F` | tree | show only annotated / only unreviewed files (again to clear); `<Tab>` skips hidden files |
| `<localleader>s` / `O` (tree) | everywhere | send the annotations to your agent (see below) |

In the annotation float: `<C-s>` (or `<CR>` in normal mode) saves, `q` / `<Esc>`
in normal mode cancels.

## Annotations

Records follow revdiff: `+` added line (new-side number), `-` removed line
(old-side number), ` ` context line (new-side number, from either window),
file-level, and `start-end` ranges. A comment containing the word "hunk" on a
`+` / `-` line widens to the end of that changed block, as in revdiff.

Annotations on your real file follow edits. Each one gets matching blank
virtual lines in the other window so the two sides stay row-aligned.

### Persistence

Each review (`:Annodiff HEAD`, `:Annodiff main...feature`, ...) keeps its
annotations and reviewed marks in `.git/annodiff/reviews/<review>.json`,
written on every change and restored when you open the same review again.
Each annotation stores its line's text; on restore it finds that text again
(same line, else the nearest match), so annotations follow code that moved.
When the text is gone the annotation is kept, drawn where it was, and flagged
"orphaned".

On close, a review with annotations also writes a history entry in revdiff's
format to `$REVDIFF_HISTORY_DIR` or `~/.config/revdiff/history/<repo>/`, so the
revdiff Claude skill's "use my latest revdiff annotations" finds it. Set
`history = false` to turn that off, or `history_dir` to move it.

### Sending to an agent

`:AnnodiffSend` (`\s`, or `O` in the tree) is revdiff's `O` flush with a
post-flush command: the full current set, in revdiff `##` format, goes on
stdin to a shell command, and the same snapshot is written to the export file.
The command comes from `send_command` in `setup()`, then
`$ANNODIFF_SEND_COMMAND`, then revdiff's `$REVDIFF_POST_FLUSH_COMMAND`. With
`send_on_close = true` (or `$ANNODIFF_SEND_ON_CLOSE=1`) closing the review or
quitting Neovim sends the set again if it changed since the last send.

`skills/annodiff/` is a Claude Code skill (`/annodiff`) built on that: it opens
the review in Neovim beside the Claude pane (a zoomed aug split, or a tmux
window) and pastes sent notes back into the Claude session, like the revdiff
`/revdiff` skill. Install it with
`ln -s "$PWD/skills/annodiff" ~/.claude/skills/annodiff`.

### Export

`:AnnodiffExport [path]` writes them (atomic, mode 0600); the default path is
`.git/annodiff/annotations.md`, and closing a review with annotations writes
there too. The output is byte-identical to what revdiff's own `FormatOutput`
produces for the same records.

Revision and index sides are read-only scratch buffers. Added and deleted files
show an empty side; binary files show a placeholder.

## Config

```lua
require("annodiff").setup({
  tree_width = 35,
  history = true, -- revdiff-format history entry on close
  history_dir = nil, -- default $REVDIFF_HISTORY_DIR or ~/.config/revdiff/history
  send_command = nil, -- sh -c; annotations on stdin
  send_on_close = false,
  keymaps = {
    next_file = "<Tab>",
    prev_file = "<S-Tab>",
    next_hunk = "]c",
    prev_hunk = "[c",
    select = { "<CR>", "o" },
    refresh = "R",
    close = "q",
    annotate = "<localleader>a",
    annotate_file = "<localleader>A",
    delete_annotation = "<localleader>d",
    list_annotations = "<localleader>l",
    next_annotation = "<localleader>n",
    prev_annotation = "<localleader>N",
    toggle_reviewed = "<localleader>r",
    tree_toggle_reviewed = "<Space>",
    filter_annotated = "f",
    filter_unreviewed = "F",
    send = "<localleader>s",
    tree_send = "O",
  },
})
```

Set any key to `false` to disable it.

## Tests

```sh
make test   # nvim --clean --headless -l tests/run.lua
```

The end-to-end tests build throwaway git repos and drive the real UI headless.
