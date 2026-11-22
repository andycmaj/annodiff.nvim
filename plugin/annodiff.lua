if vim.g.loaded_annodiff then
  return
end
vim.g.loaded_annodiff = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("annodiff.nvim needs Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Annodiff", function(cmd)
  require("annodiff").open(cmd.fargs)
end, {
  nargs = "*",
  desc = "Review a git diff: :Annodiff [--staged] [ref | A..B | A...B]",
  complete = function(arglead)
    local items = { "--staged" }
    vim.list_extend(items, require("annodiff.git").refs())
    return vim.tbl_filter(function(item)
      return vim.startswith(item, arglead)
    end, items)
  end,
})

vim.api.nvim_create_user_command("AnnodiffClose", function()
  require("annodiff").close()
end, { desc = "Close the review in this tab" })

vim.api.nvim_create_user_command("AnnodiffRefresh", function()
  require("annodiff").refresh()
end, { desc = "Reload the changed-file list of the review in this tab" })

vim.api.nvim_create_user_command("AnnodiffExport", function(cmd)
  require("annodiff").export(cmd.args)
end, { nargs = "?", complete = "file", desc = "Write annotations in revdiff ## format" })

vim.api.nvim_create_user_command("AnnodiffClear", function(cmd)
  require("annodiff").clear(cmd.bang)
end, { bang = true, desc = "Delete this review's annotations and reviewed marks (! skips the prompt)" })
