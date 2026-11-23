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
  desc = "Review a git diff: :Annodiff [--staged] [--inline|--split] [ref | A..B | A...B | --base [branch] | --pr [N|URL]], or a document: :Annodiff <file.md> | --doc [file] [ref]",
  complete = function(arglead)
    local items = { "--staged", "--inline", "--split", "--base", "--pr", "--doc" }
    vim.list_extend(items, require("annodiff.git").refs())
    -- documents: markdown files and the directories leading to them
    local is_markdown = require("annodiff.doc").is_markdown
    for _, f in ipairs(vim.fn.getcompletion(arglead, "file")) do
      if f:sub(-1) == "/" or is_markdown(f) then
        table.insert(items, f)
      end
    end
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

vim.api.nvim_create_user_command("AnnodiffSend", function()
  require("annodiff").send()
end, { desc = "Send annotations to the configured command (revdiff post-flush)" })

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("annodiff_leave", { clear = true }),
  callback = function()
    if package.loaded["annodiff.view"] then
      require("annodiff.view").close_all_leaving()
    end
  end,
})

vim.api.nvim_create_user_command("AnnodiffLayout", function(cmd)
  require("annodiff.view").layout_current(cmd.args)
end, {
  nargs = "?",
  complete = function()
    return { "inline", "split" }
  end,
  desc = "Switch the review between split and inline (no argument toggles)",
})
