# annodiff.nvim

Review git diffs inside Neovim: a changed-file tree beside native diff windows,
with the worktree side as your real, editable file (LSP, treesitter, gitsigns
all work). Neovim port of [revdiff](https://github.com/andycmaj/revdiff).
Annotations and agent handoff come next (see [docs/plan.md](docs/plan.md)).

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

`:AnnodiffClose` and `:AnnodiffRefresh` act on the review in the current tab.
Each review opens in its own tab: `tree | old | new`.

### Keys

| Key | Where | Action |
|---|---|---|
| `<Tab>` / `<S-Tab>` | everywhere | next / previous file |
| `]c` / `[c` | diff windows | next / previous hunk; past the last / first hunk moves to the next / previous file |
| `<CR>` / `o` | tree | open file, or collapse / expand directory |
| `R` | tree | refresh the file list |
| `q` | tree, read-only buffers | close the review (not mapped on your real file buffers) |

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
  },
})
```

Set any key to `false` to disable it.

## Tests

```sh
make test   # nvim --clean --headless -l tests/run.lua
```

The end-to-end tests build throwaway git repos and drive the real UI headless.
