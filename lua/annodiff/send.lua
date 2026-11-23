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

--- Send on close: false, "changed" (the set, when it changed since the last send) or
--- "always" (the command runs on every close, with empty stdin when there is nothing
--- new, so whoever launched the review learns it ended). From setup({send_on_close}),
--- else $ANNODIFF_SEND_ON_CLOSE ("1" or "always").
---@return false|"changed"|"always"
function M.on_close_mode()
  local function mode(v)
    if v == "always" then
      return "always"
    elseif v == true or v == "1" or v == "changed" then
      return "changed"
    end
  end
  return mode(config.options.send_on_close) or mode(vim.env.ANNODIFF_SEND_ON_CLOSE) or false
end

--- Send on close when configured, or when the launcher asked for it.
function M.on_close_enabled()
  return M.on_close_mode() ~= false
end

--- Run the send command. The set goes on stdin; the command also gets
--- $ANNODIFF_SEND_REASON ("send", or "close" when the review is closing) and
--- $ANNODIFF_ANNOTATION_COUNT.
---@param s annodiff.Session
---@param opts? {wait?: boolean, quiet_if_same?: boolean, reason?: "send"|"close", always?: boolean}
---   always: run the command even with nothing new to send (empty stdin), as a close notice
---@return boolean started
function M.send(s, opts)
  opts = opts or {}
  local annotate = require("annodiff.annotate")
  annotate.sync(s)
  local n = s.store:count()
  local content = n > 0 and s.store:format() or ""
  local fresh = n > 0 and not (opts.quiet_if_same and content == s.last_sent)
  if not fresh and not opts.always then
    if n == 0 and not opts.quiet_if_same then
      notify("no annotations to send")
    end
    return false
  end
  local cmd = M.command()
  if not cmd then
    notify("no send command: set send_command in setup() or $ANNODIFF_SEND_COMMAND", vim.log.levels.WARN)
    return false
  end
  local path = fresh and annotate.export(s) or nil
  local noun = n == 1 and "annotation" or "annotations"
  local function finished(res)
    if res.code ~= 0 then
      local first = vim.split(vim.trim(res.stderr or ""), "\n")[1]
      notify(
        ("send command failed (exit %d)%s"):format(res.code, first and first ~= "" and (": " .. first) or ""),
        vim.log.levels.ERROR
      )
    elseif fresh then
      s.last_sent = content
      notify(("sent %d %s%s"):format(n, noun, path and (" (snapshot " .. path .. ")") or ""))
    else
      notify(n == 0 and "closed with no annotations (told the agent)" or "closed, nothing new to send (told the agent)")
    end
  end
  local on_exit = not opts.wait and function(res)
    vim.schedule(function()
      finished(res)
    end)
  end or nil
  local env = { ANNODIFF_SEND_REASON = opts.reason or "send", ANNODIFF_ANNOTATION_COUNT = tostring(n) }
  local ok, proc = pcall(
    vim.system,
    { "sh", "-c", cmd },
    { stdin = fresh and content or "", text = true, cwd = s.root, env = env },
    on_exit
  )
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
