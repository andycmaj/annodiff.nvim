-- Review sessions: one tab page with the file tree and two native diff windows.
local config = require("annodiff.config")
local git = require("annodiff.git")
local tree = require("annodiff.tree")
local annotate = require("annodiff.annotate")
local persist = require("annodiff.persist")
local send = require("annodiff.send")

local api = vim.api
local M = {}

local ns = api.nvim_create_namespace("annodiff")

---@class annodiff.Session
---@field id integer
---@field root string
---@field spec annodiff.Spec
---@field files annodiff.Entry[]
---@field tree_root annodiff.TreeDir
---@field map annodiff.TreeLine[]
---@field collapsed table<string, boolean>
---@field current? integer
---@field tab integer
---@field win_tree integer
---@field win_old integer
---@field win_new integer
---@field buf_tree integer
---@field real_buf? integer   real file buffer we put maps on
---@field augroup integer
---@field closing? boolean

---@type table<integer, annodiff.Session>
local sessions = {}
local next_id = 0

local function notify(msg, level)
  vim.notify("annodiff: " .. msg, level or vim.log.levels.INFO)
end

local function define_highlights()
  local links = {
    AnnodiffHeader = "Title",
    AnnodiffDim = "Comment",
    AnnodiffDirectory = "Directory",
    AnnodiffCurrent = "Visual",
    AnnodiffStatusModified = "Changed",
    AnnodiffStatusAdded = "Added",
    AnnodiffStatusDeleted = "Removed",
    AnnodiffStatusRenamed = "Changed",
    AnnodiffStatusOther = "Special",
  }
  for group, link in pairs(links) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
  annotate.define_highlights()
end

---@return annodiff.Session?
function M.current()
  return sessions[api.nvim_get_current_tabpage()]
end

local function valid(s)
  return api.nvim_tabpage_is_valid(s.tab)
    and api.nvim_win_is_valid(s.win_tree)
    and api.nvim_win_is_valid(s.win_old)
    and api.nvim_win_is_valid(s.win_new)
end

-- Keymaps ------------------------------------------------------------------

local function each_lhs(lhs, fn)
  if not lhs then
    return
  end
  if type(lhs) == "table" then
    for _, l in ipairs(lhs) do
      fn(l)
    end
  else
    fn(lhs)
  end
end

--- Navigation maps shared by every buffer in the review.
---@param s annodiff.Session
---@param buf integer
---@param opts {close: boolean}
local function nav_maps(s, buf, opts)
  local km = config.options.keymaps
  local function map(lhs, rhs, desc)
    each_lhs(lhs, function(l)
      vim.keymap.set("n", l, rhs, { buffer = buf, nowait = true, silent = true, desc = "annodiff: " .. desc })
    end)
  end
  map(km.next_file, function()
    M.step_file(s, vim.v.count1)
  end, "next file")
  map(km.prev_file, function()
    M.step_file(s, -vim.v.count1)
  end, "previous file")
  if opts.close then
    map(km.close, function()
      M.close(s)
    end, "close review")
  end
  map(km.annotate_file, function()
    annotate.annotate_file(s)
  end, "file-level annotation")
  map(km.list_annotations, function()
    annotate.list(s)
  end, "list annotations")
  map(km.next_annotation, function()
    annotate.step(s, 1)
  end, "next annotation")
  map(km.prev_annotation, function()
    annotate.step(s, -1)
  end, "previous annotation")
  map(km.send, function()
    send.send(s)
  end, "send annotations")
  if not opts.tree then
    map(km.toggle_reviewed, function()
      M.toggle_reviewed(s, s.current)
    end, "toggle reviewed")
  end
end

