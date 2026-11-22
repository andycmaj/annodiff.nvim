-- Annotations in a review: input float, extmarks + virt_lines, list, jumps, export.
local annotations = require("annodiff.annotations")
local hunks = require("annodiff.hunks")
local persist = require("annodiff.persist")

local api = vim.api
local M = {}

M.ns = api.nvim_create_namespace("annodiff_annotations")

local function notify(msg, level)
  vim.notify("annodiff: " .. msg, level or vim.log.levels.INFO)
end

function M.define_highlights()
  local links = {
    AnnodiffAnnotation = "DiagnosticVirtualTextInfo",
    AnnodiffAnnotationSign = "DiagnosticSignInfo",
    AnnodiffAnnotationHeader = "DiagnosticInfo",
    AnnodiffAnnotationCount = "DiagnosticInfo",
    AnnodiffAnnotationPad = "NonText",
    AnnodiffOrphan = "DiagnosticWarn",
    AnnodiffReviewed = "DiagnosticOk",
  }
  for group, link in pairs(links) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

---@param s annodiff.Session
local function entry(s)
  return s.current and s.files[s.current]
end

--- Which side a window shows, or nil for the tree / foreign windows.
---@param s annodiff.Session
---@param win integer
---@return "old"|"new"|nil
function M.side_of(s, win)
  if win == s.win_old then
    return "old"
  elseif win == s.win_new then
    return "new"
  end
end

function M.lines_of(win)
  return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
end

---@param s annodiff.Session
---@return annodiff.Hunk[]
function M.hunks(s)
  return hunks.compute(M.lines_of(s.win_old), M.lines_of(s.win_new))
end

--- Buffer and 1-based row where a record is drawn.
---@param s annodiff.Session
---@param a annodiff.Annotation
local function anchor(s, a)
  if a.type == "-" then
    return api.nvim_win_get_buf(s.win_old), a.line
  end
  return api.nvim_win_get_buf(s.win_new), math.max(a.line, 1)
end

-- Rendering -----------------------------------------------------------------

---@param s annodiff.Session
function M.clear(s)
  for _, buf in ipairs(s.annot_bufs or {}) do
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    end
  end
  s.annot_bufs = {}
  s.marks = {}
end

--- Copy extmark positions back into the records (edits in the real buffer move them).
---@param s annodiff.Session
function M.sync(s)
  for _, m in ipairs(s.marks or {}) do
    local a = m.annotation
    -- orphans and marks drawn at a clamped row are not where the record says:
    -- reading them back would rewrite the record with an unrelated line
    if a.line > 0 and not a.orphan and not m.clamped and api.nvim_buf_is_valid(m.buf) then
      local pos = api.nvim_buf_get_extmark_by_id(m.buf, M.ns, m.id, { details = true })
      if pos[1] and not (pos[3] and pos[3].invalid) then
        local line = pos[1] + 1
        a.anchor = api.nvim_buf_get_lines(m.buf, pos[1], pos[1] + 1, false)[1] or a.anchor
        if line ~= a.line then
          local existing = s.store:find(a.file, line, a.type)
          if not existing or existing == a then
            if a.end_line then
              a.end_line = a.end_line + (line - a.line)
            end
            a.line = line
          end
        end
      end
    end
  end
end

local function virt_lines(a)
  local out = {}
  local label = a.line == 0 and "file" or (a.end_line and ("lines %d-%d"):format(a.line, a.end_line)) or nil
  for i, text in ipairs(vim.split(a.text, "\n", { plain = true })) do
    local chunks = { { "  ▍ ", "AnnodiffAnnotationSign" } }
    if i == 1 and a.orphan then
      table.insert(chunks, { "orphaned, was here: ", "AnnodiffOrphan" })
    end
    if i == 1 and label then
      table.insert(chunks, { label .. ": ", "AnnodiffAnnotationHeader" })
    end
    table.insert(chunks, { text, "AnnodiffAnnotation" })
    table.insert(out, chunks)
  end
  return out
end

function M.track(s, buf)
  if not vim.tbl_contains(s.annot_bufs, buf) then
    table.insert(s.annot_bufs, buf)
  end
end

--- Diff mode does not count virtual lines when it lines the two windows up, so
--- every annotation gets the same number of blank virtual lines on the other
--- side, at the line sharing its screen row.
function M.pad(s, h, side, line, height)
  local other_win = side == "old" and s.win_new or s.win_old
  local buf = api.nvim_win_get_buf(other_win)
  local count = api.nvim_buf_line_count(buf)
  local above = line == 0
  local row = above and 1 or hunks.counterpart(h, side, line)
  if row < 1 then
    row, above = 1, true
  end
  row = math.min(row, count)
  local lines = {}
  for i = 1, height do
    lines[i] = { { "", "AnnodiffAnnotationPad" } }
  end
  pcall(api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, { virt_lines = lines, virt_lines_above = above })
  M.track(s, buf)
