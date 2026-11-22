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
---@field toggle_reviewed string|false
---@field tree_toggle_reviewed string|false
---@field filter_annotated string|false
---@field filter_unreviewed string|false
---@field send string|false
---@field tree_send string|false

---@class annodiff.Config
---@field tree_width integer
---@field history boolean write a revdiff-format history entry when a review with annotations closes
---@field history_dir? string default $REVDIFF_HISTORY_DIR or ~/.config/revdiff/history
---@field send_command? string default $ANNODIFF_SEND_COMMAND, then $REVDIFF_POST_FLUSH_COMMAND
---@field send_on_close boolean also when $ANNODIFF_SEND_ON_CLOSE=1
---@field keymaps annodiff.Keymaps
M.defaults = {
  tree_width = 35,
  history = true,
  history_dir = nil,
  send_command = nil, -- sh -c command; annotations on stdin (revdiff post-flush-command)
  send_on_close = false, -- also send on close when the set changed since the last send
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
    toggle_reviewed = "<localleader>r", -- diff windows; <Space> in the tree
    tree_toggle_reviewed = "<Space>",
    filter_annotated = "f",
    filter_unreviewed = "F",
    send = "<localleader>s",
    tree_send = "O",
  },
}

---@type annodiff.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
