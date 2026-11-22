-- Hand annotations to an agent: revdiff's `O` flush + post-flush command.
-- The full current set goes to a shell command on stdin (stdout discarded),
-- and the same snapshot is written to the export file.
local config = require("annodiff.config")

local M = {}

local function notify(msg, level)
  vim.notify("annodiff: " .. msg, level or vim.log.levels.INFO)
end

--- The configured command: setup({send_command}), then $ANNODIFF_SEND_COMMAND,
--- then revdiff's $REVDIFF_POST_FLUSH_COMMAND.
---@return string?
function M.command()
  -- not ipairs: any of these may be nil
  local candidates = { config.options.send_command, vim.env.ANNODIFF_SEND_COMMAND, vim.env.REVDIFF_POST_FLUSH_COMMAND }
  for i = 1, 3 do
    local c = candidates[i]
    if type(c) == "string" and vim.trim(c) ~= "" then
      return vim.trim(c)
    end
  end
end

--- Send on close when configured, or when the launcher asked for it.
function M.on_close_enabled()
  return config.options.send_on_close or vim.env.ANNODIFF_SEND_ON_CLOSE == "1"
end

---@param s annodiff.Session
---@param opts? {wait?: boolean, quiet_if_same?: boolean}
---@return boolean started
function M.send(s, opts)
  opts = opts or {}
  local annotate = require("annodiff.annotate")
  annotate.sync(s)
  local n = s.store:count()
  if n == 0 then
    if not opts.quiet_if_same then
      notify("no annotations to send")
    end
    return false
  end
  local content = s.store:format()
  if opts.quiet_if_same and content == s.last_sent then
    return false
  end
  local cmd = M.command()
  if not cmd then
    notify("no send command: set send_command in setup() or $ANNODIFF_SEND_COMMAND", vim.log.levels.WARN)
    return false
  end
  local path = annotate.export(s)
  local noun = n == 1 and "annotation" or "annotations"
  local function finished(res)
    if res.code == 0 then
      s.last_sent = content
      notify(("sent %d %s%s"):format(n, noun, path and (" (snapshot " .. path .. ")") or ""))
    else
      local first = vim.split(vim.trim(res.stderr or ""), "\n")[1]
      notify(
        ("send command failed (exit %d)%s"):format(res.code, first and first ~= "" and (": " .. first) or ""),
        vim.log.levels.ERROR
      )
    end
  end
  local on_exit = not opts.wait and function(res)
    vim.schedule(function()
      finished(res)
    end)
  end or nil
  local ok, proc = pcall(vim.system, { "sh", "-c", cmd }, { stdin = content, text = true, cwd = s.root }, on_exit)
  if not ok then
    notify("send command did not start: " .. tostring(proc), vim.log.levels.ERROR)
    return false
  end
  if opts.wait then
    finished(proc:wait())
  end
  return true
end

return M
