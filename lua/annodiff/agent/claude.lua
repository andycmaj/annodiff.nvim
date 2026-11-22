-- Headless `claude -p` runner for inline questions, ported from revdiff
-- (feat/ask-agent, app/agent/claude.go): read-only tool allowlist, prompt on
-- stdin, stream-json events, fork from a parent session, resume for follow-ups.
local stream = require("annodiff.agent.stream")

local M = {}

M.STALL_AFTER_MS = 20 * 1000 -- silence before the thread shows how long it has waited
M.WATCH_EVERY_MS = 5 * 1000
M.IDLE_TIMEOUT_MS = 5 * 60 * 1000 -- silence after which the agent is stopped and the thread fails
M.CANCEL_GRACE_MS = 2000

M.DEFAULT_SYSTEM_PROMPT = "You are answering a code reviewer's question from inside annodiff, a Neovim diff review plugin. "
  .. "The answer is shown inline under the line being reviewed, so lead with the direct answer, keep it short, "
  .. "and use markdown sparingly. Do not modify any files."

M.SHELL_GUIDANCE = "Shell access is limited to an allowlist of read-only commands and anything else is refused "
  .. "without a prompt. Run each command on its own as one simple invocation: no &&, ||, ;, pipes, redirects, "
  .. "$(...) or shell variables. If you need a value from one command, run it, read the output, then pass the "
  .. "literal value to the next command."

M.ALLOWED_TOOLS = {
  "Read", "Glob", "Grep",
  "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(git blame:*)",
  "Bash(git merge-base:*)", "Bash(git rev-parse:*)", "Bash(git ls-files:*)", "Bash(git ls-tree:*)",
  "Bash(jj status:*)", "Bash(jj diff:*)", "Bash(jj log:*)", "Bash(jj show:*)", "Bash(jj file show:*)",
  "Bash(hg status:*)", "Bash(hg diff:*)", "Bash(hg log:*)", "Bash(hg cat:*)",
  "Bash(wc:*)",
}

M.DISALLOWED_TOOLS = {
  "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch",
  "Bash(git -c:*)", "Bash(git --config-env:*)", "Bash(git diff --out*)", "Bash(git log --out*)",
  "Bash(git show --out*)", "Bash(jj --config:*)", "Bash(jj --config-toml:*)", "Bash(jj diff --tool:*)",
}

---@class annodiff.AgentConfig
---@field binary? string
---@field model? string
---@field args? string[]
---@field system_prompt? string

---@class annodiff.AgentRequest
---@field prompt string
---@field session_id string    fresh uuid for a first ask, the thread's id for a follow-up
---@field resume? boolean
---@field parent_session? string

function M.uuid()
  local bytes = vim.uv.random(16)
  local b = {}
  for i = 1, 16 do
    b[i] = bytes:byte(i)
  end
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do
    hex[i] = ("%02x"):format(b[i])
  end
  local h = table.concat(hex)
  return ("%s-%s-%s-%s-%s"):format(h:sub(1, 8), h:sub(9, 12), h:sub(13, 16), h:sub(17, 20), h:sub(21, 32))
end

--- Parent session to fork from: $ANNODIFF_AGENT_PARENT_SESSION, then revdiff's
--- $REVDIFF_AGENT_PARENT_SESSION. Tagged "claude:<id>"; another host's tag is ignored.
---@return string?
function M.parent_session()
  for _, raw in ipairs({ vim.env.ANNODIFF_AGENT_PARENT_SESSION or "", vim.env.REVDIFF_AGENT_PARENT_SESSION or "" }) do
    raw = vim.trim(raw)
    if raw ~= "" then
      local tag, id = raw:match("^(%w+):(.+)$")
      if not tag then
        return raw
      end
      if tag == "claude" then
        return id
      end
    end
  end
end

