# annodiff.nvim

Review git diffs inside Neovim: a changed-file tree beside native diff windows,
with the worktree side as your real, editable file (LSP, treesitter, gitsigns
all work). Neovim port of [revdiff](https://github.com/andycmaj/revdiff).
Annotate lines, ranges and files; export in revdiff's `##` format so the
revdiff agent skills read it unchanged. Persistence and agent handoff come next
(see [docs/plan.md](docs/plan.md)).

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

`:AnnodiffClose`, `:AnnodiffRefresh` and `:AnnodiffExport [path]` act on the
review in the current tab.
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

In the annotation float: `<C-s>` (or `<CR>` in normal mode) saves, `q` / `<Esc>`
in normal mode cancels.

## Annotations

Records follow revdiff: `+` added line (new-side number), `-` removed line
(old-side number), ` ` context line (new-side number, from either window),
file-level, and `start-end` ranges. A comment containing the word "hunk" on a
`+` / `-` line widens to the end of that changed block, as in revdiff.

Annotations on your real file follow edits. Each one gets matching blank
virtual lines in the other window so the two sides stay row-aligned.

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
  },
})
```

Set any key to `false` to disable it.

## Tests

```sh
make test   # nvim --clean --headless -l tests/run.lua
```

The end-to-end tests build throwaway git repos and drive the real UI headless.