end

--- Records loaded from disk point at the line where they were saved. Find
--- their anchor text again: same line, else the nearest line with that text.
--- New-side records are reclassified ("+" may have become context). Not found
--- means orphaned: kept, drawn at the old line, flagged.
---@param s annodiff.Session
---@param h? annodiff.Hunk[]
function M.reanchor(s, h)
  local e = entry(s)
  for _, a in ipairs(s.store:get(e.path)) do
    if a.pending then
      a.pending = nil
      if a.line > 0 and a.anchor then
        local side = a.type == "-" and "old" or "new"
        local lines = M.lines_of(side == "old" and s.win_old or s.win_new)
        local found
        if lines[a.line] == a.anchor then
          found = a.line
        else
          for d = 1, #lines do
            if lines[a.line - d] == a.anchor then
              found = a.line - d
              break
            elseif lines[a.line + d] == a.anchor then
              found = a.line + d
              break
            end
          end
        end
        if found then
          if a.end_line then
            a.end_line = a.end_line + (found - a.line)
          end
          a.line = found
          a.orphan = nil
          if side == "new" and h then
            a.type = hunks.classify(h, "new", found)
          end
        else
          a.orphan = true
        end
      end
    end
  end
end

--- Write the review state (annotations + reviewed files) to .git/annodiff/reviews/.
---@param s annodiff.Session
function M.save(s)
  if not s.state_path then
    return
  end
  local ok, err = persist.write_atomic(s.state_path, persist.encode(s.store, s.reviewed or {}, s.spec.label))
  if not ok then
    notify("could not save review state: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Draw the open file's annotations: a tracking mark with the sign on the
--- first line (spanning the range), the text below the last line. Text rows
--- for one screen row (annotations, then agent threads) are drawn by a single
--- extmark, so their order never depends on how Neovim ties same-row marks.
---@param s annodiff.Session
function M.render(s)
  M.sync(s)
  M.clear(s)
  local e = entry(s)
  if not e then
    return
  end
  local diffing = vim.wo[s.win_old].diff and vim.wo[s.win_new].diff
  local h = diffing and M.hunks(s) or nil
  M.reanchor(s, h)

  local display, order = {}, {}
  --- Queue virtual rows under (or above) a line. side/line feed the padding.
  local function show(buf, row, above, rows, side, line)
    local key = ("%d:%d:%s"):format(buf, row, tostring(above))
    local d = display[key]
    if not d then
      d = { buf = buf, row = row, above = above, lines = {}, side = side, line = line }
      display[key] = d
      table.insert(order, d)
    end
    vim.list_extend(d.lines, rows)
  end

  for _, a in ipairs(s.store:get(e.path)) do
    local buf, row = anchor(s, a)
    local count = api.nvim_buf_line_count(buf)
    local clamped = row > count
    row = math.min(row, count)
    local opts = {
      sign_text = "▍",
      sign_hl_group = "AnnodiffAnnotationSign",
      invalidate = true,
      undo_restore = false,
    }
    local last = row
    if a.end_line and a.end_line <= count and a.end_line > row then
      opts.end_row = a.end_line - 1
      opts.end_col = 0
      last = a.end_line
    end
    local ok, id = pcall(api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, opts)
    if ok then
      table.insert(s.marks, { annotation = a, buf = buf, id = id, clamped = clamped })
      M.track(s, buf)
      show(buf, a.line == 0 and 1 or last, a.line == 0, virt_lines(a), a.type == "-" and "old" or "new", a.line == 0 and 0 or last)
    end
  end
  if s.threads then
    require("annodiff.ask").render(s, show)
  end
  for _, d in ipairs(order) do
    if pcall(api.nvim_buf_set_extmark, d.buf, M.ns, d.row - 1, 0, { virt_lines = d.lines, virt_lines_above = d.above }) then
      M.track(s, d.buf)
      if h then
        M.pad(s, h, d.side, d.line, #d.lines)
      end
    end
  end
end

-- Input -----------------------------------------------------------------------

--- Floating editor. on_done(text) gets the trimmed text, or nil on cancel.
---@param title string
---@param initial string
---@param on_done fun(text: string?)
function M.input(title, initial, on_done)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
  local width = math.min(80, math.max(40, math.floor(vim.o.columns * 0.5)))
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 5,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "left",
    footer = " <C-s> save · <Esc><Esc> or q cancel · empty deletes ",
    footer_pos = "right",
  })
  vim.wo[win].wrap = true
  local done = false
  local function finish(save)
    if done then
      return
    end
    done = true
    local text = save and vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")) or nil
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    vim.cmd("stopinsert")
    vim.schedule(function()
      on_done(text)
    end)
  end
  local o = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    finish(true)
  end, o)
  vim.keymap.set("n", "<CR>", function()
    finish(true)
  end, o)
  vim.keymap.set("n", "q", function()
    finish(false)
  end, o)
  vim.keymap.set("n", "<Esc>", function()
    finish(false)
  end, o)
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      finish(false)
    end,
  })
  if initial == "" then
    vim.cmd("startinsert")
  end
  return buf, win, finish
