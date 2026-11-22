local M = {}

---@param opts? annodiff.Config
function M.setup(opts)
  require("annodiff.config").setup(opts)
end

--- Open a review. Same arguments as :Annodiff, e.g. {}, {"main"}, {"--staged"}, {"main...HEAD"}.
---@param args? string[]
function M.open(args)
  return require("annodiff.view").open(args or {})
end

function M.close()
  require("annodiff.view").close_current()
end

--- Write the review's annotations in revdiff `##` format.
---@param path? string default <git-dir>/annodiff/annotations.md
function M.export(path)
  return require("annodiff.view").export_current(path)
end

function M.refresh()
  require("annodiff.view").refresh_current()
end

return M