local function diff_maps(s, buf)
  local km = config.options.keymaps
  each_lhs(km.annotate, function(l)
    vim.keymap.set("n", l, function()
      annotate.annotate(s)
    end, { buffer = buf, silent = true, desc = "annodiff: annotate line" })
    vim.keymap.set("x", l, function()
      local a, b = vim.fn.line("v"), vim.fn.line(".")
      if a > b then
        a, b = b, a
      end
      vim.cmd("normal! \27") -- leave visual mode before the float opens
      annotate.annotate(s, { a, b })
    end, { buffer = buf, silent = true, desc = "annodiff: annotate range" })
  end)
  each_lhs(km.delete_annotation, function(l)
    vim.keymap.set("n", l, function()
      annotate.delete(s)
    end, { buffer = buf, silent = true, desc = "annodiff: delete annotation" })
  end)
  each_lhs(km.next_hunk, function(l)
    vim.keymap.set("n", l, function()
      M.step_hunk(s, 1)
    end, { buffer = buf, silent = true, desc = "annodiff: next hunk (crosses files)" })
  end)
  each_lhs(km.prev_hunk, function(l)
    vim.keymap.set("n", l, function()
      M.step_hunk(s, -1)
    end, { buffer = buf, silent = true, desc = "annodiff: previous hunk (crosses files)" })
  end)
end

local function unmap_real(s)
  local buf = s.real_buf
  s.real_buf = nil
  if s.real_autocmd then
    pcall(api.nvim_del_autocmd, s.real_autocmd)
    s.real_autocmd = nil
  end
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  local km = config.options.keymaps
  for _, key in ipairs({
    "next_file",
    "prev_file",
    "next_hunk",
    "prev_hunk",
    "annotate",
    "annotate_file",
    "delete_annotation",
    "list_annotations",
    "next_annotation",
    "prev_annotation",
    "toggle_reviewed",
    "send",
  }) do
    each_lhs(km[key], function(l)
      pcall(vim.keymap.del, "n", l, { buffer = buf })
      pcall(vim.keymap.del, "x", l, { buffer = buf })
    end)
  end
end

-- Buffers ------------------------------------------------------------------

--- Read-only buffer holding one side of a file. Show it with show_scratch().
local function scratch(s, lines, path)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  bo.bufhidden = "wipe"
  bo.swapfile = false
  bo.modifiable = false
  bo.readonly = true
  if path then
    local ft = vim.filetype.match({ filename = path, buf = buf })
    if ft then
      bo.filetype = ft
    end
  end
  nav_maps(s, buf, { close = true })
  diff_maps(s, buf)
  return buf
end

--- Put a scratch buffer in a window, then name it. Naming after the swap lets
--- the buffer it replaces (bufhidden=wipe) free the name first.
local function show_scratch(s, win, buf, name)
  api.nvim_win_set_buf(win, buf)
  pcall(api.nvim_buf_set_name, buf, ("annodiff://%d/%s"):format(s.id, name))
end

local function binary_placeholder(entry)
  return { "Binary file: " .. entry.path, "(no text diff)" }
end

-- Tree ---------------------------------------------------------------------

--- Paths the tree filter hides (the open file always stays).
---@param s annodiff.Session
---@return table<string, boolean>
function M.hidden(s)
  local hidden = {}
  if not s.filter then
    return hidden
  end
  for i, e in ipairs(s.files) do
    local keep = (s.filter == "annotated" and s.store:count(e.path) > 0)
      or (s.filter == "unreviewed" and not s.reviewed[e.path])
    if not keep and i ~= s.current then
      hidden[e.path] = true
    end
  end
  return hidden
end

---@param s annodiff.Session
function M.render_tree(s)
  local header = git.side_label(s.spec.left) .. " → " .. git.side_label(s.spec.right)
  local counts = {}
  for _, file in ipairs(s.store:files()) do
    counts[file] = s.store:count(file)
  end
  local reviewed = 0
  for _, e in ipairs(s.files) do
    if s.reviewed[e.path] then
      reviewed = reviewed + 1
    end
  end
  local summary = reviewed > 0 and (" · %d reviewed"):format(reviewed) or ""
  if s.filter then
    summary = summary .. " · only " .. s.filter
  end
  local lines, map, hls = tree.render(s.tree_root, s.files, {
    header = header,
    collapsed = s.collapsed,
    current = s.current,
    counts = counts,
    reviewed = s.reviewed,
    hidden = M.hidden(s),
    summary = summary,
  })
  s.map = map
  local buf = s.buf_tree
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    if h.line_hl then
      api.nvim_buf_set_extmark(buf, ns, h.line, 0, { line_hl_group = h.group, priority = 50 })
    else
      local end_col = h.col_end == -1 and #lines[h.line + 1] or h.col_end
      api.nvim_buf_set_extmark(buf, ns, h.line, h.col_start, { end_col = end_col, hl_group = h.group })
    end
  end
