local M = {}

---@class annodiff.Keymaps
---@field next_file string|false
---@field prev_file string|false
---@field next_hunk string|false
---@field prev_hunk string|false
---@field select string[]|string|false
---@field refresh string|false
---@field close string|false
---@field annotate string|false
---@field annotate_file string|false
---@field delete_annotation string|false
---@field list_annotations string|false
---@field next_annotation string|false
---@field prev_annotation string|false

---@class annodiff.Config
---@field tree_width integer
---@field keymaps annodiff.Keymaps
M.defaults = {
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
}

---@type annodiff.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
