-- `claude -p --output-format stream-json` parser, ported from revdiff
-- (feat/ask-agent, app/agent/stream.go).
--
-- Events:
--   { kind = "text", text }            answer text delta
--   { kind = "tool", text }            "read x.txt", "$ git log -1"
--   { kind = "done", text, session_id } final result
--   { kind = "failed", text }
local M = {}

local MAX_TOOL_SUMMARY = 80

---@class annodiff.StreamParser
---@field work_dir string
---@field session_id? string
---@field wrote_text boolean
---@field need_break boolean
---@field finished boolean
local Parser = {}
Parser.__index = Parser

---@param work_dir? string trimmed from tool paths so summaries read repo-relative
---@param session_id? string
function M.new(work_dir, session_id)
  return setmetatable({
    work_dir = work_dir or "",
    session_id = session_id,
    wrote_text = false,
    need_break = false,
    finished = false,
  }, Parser)
end

--- Collapse whitespace / control characters, optionally truncating with an ellipsis.
function M.clean(s, limit)
  s = vim.trim((s or ""):gsub("[%s%c]+", " "))
  if limit and limit > 0 and vim.fn.strchars(s) > limit then
    return vim.fn.strcharpart(s, 0, limit) .. "…"
  end
  return s
end

function Parser:rel(path)
  local prefix = self.work_dir:gsub("/$", "") .. "/"
  if self.work_dir ~= "" and path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

function Parser:tool_summary(name, input)
  input = type(input) == "table" and input or {}
  local verb, arg = (name or ""):lower(), nil
  if type(input.command) == "string" and input.command ~= "" then
    verb, arg = "$", input.command
  elseif type(input.file_path) == "string" and input.file_path ~= "" then
    arg = self:rel(input.file_path)
  elseif type(input.pattern) == "string" and input.pattern ~= "" then
    arg = input.pattern
  elseif type(input.path) == "string" and input.path ~= "" then
    arg = self:rel(input.path)
  end
  return M.clean(arg and (verb .. " " .. arg) or verb, MAX_TOOL_SUMMARY)
end

--- Feed one line. Returns the events it produced; done/failed end the stream.
---@param raw string
---@return table[]
function Parser:line(raw)
  local out = {}
  if self.finished then
    return out
  end
  local ok, l = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok or type(l) ~= "table" then
    return out
  end
  if type(l.session_id) == "string" and l.session_id ~= "" then
    self.session_id = l.session_id
  end
  -- subagent output belongs to a tool call, not to the answer
  if type(l.parent_tool_use_id) == "string" and l.parent_tool_use_id ~= "" then
    return out
  end
  if l.type == "stream_event" and type(l.event) == "table" then
    local ev = l.event
    if ev.type == "message_start" then
      if self.wrote_text then
        self.need_break, self.wrote_text = true, false
      end
    elseif ev.type == "content_block_delta" and type(ev.delta) == "table" then
      local d = ev.delta
      if d.type == "text_delta" and type(d.text) == "string" and d.text ~= "" then
        local text = d.text
        if self.need_break then
          text, self.need_break = "\n\n" .. text, false
        end
        self.wrote_text = true
        table.insert(out, { kind = "text", text = text })
      end
    end
  elseif l.type == "assistant" and type(l.message) == "table" then
    for _, c in ipairs(l.message.content or {}) do
      if type(c) == "table" and c.type == "tool_use" then
        table.insert(out, { kind = "tool", text = self:tool_summary(c.name, c.input) })
      end
    end
  elseif l.type == "result" then
    -- a result for a side turn (e.g. a task notification replayed by a forked
    -- session) is not the answer to our question
    if l.origin ~= nil then
      return out
    end
    self.finished = true
    local failed = l.is_error == true or (type(l.subtype) == "string" and l.subtype ~= "" and l.subtype ~= "success")
    if failed then
      local msg = vim.trim(type(l.result) == "string" and l.result or "")
      if msg == "" and type(l.errors) == "table" then
        msg = table.concat(vim.tbl_filter(function(e)
          return type(e) == "string"
        end, l.errors), "; ")
      end
      if msg == "" then
        msg = "agent failed: " .. tostring(l.subtype)
      end
      table.insert(out, { kind = "failed", text = M.clean(msg) })
    else
      table.insert(out, { kind = "done", text = type(l.result) == "string" and l.result or "", session_id = self.session_id })
    end
  end
  return out
end

--- Line-buffered feeding for raw stdout chunks.
---@param chunk string
---@return table[]
function Parser:feed(chunk)
  self.pending = (self.pending or "") .. chunk
  local out = {}
  while true do
    local nl = self.pending:find("\n", 1, true)
    if not nl then
      break
    end
    local raw = self.pending:sub(1, nl - 1)
    self.pending = self.pending:sub(nl + 1)
    vim.list_extend(out, self:line(raw))
  end
  return out
end

--- Flush a trailing line without a newline (end of stream).
function Parser:flush()
  local rest = self.pending or ""
  self.pending = ""
  if rest ~= "" then
    return self:line(rest)
  end
  return {}
end

return M