end

local function tree_line_of(s, index)
  for i, item in ipairs(s.map) do
    if item.kind == "file" and item.index == index then
      return i
    end
  end
end

local function tree_select(s)
  local row = api.nvim_win_get_cursor(s.win_tree)[1]
  local item = s.map[row]
  if not item then
    return
  end
  if item.kind == "dir" then
    s.collapsed[item.path] = not s.collapsed[item.path] or nil
    M.render_tree(s)
    api.nvim_win_set_cursor(s.win_tree, { math.min(row, #s.map), 0 })
  elseif item.kind == "file" then
    M.open_file(s, item.index, { focus = "new" })
  end
end

local function setup_tree(s)
  local buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, buf, ("annodiff://%d/tree"):format(s.id))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "annodiff"
  s.buf_tree = buf
  api.nvim_win_set_buf(s.win_tree, buf)

  local wo = vim.wo[s.win_tree]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.wrap = false
  wo.spell = false
  wo.list = false
  wo.cursorline = true
  wo.winfixwidth = true
  api.nvim_win_set_width(s.win_tree, config.options.tree_width)

  local km = config.options.keymaps
  nav_maps(s, buf, { close = true, tree = true })
  local function tmap(lhs, fn, desc)
    each_lhs(lhs, function(l)
      vim.keymap.set("n", l, fn, { buffer = buf, nowait = true, silent = true, desc = "annodiff: " .. desc })
    end)
  end
  tmap(km.tree_toggle_reviewed, function()
    local item = s.map[api.nvim_win_get_cursor(s.win_tree)[1]]
    if item and item.kind == "file" then
      M.toggle_reviewed(s, item.index)
    end
  end, "toggle reviewed")
  tmap(km.tree_send, function()
    send.send(s)
  end, "send annotations")
  tmap(km.filter_annotated, function()
    M.set_filter(s, "annotated")
  end, "show only annotated files")
  tmap(km.filter_unreviewed, function()
    M.set_filter(s, "unreviewed")
  end, "show only unreviewed files")
  each_lhs(km.select, function(l)
    vim.keymap.set("n", l, function()
      tree_select(s)
    end, { buffer = buf, nowait = true, silent = true, desc = "annodiff: open file / toggle directory" })
  end)
  each_lhs(km.refresh, function(l)
    vim.keymap.set("n", l, function()
      M.refresh(s)
    end, { buffer = buf, nowait = true, silent = true, desc = "annodiff: refresh" })
  end)
end

-- Diff windows -------------------------------------------------------------

local function in_diff(lnum)
  return vim.fn.diff_hlID(lnum, 1) ~= 0 or vim.fn.diff_filler(lnum) > 0
end

---@param win integer
---@param where "first"|"last"
local function goto_hunk(win, where)
  api.nvim_win_call(win, function()
    if where == "first" then
      api.nvim_win_set_cursor(win, { 1, 0 })
      if not in_diff(1) then
        pcall(vim.cmd, "normal! ]c")
      end
    else
      local last = api.nvim_buf_line_count(0)
      api.nvim_win_set_cursor(win, { last, 0 })
      if in_diff(last) then
        local l = last
        while l > 1 and in_diff(l - 1) do
          l = l - 1
        end
        api.nvim_win_set_cursor(win, { l, 0 })
      else
        pcall(vim.cmd, "normal! [c")
      end
    end
  end)
end

local function setup_diff_window(win)
  vim.wo[win].winfixwidth = false
end

---@param s annodiff.Session
---@param index integer
---@param opts? {focus?: "tree"|"old"|"new", hunk?: "first"|"last"|false}
function M.open_file(s, index, opts)
  opts = opts or {}
  if not valid(s) then
    notify("review layout is broken; run :AnnodiffClose", vim.log.levels.WARN)
    return
  end
  local entry = s.files[index]
  if not entry then
    return
  end
  local root, spec = s.root, s.spec
  local old_path = entry.old_path or entry.path

  local old_lines, old_bin = git.show(root, spec.left, old_path)
  local real_path = vim.fs.joinpath(root, entry.path)
  local use_real = spec.right.kind == "worktree" and entry.status ~= "D" and vim.fn.filereadable(real_path) == 1
  local new_lines, new_bin
  if use_real then
    -- read once to rule out binary files before handing them to :edit
    new_lines, new_bin = git.show(root, spec.right, entry.path)
  elseif entry.status ~= "D" then
    new_lines, new_bin = git.show(root, spec.right, entry.path)
  end
  local binary = old_bin or new_bin

  api.nvim_set_current_tabpage(s.tab)
  annotate.sync(s)
  annotate.save(s)
  annotate.clear(s)
  vim.cmd("diffoff!")
  unmap_real(s)

  local left_name = git.side_label(spec.left) .. "/" .. old_path
  local right_name = git.side_label(spec.right) .. "/" .. entry.path

  if binary then
    show_scratch(s, s.win_old, scratch(s, binary_placeholder(entry)), left_name)
    show_scratch(s, s.win_new, scratch(s, binary_placeholder(entry)), right_name)
  else
    show_scratch(s, s.win_old, scratch(s, old_lines or {}, old_path), left_name)
    if use_real then
      api.nvim_win_call(s.win_new, function()
        vim.cmd.edit(vim.fn.fnameescape(real_path))
      end)
      local buf = api.nvim_win_get_buf(s.win_new)
      nav_maps(s, buf, { close = false })
      diff_maps(s, buf)
      s.real_buf = buf
      -- edits shift hunks: redraw annotations (and their padding) once typing settles
      s.real_autocmd = api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
        group = s.augroup,
        buffer = buf,
        callback = function()
          vim.schedule(function()
            if s.real_buf == buf and valid(s) then
              annotate.render(s)
            end
          end)
        end,
      })
    else
      show_scratch(s, s.win_new, scratch(s, new_lines or {}, entry.path), right_name)
    end
    for _, win in ipairs({ s.win_old, s.win_new }) do
      api.nvim_win_call(win, function()
        vim.cmd("diffthis")
      end)
      setup_diff_window(win)
    end
  end

  s.current = index
  annotate.render(s)
  for _, dir in ipairs(tree.ancestors(entry.path)) do
    s.collapsed[dir] = nil
  end
  M.render_tree(s)
  local row = tree_line_of(s, index)
  if row then
    api.nvim_win_set_cursor(s.win_tree, { row, 0 })
  end

  if not binary and opts.hunk ~= false then
    goto_hunk(s.win_new, opts.hunk or "first")
  end
  local focus = opts.focus and s["win_" .. opts.focus]
  if focus and api.nvim_win_is_valid(focus) then
    api.nvim_set_current_win(focus)
  end