end

-- Actions ---------------------------------------------------------------------

---@param s annodiff.Session
local function changed(s)
  M.render(s)
  require("annodiff.view").render_tree(s)
  M.save(s)
end
M.changed = changed

--- The record under the cursor on this side, if any.
---@param s annodiff.Session
local function at_cursor(s, win, side)
  local e = entry(s)
  local row = api.nvim_win_get_cursor(win)[1]
  M.sync(s)
  local covering
  for _, a in ipairs(s.store:get(e.path)) do
    if a.line > 0 and (a.type == "-") == (side == "old") then
      if a.line == row then
        return a -- a record starting here beats a range that covers the line
      end
      if not covering and row > a.line and row <= (a.end_line or a.line) then
        covering = a
      end
    end
  end
  return covering
end

--- Target record (file, line, end_line, type) for the cursor or a visual range.
---@param s annodiff.Session
---@param range? {[1]: integer, [2]: integer}
function M.target(s, win, side, range)
  local e = entry(s)
  local h = M.hunks(s)
  local first = range and range[1] or api.nvim_win_get_cursor(win)[1]
  local type, line, hunk = hunks.classify(h, side, first)
  local rec = { file = e.path, line = line, type = type }
  if range and range[2] > range[1] then
    local _, last = hunks.classify(h, side, range[2])
    rec.end_line = last
  end
  return rec, hunk
end

--- Annotate the cursor line or a visual range (\a).
---@param s annodiff.Session
---@param range? {[1]: integer, [2]: integer}
function M.annotate(s, range)
  local win = api.nvim_get_current_win()
  local side = M.side_of(s, win)
  if not side or not entry(s) then
    notify("annotate from a diff window", vim.log.levels.WARN)
    return
  end
  if not vim.wo[win].diff then
    notify("no text diff here; use file-level annotation", vim.log.levels.WARN)
    return
  end
  local existing = not range and at_cursor(s, win, side)
  local rec, hunk = M.target(s, win, side, range)
  if existing then
    rec = { file = existing.file, line = existing.line, end_line = existing.end_line, type = existing.type }
  end
  local where = rec.end_line and ("%d-%d"):format(rec.line, rec.end_line) or tostring(rec.line)
  M.input(("%s:%s (%s)"):format(rec.file, where, rec.type), existing and existing.text or "", function(text)
    if text == nil then
      return
    end
    if text == "" then
      if existing then
        s.store:delete(existing.file, existing.line, existing.type)
        changed(s)
      end
      return
    end
    rec.text = text
    local abuf, arow = anchor(s, rec)
    rec.anchor = api.nvim_buf_get_lines(abuf, arow - 1, arow, false)[1]
    -- revdiff: "hunk" in the comment widens a +/- line to the end of its block
    if not rec.end_line and hunk and vim.regex([[\c\<hunk\>]]):match_str(text) then
      local last = hunks.block_end(hunk, rec.type)
      if last > rec.line then
        rec.end_line = last
      end
    end
    s.store:add(rec)
    changed(s)
  end)
end

--- File-level annotation (\A).
---@param s annodiff.Session
function M.annotate_file(s)
  local e = entry(s)
  if not e then
    return
  end
  local existing = s.store:find(e.path, 0, "")
  M.input(e.path .. " (file-level)", existing and existing.text or "", function(text)
    if text == nil then
      return
    end
    if text == "" then
      if existing then
        s.store:delete(e.path, 0, "")
        changed(s)
      end
      return
    end
    s.store:add({ file = e.path, line = 0, type = "", text = text })
    changed(s)
  end)
end

--- Delete the annotation under the cursor (\d).
---@param s annodiff.Session
function M.delete(s)
  local win = api.nvim_get_current_win()
  local side = M.side_of(s, win)
  local a = side and at_cursor(s, win, side)
  if not a then
    notify("no annotation on this line")
    return
  end
  s.store:delete(a.file, a.line, a.type)
  changed(s)
end

