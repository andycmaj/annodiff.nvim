-- Annotation store and the revdiff `##` record format (app/annotation in revdiff).
--
-- A record: { file, line, end_line?, type, text }
--   line 0 + type ""  file-level annotation
--   type "+" / "-" / " "  see annodiff.hunks
local M = {}

---@class annodiff.Annotation
---@field file string
---@field line integer
---@field end_line? integer
---@field type string
---@field text string
---@field seq? integer insertion order, keeps sorting stable

---@class annodiff.Store
---@field by_file table<string, annodiff.Annotation[]>
---@field seq integer
local Store = {}
Store.__index = Store

---@return annodiff.Store
function M.new()
  return setmetatable({ by_file = {}, seq = 0 }, Store)
end

---@return annodiff.Annotation?, integer?
function Store:find(file, line, type)
  for i, a in ipairs(self.by_file[file] or {}) do
    if a.line == line and a.type == type then
      return a, i
    end
  end
end

--- Add, or replace the text / range of the record at the same file, line and type.
---@param a annodiff.Annotation
---@return annodiff.Annotation
function Store:add(a)
  local existing = self:find(a.file, a.line, a.type)
  if existing then
    existing.text = a.text
    existing.end_line = a.end_line
    return existing
  end
  self.seq = self.seq + 1
  local rec = { file = a.file, line = a.line, end_line = a.end_line, type = a.type, text = a.text, seq = self.seq }
  self.by_file[a.file] = self.by_file[a.file] or {}
  table.insert(self.by_file[a.file], rec)
  return rec
end

---@return boolean
function Store:delete(file, line, type)
  local _, i = self:find(file, line, type)
  if not i then
    return false
  end
  table.remove(self.by_file[file], i)
  if #self.by_file[file] == 0 then
    self.by_file[file] = nil
  end
  return true
end

--- Records of a file sorted by line (file-level first). Returns the live records.
---@return annodiff.Annotation[]
function Store:get(file)
  local list = vim.list_slice(self.by_file[file] or {})
  table.sort(list, function(x, y)
    if x.line ~= y.line then
      return x.line < y.line
    end
    return x.seq < y.seq
  end)
  return list
end

---@return string[]
function Store:files()
  local files = vim.tbl_keys(self.by_file)
  table.sort(files)
  return files
end

function Store:count(file)
  if file then
    return #(self.by_file[file] or {})
  end
  local n = 0
  for _, list in pairs(self.by_file) do
    n = n + #list
  end
  return n
end

--- Body lines whose first non-space text is "## " get one leading space.
local function escape(body)
  if not body:find("## ", 1, true) then
    return body
  end
  local lines = vim.split(body, "\n", { plain = true })
  for i, l in ipairs(lines) do
    if l:match("^ *## ") then
      lines[i] = " " .. l
    end
  end
  return table.concat(lines, "\n")
end

--- revdiff FormatOutput: files alphabetical, records by line, blank line between.
---@return string
function Store:format()
  local out = {}
  for _, file in ipairs(self:files()) do
    for _, a in ipairs(self:get(file)) do
      local header
      if a.line == 0 then
        header = ("## %s (file-level)"):format(a.file)
      elseif a.end_line and a.end_line > 0 then
        header = ("## %s:%d-%d (%s)"):format(a.file, a.line, a.end_line, a.type)
      else
        header = ("## %s:%d (%s)"):format(a.file, a.line, a.type)
      end
      table.insert(out, header .. "\n" .. escape(a.text) .. "\n")
    end
  end
  return table.concat(out, "\n")
end

--- Parse FormatOutput markdown back into records (revdiff annotation.Parse).
---@param text string
---@return annodiff.Annotation[]? records, string? err
function M.parse(text)
  local records, current, body = {}, nil, {}
  local function flush()
    if not current then
      return
    end
    if body[#body] == "" then
      table.remove(body)
    end
    current.text = table.concat(body, "\n")
    table.insert(records, current)
    current, body = nil, {}
  end
  local function header(line)
    local rest, kind = line:match("^## (.+) %((.-)%)$")
    if not rest then
      return nil
    end
    if kind == "file-level" then
      return { file = rest, line = 0, type = "" }
    end
    if kind ~= "+" and kind ~= "-" and kind ~= " " then
      return nil
    end
    local file, l1, l2 = rest:match("^(.+):(%d+)%-(%d+)$")
    if file then
      return { file = file, line = tonumber(l1), end_line = tonumber(l2), type = kind }
    end
    file, l1 = rest:match("^(.+):(%d+)$")
    if file then
      return { file = file, line = tonumber(l1), type = kind }
    end
  end

  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  for _, line in ipairs(lines) do
    local h = line:sub(1, 3) == "## " and header(line)
    if h then
      flush()
      current = h
    elseif current then
      if line:match("^ +## ") then
        line = line:sub(2)
      end
      table.insert(body, line)
    elseif line:sub(1, 3) == "## " then
      return nil, ("malformed annotation header: %q"):format(line)
    elseif vim.trim(line) ~= "" then
      return nil, "annotation input has content before any header"
    end
  end
  flush()
  return records
end

return M
