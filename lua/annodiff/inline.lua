-- Inline layout: one window with the new side (your real file when it is the
-- worktree). Added lines are highlighted; removed lines are drawn as "ghost"
-- virtual rows above the line they were removed before. A deleted file shows
-- its old content with every line marked removed.
local api = vim.api
local M = {}

function M.define_highlights()
  local links = {
    AnnodiffInlineAdd = "DiffAdd",
    AnnodiffInlineDelete = "DiffDelete",
    AnnodiffInlineDeleteSign = "Removed",
  }
  for group, link in pairs(links) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

--- Where a hunk's removed lines are drawn on the new side: above `row`, or
--- below the last line when the removal is at the end of the file.
---@param hunk annodiff.Hunk
---@param new_count integer
---@return integer row, boolean above
function M.ghost_row(hunk, new_count)
  local sb, cb = hunk[3], hunk[4]
  local row = cb > 0 and sb or sb + 1
  if row > new_count then
    return math.max(new_count, 1), new_count == 0
  end
  return math.max(row, 1), true
end

--- Removed (old) line numbers whose ghost rows sit at a new-side row.
---@param h annodiff.Hunk[]
---@param new_count integer
---@param row integer
---@return integer[]
function M.removed_at(h, new_count, row)
  local out = {}
  for _, hk in ipairs(h) do
    if hk[2] > 0 and (M.ghost_row(hk, new_count)) == row then
      for i = 0, hk[2] - 1 do
        table.insert(out, hk[1] + i)
      end
    end
  end
  return out
end

--- Rows to stop at for ]c / [c: the first changed line of each hunk, or the
--- line its removed lines sit above.
---@param h annodiff.Hunk[]
---@param new_count integer
---@return integer[]
function M.hunk_rows(h, new_count)
  local seen, rows = {}, {}
  for _, hk in ipairs(h) do
    local row = hk[4] > 0 and hk[3] or (M.ghost_row(hk, new_count))
    if not seen[row] then
      seen[row] = true
      table.insert(rows, row)
    end
  end
  table.sort(rows)
  return rows
end

local function ghost_text(text, width, tabstop)
  text = (text or ""):gsub("\t", string.rep(" ", tabstop))
  local w = vim.fn.strdisplaywidth(text)
  if w < width then
    text = text .. string.rep(" ", width - w)
  end
  return text
end

--- Highlights and ghost rows for the open file.
---@param s annodiff.Session
---@param h annodiff.Hunk[]
---@param entry_at fun(buf: integer, row: integer, above: boolean, side: string, line: integer): table
---@return table<integer, {rows: table}> ghosts old line -> its ghost slot (note rows go in after it)
function M.draw(s, h, entry_at)
  local annotate = require("annodiff.annotate")
  local ghosts = {}
  local win = s.win_new
  local info = vim.fn.getwininfo(win)[1]
  local width = math.max(20, api.nvim_win_get_width(win) - (info and info.textoff or 0))
  local tabstop = vim.bo[api.nvim_win_get_buf(win)].tabstop

  if s.inline_side == "old" then
    -- deleted file: the old content, all removed
    local buf = s.buf_old
    for i = 1, api.nvim_buf_line_count(buf) do
      api.nvim_buf_set_extmark(buf, annotate.ns, i - 1, 0, { line_hl_group = "AnnodiffInlineDelete", priority = 10 })
    end
    annotate.track(s, buf)
    return ghosts
  end

  local buf = s.buf_new
  local new_count = api.nvim_buf_line_count(buf)
  local new_lines_empty = new_count == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  local old = api.nvim_buf_get_lines(s.buf_old, 0, -1, false)
  for _, hk in ipairs(h) do
    local sa, ca, sb, cb = hk[1], hk[2], hk[3], hk[4]
    for i = 0, cb - 1 do
      pcall(api.nvim_buf_set_extmark, buf, annotate.ns, sb + i - 1, 0, {
        line_hl_group = "AnnodiffInlineAdd",
        sign_text = "+",
        sign_hl_group = "Added",
        priority = 10,
      })
    end
    if ca > 0 then
      local row, above = M.ghost_row(hk, new_lines_empty and 0 or new_count)
      local d = entry_at(buf, row, above, "new", row)
      d.ghosts = d.ghosts or {}
      for i = 0, ca - 1 do
        local slot = { rows = { { { ghost_text(old[sa + i], width, tabstop), "AnnodiffInlineDelete" } } } }
        table.insert(d.ghosts, slot)
        ghosts[sa + i] = slot
      end
    end
  end
  annotate.track(s, buf)
  return ghosts
end

return M
