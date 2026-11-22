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

--- Which side a window shows, or nil for the tree / foreign windows. In the
--- inline layout the one diff window shows the new side, or the old side for
--- a deleted file.
---@param s annodiff.Session
---@param win integer
---@return "old"|"new"|nil
function M.side_of(s, win)
  if s.layout == "inline" then
    return win == s.win_new and (s.inline_side or "new") or nil
  end
  if win == s.win_old then
    return "old"
  elseif win == s.win_new then
    return "new"
  end
end

--- Window showing a side, if any (inline: only the displayed side).
---@param s annodiff.Session
---@param side "old"|"new"
---@return integer?
function M.win_of(s, side)
  if s.layout == "inline" then
    return side == (s.inline_side or "new") and s.win_new or nil
  end
  return side == "old" and s.win_old or s.win_new
end

--- Buffer holding a side's content for the open file (shown or not).
---@param s annodiff.Session
---@param side "old"|"new"
function M.buf_of(s, side)
  return side == "old" and s.buf_old or s.buf_new
end

--- Whether the open file has a text diff (not binary).
function M.diffing(s)
  return s.current ~= nil and not s.binary and s.buf_old ~= nil and s.buf_new ~= nil
end

function M.lines_of(win)
  return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
end

--- A side's lines. A side with no file (added / deleted file) is {}, not the
--- single empty line an empty buffer holds.
function M.side_lines(s, side)
  if s.absent and s.absent[side] then
    return {}
  end
  local buf = M.buf_of(s, side)
  return buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_get_lines(buf, 0, -1, false) or {}
end

---@param s annodiff.Session
---@return annodiff.Hunk[]
function M.hunks(s)
  return hunks.compute(M.side_lines(s, "old"), M.side_lines(s, "new"))
end

--- Buffer and 1-based row of a record's own line (on its side's buffer).
---@param s annodiff.Session
---@param a annodiff.Annotation
local function anchor(s, a)
  if a.type == "-" then
    return M.buf_of(s, "old"), a.line
  end
  return M.buf_of(s, "new"), math.max(a.line, 1)
end
M.anchor = anchor

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
  local buf = M.buf_of(s, side == "old" and "new" or "old")
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
        local lines = M.side_lines(s, side)
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

