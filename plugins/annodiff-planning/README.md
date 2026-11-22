# annodiff-planning

Claude Code plugin that opens each plan Claude is about to present in Neovim
([annodiff.nvim](https://github.com/andycmaj/annodiff.nvim)) for annotation, before it
runs. Port of revdiff's `revdiff-planning`.

```text
/plugin marketplace add andycmaj/annodiff.nvim
/plugin install annodiff-planning@annodiff
```

Needs tmux, Neovim 0.10+, git and python3. annodiff's Lua is taken from `$ANNODIFF_RTP`,
the checkout this plugin sits in, the installed `annodiff` Claude plugin, or your own
Neovim config, in that order.

How it works, the launcher override and the differences from revdiff: see the
"Claude Code" section of the [main README](../../README.md#claude-code).