end

local function focused_side(s)
  local win = api.nvim_get_current_win()
  if win == s.win_tree then
    return "tree"
  elseif win == s.win_old then
    return "old"
  end
  return "new"
end

---@param s annodiff.Session
---@param delta integer
---@param hunk? "first"|"last"
function M.step_file(s, delta, hunk)
  if #s.files == 0 then
    return
  end
  local hidden = M.hidden(s)
  local step = delta > 0 and 1 or -1
  local target = s.current or 0
  for _ = 1, math.abs(delta) do
    local next_target = target + step
    while s.files[next_target] and hidden[s.files[next_target].path] do
      next_target = next_target + step
    end
    if not s.files[next_target] then
      break
    end
    target = next_target
  end
  if target == (s.current or 0) or target < 1 then
    notify(delta > 0 and "last file" or "first file")
    return
  end
  M.open_file(s, target, { focus = focused_side(s), hunk = hunk })
end

--- Toggle the reviewed mark of a file (revdiff <Space>).
---@param s annodiff.Session
---@param index? integer
function M.toggle_reviewed(s, index)
  local e = index and s.files[index]
  if not e then
    return
  end
  s.reviewed[e.path] = not s.reviewed[e.path] or nil
  M.render_tree(s)
  annotate.save(s)
end

--- Toggle a tree filter ("annotated" / "unreviewed"); the same one again clears it.
---@param s annodiff.Session
---@param kind "annotated"|"unreviewed"
function M.set_filter(s, kind)
  s.filter = s.filter ~= kind and kind or nil
  M.render_tree(s)
  local row = s.current and tree_line_of(s, s.current)
  if row then
    api.nvim_win_set_cursor(s.win_tree, { row, 0 })
  end
