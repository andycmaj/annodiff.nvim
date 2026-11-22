-- Agent Q&A threads, one per anchor (file, line, type). Separate from
-- annotations: never exported or sent; only history records them.
-- Port of revdiff feat/ask-agent app/agent/threads.go.
local M = {}

---@class annodiff.Turn
---@field question string
---@field answer string

---@class annodiff.Thread
---@field id integer
---@field session_id? string  set once the agent has started a session
---@field file string
---@field line integer         0 = file-level
---@field end_line? integer
---@field type string
---@field turns annodiff.Turn[]
---@field status "idle"|"streaming"|"failed"
---@field activity? string     last tool use or stall note while streaming
---@field err? string
---@field version integer      bumped on every change

---@class annodiff.Threads
---@field by_id table<integer, annodiff.Thread>
---@field next_id integer
local Threads = {}
Threads.__index = Threads

function M.new()
  return setmetatable({ by_id = {}, next_id = 0 }, Threads)
end

local function bump(t)
  t.version = (t.version or 0) + 1
end

---@return annodiff.Thread?
function Threads:get(file, line, type)
  for _, t in pairs(self.by_id) do
    if t.file == file and t.line == line and t.type == type then
      return t
    end
  end
end

function Threads:by(id)
  return self.by_id[id]
end

--- Start a thread, or a new turn on the existing one at this anchor.
---@param anchor {file: string, line: integer, end_line?: integer, type: string}
---@param question string
---@return annodiff.Thread
function Threads:ask(anchor, question)
  local t = self:get(anchor.file, anchor.line, anchor.type)
  if not t then
    self.next_id = self.next_id + 1
    t = {
      id = self.next_id,
      file = anchor.file,
      line = anchor.line,
      end_line = anchor.end_line,
      type = anchor.type,
      turns = {},
      status = "idle",
      version = 0,
    }
    self.by_id[t.id] = t
  end
  table.insert(t.turns, { question = question, answer = "" })
  t.status, t.err, t.activity = "streaming", nil, nil
  bump(t)
  return t
end

--- Re-send the last question of a failed thread.
---@return annodiff.Thread?
function Threads:retry(id)
  local t = self.by_id[id]
  if not t or t.status ~= "failed" or #t.turns == 0 then
    return nil
  end
  t.turns[#t.turns].answer = ""
  t.status, t.err, t.activity = "streaming", nil, nil
  bump(t)
  return t
end

--- Apply an agent event. Returns false when the thread is gone.
function Threads:apply(id, ev)
  local t = self.by_id[id]
  if not t then
    return false
  end
  local turn = t.turns[#t.turns]
  if ev.kind == "text" then
    turn.answer = turn.answer .. ev.text
    t.activity = nil
  elseif ev.kind == "tool" then
    t.activity = ev.text
  elseif ev.kind == "stalled" then
    t.activity = ev.text ~= "" and ev.text or nil
  elseif ev.kind == "done" then
    if vim.trim(turn.answer) == "" and ev.text then
      turn.answer = ev.text
    end
    if ev.session_id and ev.session_id ~= "" then
      t.session_id = ev.session_id
    end
    t.status, t.activity = "idle", nil
  elseif ev.kind == "failed" then
    t.status, t.err, t.activity = "failed", ev.text, nil
  end
  bump(t)
  return true
end

function Threads:delete(id)
  if not self.by_id[id] then
    return false
  end
  self.by_id[id] = nil
  return true
end

---@return annodiff.Thread[]
function Threads:for_file(file)
  local out = {}
  for _, t in pairs(self.by_id) do
    if t.file == file then
      table.insert(out, t)
    end
  end
  table.sort(out, function(a, b)
    return a.line < b.line or (a.line == b.line and a.id < b.id)
  end)
  return out
end

function Threads:streaming()
  local n = 0
  for _, t in pairs(self.by_id) do
    if t.status == "streaming" then
      n = n + 1
    end
  end
  return n
end

function Threads:count()
  return vim.tbl_count(self.by_id)
end

function M.heading(t)
  if t.line == 0 then
    return t.file .. " (file-level)"
  elseif t.end_line and t.end_line > t.line then
    return ("%s:%d-%d (%s)"):format(t.file, t.line, t.end_line, t.type)
  end
  return ("%s:%d (%s)"):format(t.file, t.line, t.type)
end

--- revdiff FormatHistory: `### heading`, **Q:** / **A:** turns, **Error:** on failure.
function Threads:format_history()
  local all = vim.tbl_values(self.by_id)
  table.sort(all, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.type < b.type
  end)
  local out = {}
  for _, t in ipairs(all) do
    table.insert(out, ("### %s\n\n"):format(M.heading(t)))
    for _, turn in ipairs(t.turns) do
      table.insert(out, ("**Q:** %s\n\n"):format(vim.trim(turn.question)))
      local answer = vim.trim(turn.answer)
      if answer ~= "" then
        table.insert(out, ("**A:** %s\n\n"):format(answer))
      end
    end
    if t.status == "failed" and t.err and t.err ~= "" then
      table.insert(out, ("**Error:** %s\n\n"):format(t.err))
    end
  end
  return table.concat(out)
end

return M