---@param cfg annodiff.AgentConfig
---@param req annodiff.AgentRequest
---@return string[]
function M.args(cfg, req)
  local system = cfg.system_prompt and cfg.system_prompt ~= "" and cfg.system_prompt or M.DEFAULT_SYSTEM_PROMPT
  local args = {
    cfg.binary or "claude",
    "-p", "--verbose", "--output-format", "stream-json", "--include-partial-messages",
    "--permission-mode", "dontAsk",
    "--setting-sources", "user",
    "--strict-mcp-config",
    "--allowedTools", table.concat(M.ALLOWED_TOOLS, ","),
    "--disallowedTools", table.concat(M.DISALLOWED_TOOLS, ","),
    "--append-system-prompt", system .. "\n\n" .. M.SHELL_GUIDANCE,
  }
  if req.resume then
    vim.list_extend(args, { "--resume", req.session_id })
  elseif req.parent_session and req.parent_session ~= "" then
    vim.list_extend(args, { "--resume", req.parent_session, "--fork-session", "--session-id", req.session_id })
  else
    vim.list_extend(args, { "--session-id", req.session_id })
  end
  if cfg.model and cfg.model ~= "" then
    vim.list_extend(args, { "--model", cfg.model })
  end
  vim.list_extend(args, cfg.args or {})
  return args
end

---@class annodiff.AgentJob
---@field cancel fun()

--- Start a request. on_event runs on the main loop, ends with exactly one
--- "done" or "failed" event. "stalled" events carry how long it has been quiet
--- (empty text clears it).
---@param cfg annodiff.AgentConfig
---@param req annodiff.AgentRequest
---@param work_dir string
---@param on_event fun(ev: table)
---@return annodiff.AgentJob? job, string? err
function M.ask(cfg, req, work_dir, on_event)
  local parser = stream.new(work_dir, req.session_id)
  local finished, canceled = false, false
  local stderr = ""
  local last_activity = vim.uv.now()
  local stalled = false
  local timer = vim.uv.new_timer()
  local proc

  local function emit(ev)
    if finished then
      return
    end
    if ev.kind == "done" or ev.kind == "failed" then
      finished = true
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    on_event(ev)
  end

  local function on_stdout(_, data)
    if not data then
      return
    end
    last_activity = vim.uv.now()
    -- parse on the main loop (the parser calls vim.fn); schedule keeps chunk order
    vim.schedule(function()
      local events = parser:feed(data)
      if stalled and not finished then
        stalled = false
        emit({ kind = "stalled", text = "" })
      end
      for _, ev in ipairs(events) do
        emit(ev)
      end
    end)
  end

  local function on_stderr(_, data)
    if data and #stderr < 4096 then
      stderr = stderr .. data:sub(1, 4096 - #stderr)
    end
  end

  local ok, res = pcall(vim.system, M.args(cfg, req), {
    cwd = work_dir,
    stdin = req.prompt,
    stdout = on_stdout,
    stderr = on_stderr,
    text = true,
    detach = true, -- own process group, so cancel reaches the agent's children too
  }, function(out)
    vim.schedule(function()
      for _, ev in ipairs(parser:flush()) do
        emit(ev)
      end
      if finished then
        return
      end
      local text
      if canceled then
        text = "canceled"
      elseif out.signal == 15 and (vim.uv.now() - last_activity) >= M.IDLE_TIMEOUT_MS then
        text = ("%s wrote nothing for %d minutes and was stopped"):format(cfg.binary or "claude", M.IDLE_TIMEOUT_MS / 60000)
      else
        for line in stderr:gmatch("[^\n]+") do
          if vim.trim(line) ~= "" then
            text = vim.trim(line)
            break
          end
        end
        text = text or (out.code ~= 0 and ("%s: exit status %d"):format(cfg.binary or "claude", out.code))
          or ((cfg.binary or "claude") .. " exited without an answer")
      end
      emit({ kind = "failed", text = text })
    end)
  end)
  if not ok then
    timer:close()
    return nil, ("start %s: %s"):format(cfg.binary or "claude", tostring(res))
  end
  proc = res

  -- SIGTERM to the whole group, SIGKILL after a grace period
  local function kill()
    if proc and not proc:is_closing() then
      local pid = proc.pid
      pcall(vim.uv.kill, -pid, 15)
      vim.defer_fn(function()
        pcall(vim.uv.kill, -pid, 9)
      end, M.CANCEL_GRACE_MS)
    end
  end

  timer:start(M.WATCH_EVERY_MS, M.WATCH_EVERY_MS, function()
    local quiet = vim.uv.now() - last_activity
    vim.schedule(function()
      if finished then
        return
      end
      if quiet >= M.IDLE_TIMEOUT_MS then
        kill()
      elseif quiet >= M.STALL_AFTER_MS then
        stalled = true
        emit({ kind = "stalled", text = ("no output for %ds"):format(math.floor(quiet / 1000)) })
      end
    end)
  end)

  return {
    cancel = function()
      if finished then
        return
      end
      canceled = true
      kill()
    end,
  }
end

return M