end

--- Native ]c / [c, then on to the adjacent file at the first / last hunk.
---@param s annodiff.Session
---@param dir 1|-1
function M.step_hunk(s, dir)
  local win = api.nvim_get_current_win()
  if win ~= s.win_old and win ~= s.win_new then
    win = s.win_new
  end
  local count = vim.v.count1
  local moved = false
  api.nvim_win_call(win, function()
    local before = api.nvim_win_get_cursor(win)[1]
    if vim.wo[win].diff then
      pcall(vim.cmd, "normal! " .. count .. (dir > 0 and "]c" or "[c"))
    end
    moved = api.nvim_win_get_cursor(win)[1] ~= before
  end)
  if not moved then
    M.step_file(s, dir, dir > 0 and "first" or "last")
  end
end

-- Lifecycle ----------------------------------------------------------------

--- Save, export, history, send-on-close. Everything a review does on the way out
--- that does not touch windows (also runs when Neovim exits).
---@param s annodiff.Session
local function finish(s)
  if not s.store then
    return
  end
  annotate.sync(s)
  annotate.save(s)
  if s.store:count() > 0 and send.on_close_enabled() and send.command() then
    send.send(s, { wait = true, quiet_if_same = true })
  end
  local qa = s.threads and s.threads:format_history() or ""
  if s.store:count() == 0 and qa == "" then
    return
  end
  local msg
  if s.store:count() > 0 then
    local path = annotate.export(s)
    msg = path and ("%d annotation(s) saved to %s"):format(s.store:count(), path)
  end
  if config.options.history then
    local files = vim.tbl_filter(function(f)
      return f ~= ""
    end, s.store:files())
    local hist, herr = persist.save_history({
      root = s.root,
      ref = s.spec.ref,
      diff_args = s.spec.diff_args,
      annotations = s.store:format(),
      agent_qa = qa,
      files = files,
    }, config.options.history_dir)
    if hist then
      msg = (msg or "review") .. "; history " .. hist
    elseif herr then
      notify("history not written: " .. tostring(herr), vim.log.levels.WARN)
    end
  end
  if msg then
    notify(msg)
  end
end

---@param s annodiff.Session
---@param opts? {leaving?: boolean} leaving: Neovim is exiting, leave the windows alone
function M.close(s, opts)
  if s.closing then
    return
  end
  s.closing = true
  sessions[s.tab] = nil
  if s.on_close then
    pcall(s.on_close, s)
  end
  finish(s)
  if opts and opts.leaving then
    return
  end
  annotate.clear(s)
  unmap_real(s)
  pcall(api.nvim_del_augroup_by_id, s.augroup)
  if not api.nvim_tabpage_is_valid(s.tab) then
    return
  end
  api.nvim_set_current_tabpage(s.tab)
  vim.cmd("diffoff!")
  if #api.nvim_list_tabpages() > 1 then
    vim.cmd("tabclose")
  else
    vim.cmd("enew")
    vim.cmd("only")
  end
end

--- Finish every open review (VimLeavePre).
function M.close_all_leaving()
  for _, s in pairs(vim.deepcopy(sessions, true)) do
    M.close(s, { leaving = true })
  end
end

function M.close_current()
  local s = M.current()
  if not s then
    notify("no review in this tab", vim.log.levels.WARN)
    return
  end
  M.close(s)
end

---@param s annodiff.Session
function M.refresh(s)
  local entries, err = git.changed_files(s.root, s.spec)
  if not entries then
    notify(err, vim.log.levels.ERROR)
    return
  end
  local path = s.current and s.files[s.current] and s.files[s.current].path
  s.tree_root, s.files = tree.build(entries)
  local index = 1
  for i, e in ipairs(s.files) do
    if e.path == path then
      index = i
    end
  end
  if #s.files == 0 then
    s.current = nil
    M.render_tree(s)
    notify("no changes left")
    return
  end
  local cursor = api.nvim_win_is_valid(s.win_new) and api.nvim_win_get_cursor(s.win_new)
  M.open_file(s, index, { focus = focused_side(s), hunk = false })
  if cursor and s.files[index].path == path then
    pcall(api.nvim_win_set_cursor, s.win_new, cursor)
  else
    goto_hunk(s.win_new, "first")
  end
end

---@param path? string
function M.export_current(path)
  local s = M.current()
  if not s then
    notify("no review in this tab", vim.log.levels.WARN)
    return
  end
  local written = annotate.export(s, path)
  if written then
    notify(("%d annotation(s) written to %s"):format(s.store:count(), written))
  end
  return written
end

--- Drop this review's annotations and reviewed marks, on screen and on disk.
function M.clear_current(force)
  local s = M.current()
  if not s then
    notify("no review in this tab", vim.log.levels.WARN)
    return
  end
  local n = s.store:count()
  if not force and vim.fn.confirm(("Delete %d annotation(s) and reviewed marks?"):format(n), "&Yes\n&No", 2) ~= 1 then
    return
  end
  s.store:clear()
  s.reviewed = {}
  annotate.changed(s)
  notify(("cleared %d annotation(s)"):format(n))
end

function M.refresh_current()
  local s = M.current()
  if not s then
    notify("no review in this tab", vim.log.levels.WARN)
    return
  end
  M.refresh(s)
end

---@param args string[]
---@return annodiff.Session?
function M.open(args)
  define_highlights()
  local root, rerr = git.root()
  if not root then
    notify(rerr, vim.log.levels.ERROR)
    return
  end
  local spec, serr = git.parse_spec(args)
  if spec then
    spec, serr = git.resolve(root, spec)
  end
  if not spec then
    notify(serr, vim.log.levels.ERROR)
    return
  end
  local entries, ferr = git.changed_files(root, spec)
  if not entries then
    notify(ferr, vim.log.levels.ERROR)
    return
  end
  if #entries == 0 then
    notify("no changes (" .. spec.label .. ")")
    return
  end

  next_id = next_id + 1
  vim.cmd("tabnew")
  local placeholder = api.nvim_get_current_buf()
  vim.bo[placeholder].bufhidden = "wipe"
  local s = {
    id = next_id,
    root = root,
    spec = spec,
    collapsed = {},
    map = {},
    tab = api.nvim_get_current_tabpage(),
    win_new = api.nvim_get_current_win(),
  }
  s.tree_root, s.files = tree.build(entries)
  annotate.new_store(s)
  local restored = annotate.restore(s)
  vim.cmd("leftabove vsplit")
  s.win_old = api.nvim_get_current_win()
  vim.cmd("topleft vsplit")
  s.win_tree = api.nvim_get_current_win()
  setup_tree(s)
  vim.cmd.tcd(vim.fn.fnameescape(root))

  s.augroup = api.nvim_create_augroup("annodiff_" .. s.id, { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = s.augroup,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win == s.win_tree or win == s.win_old or win == s.win_new then
        vim.schedule(function()
          M.close(s)
        end)
      end
    end,
  })
  api.nvim_create_autocmd("TabClosed", {
    group = s.augroup,
    callback = function()
      if not api.nvim_tabpage_is_valid(s.tab) then
        M.close(s)
      end
    end,
  })
  api.nvim_create_autocmd("ColorScheme", { group = s.augroup, callback = define_highlights })

  sessions[s.tab] = s
  M.open_file(s, 1, { focus = "new" })
  if restored > 0 then
    notify(("restored %d annotation(s)"):format(restored))
  end
  -- equalize the two diff windows, keep the tree at its width
  vim.cmd("wincmd =")
  api.nvim_win_set_width(s.win_tree, config.options.tree_width)
  return s
end

return M