--- Draw the open file's annotations and agent threads.
---
--- A record gets a tracking mark (sign, range) on its own line when that line
--- is on screen, and its text rows below its last line. Rows for one screen
--- row (annotations, then threads) are drawn by a single extmark, so their
--- order never depends on how Neovim ties same-row marks.
---
--- Split layout: diff mode ignores virtual lines, so every row block gets
--- blank padding at the counterpart line in the other window.
--- Inline layout: removed lines are ghost rows above where they were; rows of
--- records on removed lines go right under their ghost row.
---@param s annodiff.Session
function M.render(s)
  M.sync(s)
  M.clear(s)
  local e = entry(s)
  if not e or not s.buf_new then
    return
  end
  local h = M.diffing(s) and M.hunks(s) or nil
  M.reanchor(s, h)
  local inline = s.layout == "inline"
  local main_side = inline and (s.inline_side or "new") or nil

  local display, order = {}, {}
  local function entry_at(buf, row, above, side, line)
    local key = ("%d:%d:%s"):format(buf, row, tostring(above))
    local d = display[key]
    if not d then
      d = { buf = buf, row = row, above = above, lines = {}, side = side, line = line }
      display[key] = d
      table.insert(order, d)
    end
    return d
  end

  -- inline ghosts: old line -> { entry, rows } so notes can slot in under them
  local ghosts = {}
  if inline and h then
    ghosts = require("annodiff.inline").draw(s, h, entry_at)
  end

  --- Queue rows for a record on `side`, below line `last` (0 = file-level).
  local function place(side, line, last, rows)
    if line == 0 then
      local buf = inline and M.buf_of(s, main_side) or M.buf_of(s, "new")
      local d = entry_at(buf, 1, true, "new", 0)
      vim.list_extend(d.lines, rows)
      return
    end
    if inline and side ~= main_side then
      local g = ghosts[line]
      if g then
        vim.list_extend(g.rows, rows)
        return
      end
      -- not a removed line any more (stale record): under its counterpart
      local buf = M.buf_of(s, main_side)
      local row = h and hunks.counterpart(h, side, line) or 1
      row = math.max(1, math.min(row, api.nvim_buf_line_count(buf)))
      vim.list_extend(entry_at(buf, row, false, main_side, row).lines, rows)
      return
    end
    local buf = M.buf_of(s, side)
    vim.list_extend(entry_at(buf, last, false, side, last).lines, rows)
  end
  M.place = place

  for _, a in ipairs(s.store:get(e.path)) do
    local side = a.type == "-" and "old" or "new"
    local buf, row = anchor(s, a)
    local count = api.nvim_buf_line_count(buf)
    local clamped = row > count
    row = math.min(row, count)
    local last = row
    if a.end_line and a.end_line <= count and a.end_line > row then
      last = a.end_line
    end
    local on_screen = a.line > 0 and (not inline or side == main_side)
    if on_screen then
      local opts = {
        sign_text = "▍",
        sign_hl_group = "AnnodiffAnnotationSign",
        invalidate = true,
        undo_restore = false,
      }
      if last ~= row then
        opts.end_row = last - 1
        opts.end_col = 0
      end
      local ok, id = pcall(api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, opts)
      if ok then
        table.insert(s.marks, { annotation = a, buf = buf, id = id, clamped = clamped })
        M.track(s, buf)
      end
    end
    place(side, a.line, last, virt_lines(a))
  end
  if s.threads then
    require("annodiff.ask").render(s, place)
  end
  for _, d in ipairs(order) do
    local lines = d.lines
    if d.ghosts then
      lines = vim.list_slice(d.lines) -- e.g. a file-level note above line 1 comes first
      for _, g in ipairs(d.ghosts) do
        vim.list_extend(lines, g.rows)
      end
    end
    if #lines > 0 and pcall(api.nvim_buf_set_extmark, d.buf, M.ns, d.row - 1, 0, { virt_lines = lines, virt_lines_above = d.above }) then
      M.track(s, d.buf)
      if h and not inline and not d.ghosts then
        M.pad(s, h, d.side, d.line, #lines)
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

local function short(text)
  return vim.trim((text or ""):gsub("%s+", " ")):sub(1, 60)
end

--- What the cursor (or a visual range) points at, then cb(rec, hunk, existing).
--- In the inline layout, removed lines are ghost rows the cursor cannot reach:
--- on a line with ghost rows above it, a picker offers the line itself, each
--- removed line, and the whole removed block.
---@param s annodiff.Session
---@param range? {[1]: integer, [2]: integer}
---@param cb fun(rec: table, hunk?: annodiff.Hunk, existing?: annodiff.Annotation)
---@param verb string
function M.pick_target(s, range, cb, verb)
  local win = api.nvim_get_current_win()
  local side = M.side_of(s, win)
  if not side or not entry(s) then
    notify(verb .. " from a diff window", vim.log.levels.WARN)
    return
  end
  if not M.diffing(s) then
    notify("no text diff here; use the file-level key", vim.log.levels.WARN)
    return
  end
  local existing = not range and at_cursor(s, win, side)
  local rec, hunk = M.target(s, win, side, range)
  if existing then
    rec = { file = existing.file, line = existing.line, end_line = existing.end_line, type = existing.type }
  end
  local removed = {}
  if s.layout == "inline" and side == "new" and not range then
    local row = api.nvim_win_get_cursor(win)[1]
    removed = require("annodiff.inline").removed_at(M.hunks(s), api.nvim_buf_line_count(s.buf_new), row)
  end
  if #removed == 0 then
    return cb(rec, hunk, existing or nil)
  end
  local old = M.side_lines(s, "old")
  local new_text = api.nvim_get_current_line()
  local items = { { rec = rec, hunk = hunk, existing = existing or nil, label = ("this line %d (%s): %s"):format(rec.line, rec.type, short(new_text)) } }
  local e = entry(s)
  for _, l in ipairs(removed) do
    local r = { file = e.path, line = l, type = "-" }
    local ex = s.store:find(e.path, l, "-")
    table.insert(items, {
      rec = r,
      existing = ex,
      label = ("removed %d: %s%s"):format(l, short(old[l]), ex and "  [annotated]" or ""),
    })
  end
  if #removed > 1 then
    table.insert(items, {
      rec = { file = e.path, line = removed[1], end_line = removed[#removed], type = "-" },
      label = ("all removed lines %d-%d"):format(removed[1], removed[#removed]),
    })
  end
  vim.ui.select(items, {
    prompt = verb,
    format_item = function(it)
      return it.label
    end,
  }, function(choice)
    if choice then
      cb(choice.rec, choice.hunk, choice.existing)
    end
  end)
end

--- Annotate the cursor line or a visual range (\a).
---@param s annodiff.Session
---@param range? {[1]: integer, [2]: integer}
function M.annotate(s, range)
  M.pick_target(s, range, function(rec, hunk, existing)
    M.edit(s, rec, hunk, existing)
  end, "annotate")
end

--- Open the annotation editor for a target record.
function M.edit(s, rec, hunk, existing)
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
    rec.anchor = abuf and api.nvim_buf_get_lines(abuf, arow - 1, arow, false)[1] or nil
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
  if not side or not entry(s) then
    return
  end
  local candidates = {}
  local here = at_cursor(s, win, side)
  if here then
    table.insert(candidates, here)
  end
  if s.layout == "inline" and side == "new" and M.diffing(s) then
    local row = api.nvim_win_get_cursor(win)[1]
    for _, l in ipairs(require("annodiff.inline").removed_at(M.hunks(s), api.nvim_buf_line_count(s.buf_new), row)) do
      local a = s.store:find(entry(s).path, l, "-")
      if a then
        table.insert(candidates, a)
      end
    end
  end
  local function drop(a)
    s.store:delete(a.file, a.line, a.type)
    changed(s)
  end
  if #candidates == 0 then
    notify("no annotation on this line")
  elseif #candidates == 1 then
    drop(candidates[1])
  else
    vim.ui.select(candidates, {
      prompt = "delete annotation",
      format_item = function(a)
        return ("%d (%s): %s"):format(a.line, a.type, short(a.text))
      end,
    }, function(a)
      if a then
        drop(a)
      end
    end)
  end
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
  local side = a.type == "-" and "old" or "new"
  local win = M.win_of(s, side)
  local line = math.max(a.line, 1)
  if not win then
    -- inline: a removed line is a ghost row; land on the line it sits above
    win = s.win_new
    local h = M.hunks(s)
    local count = api.nvim_buf_line_count(s.buf_new)
    line = hunks.counterpart(h, "old", line)
    for _, hk in ipairs(h) do
      if hk[2] > 0 and a.line >= hk[1] and a.line < hk[1] + hk[2] then
        line = (require("annodiff.inline").ghost_row(hk, count))
      end
    end
  end
  local buf = api.nvim_win_get_buf(win)
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { math.min(math.max(line, 1), api.nvim_buf_line_count(buf)), 0 })
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
  local row = M.side_of(s, win) and api.nvim_win_get_cursor(win)[1] or 0
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