--- All records in review order (tree file order, then line).
---@param s annodiff.Session
---@return {index: integer, annotation: annodiff.Annotation}[]
function M.ordered(s)
  M.sync(s)
  local out = {}
  for i, e in ipairs(s.files) do
    for _, a in ipairs(s.store:get(e.path)) do
      table.insert(out, { index = i, annotation = a })
    end
  end
  -- records whose file is no longer in the review still count
  local known = {}
  for _, e in ipairs(s.files) do
    known[e.path] = true
  end
  for _, file in ipairs(s.store:files()) do
    if not known[file] then
      for _, a in ipairs(s.store:get(file)) do
        table.insert(out, { annotation = a })
      end
    end
  end
  return out
end

--- Open a record's file and put the cursor on it.
---@param s annodiff.Session
---@param item {index?: integer, annotation: annodiff.Annotation}
function M.jump(s, item)
  if not item.index then
    notify(item.annotation.file .. " is no longer in this review", vim.log.levels.WARN)
    return
  end
  local view = require("annodiff.view")
  if s.current ~= item.index then
    view.open_file(s, item.index, { hunk = false })
  end
  local a = item.annotation
  local win = a.type == "-" and s.win_old or s.win_new
  local buf = api.nvim_win_get_buf(win)
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { math.min(math.max(a.line, 1), api.nvim_buf_line_count(buf)), 0 })
  vim.cmd("normal! zz")
end

--- Next / previous annotation, crossing files (\n / \N).
---@param s annodiff.Session
---@param dir 1|-1
function M.step(s, dir)
  local items = vim.tbl_filter(function(it)
    return it.index ~= nil
  end, M.ordered(s))
  if #items == 0 then
    notify("no annotations")
    return
  end
  local win = api.nvim_get_current_win()
  local row = (win == s.win_old or win == s.win_new) and api.nvim_win_get_cursor(win)[1] or 0
  local cur = s.current or 0
  local function key(it)
    return it.index * 1e7 + it.annotation.line
  end
  local here = cur * 1e7 + row
  local pick
  if dir > 0 then
    for _, it in ipairs(items) do
      if key(it) > here then
        pick = it
        break
      end
    end
  else
    for i = #items, 1, -1 do
      if key(items[i]) < here then
        pick = items[i]
        break
      end
    end
  end
  if not pick then
    notify(dir > 0 and "no more annotations" or "no earlier annotations")
    return
  end
  M.jump(s, pick)
end

local function describe(a)
  local where = a.line == 0 and "file" or a.end_line and ("%d-%d"):format(a.line, a.end_line) or tostring(a.line)
  local first = vim.split(a.text, "\n", { plain = true })[1]
  return ("%s:%s (%s) %s%s"):format(a.file, where, a.type == "" and "file" or a.type, first, a.orphan and "  [orphaned]" or "")
end

--- Pick an annotation and jump to it (\l).
---@param s annodiff.Session
function M.list(s)
  local items = M.ordered(s)
  if #items == 0 then
    notify("no annotations")
    return
  end
  vim.ui.select(items, {
    prompt = "Annotations",
    format_item = function(it)
      return describe(it.annotation)
    end,
  }, function(choice)
    if choice then
      M.jump(s, choice)
    end
  end)
end

--- Default export path: <git-dir>/annodiff/annotations.md
---@param s annodiff.Session
function M.default_path(s)
  return vim.fs.joinpath(persist.git_dir(s.root), "annodiff", "annotations.md")
end

--- Write the revdiff `##` export. Returns the path written.
---@param s annodiff.Session
---@param path? string
---@return string? path
function M.export(s, path)
  M.sync(s)
  path = path and path ~= "" and vim.fn.fnamemodify(vim.fn.expand(path), ":p") or M.default_path(s)
  local ok, err = persist.write_atomic(path, s.store:format())
  if not ok then
    notify("export failed: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end
  return path
end

---@param s annodiff.Session
function M.new_store(s)
  s.store = annotations.new()
  s.marks = {}
  s.annot_bufs = {}
  s.reviewed = {}
end

--- Load saved state for this review into an empty store. Returns the count.
---@param s annodiff.Session
function M.restore(s)
  s.state_path = persist.state_path(s.root, s.spec)
  local state, err = persist.load(s.state_path)
  if err then
    notify(err .. ": " .. s.state_path, vim.log.levels.WARN)
    s.state_path = nil -- never overwrite a file we could not read
    return 0
  end
  if not state then
    return 0
  end
  for _, a in ipairs(state.annotations) do
    local rec = s.store:add(a)
    rec.pending = rec.line > 0 and rec.anchor ~= nil
  end
  s.reviewed = state.reviewed
  return #state.annotations
end

return M
