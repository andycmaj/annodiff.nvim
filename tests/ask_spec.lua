-- End-to-end ask-agent with revdiff's fake `claude` (tests/fixtures/fake-claude.sh).
local api = vim.api
local config = require("annodiff.config")
local annotate = require("annodiff.annotate")

local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
local fake = vim.fs.joinpath(root, "tests", "fixtures", "fake-claude.sh")

local function sh(dir, cmd)
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. "\n" .. (res.stderr or ""))
  return res.stdout
end

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
  vim.wait(20, function()
    return false
  end)
end

local function quiet(fn)
  local orig = vim.notify
  vim.notify = function() end
  local ok, err = pcall(fn)
  vim.notify = orig
  assert(ok, err)
end

local function wait_status(t, status)
  vim.wait(5000, function()
    return t.status == status
  end, 20)
  vim.wait(80, function()
    return false
  end) -- let the throttled redraw run
  eq(status, t.status, "thread status")
end

local function preview_text(s)
  local out = {}
  for _, win in ipairs({ s.win_old, s.win_new }) do
    for _, m in ipairs(api.nvim_buf_get_extmarks(api.nvim_win_get_buf(win), annotate.ns, 0, -1, { details = true })) do
      for _, line in ipairs(m[4].virt_lines or {}) do
        local parts = {}
        for _, chunk in ipairs(line) do
          table.insert(parts, chunk[1])
        end
        local text = table.concat(parts)
        if vim.trim(text) ~= "" then
          table.insert(out, text)
        end
      end
    end
  end
  return out
end

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local t = f:read("*a")
  f:close()
  return t
end

vim.g.maplocalleader = "\\"

describe("ask the agent", function()
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b" }, repo .. "/f.lua")
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "init" })
  vim.fn.writefile({ "local a = 1", "local b = 20", "return a + b" }, repo .. "/f.lua")
  vim.cmd.cd(repo)
  local record = repo .. "/rec"
  vim.env.FAKE_CLAUDE_RECORD = record
  vim.env.FAKE_CLAUDE_MODE = "ok"
  vim.env.ANNODIFF_AGENT_PARENT_SESSION = "claude:parent-123"
  config.options.agent = { binary = fake }
  quiet(function()
    vim.cmd("Annodiff HEAD")
  end)
  local s = require("annodiff.view").current()

  it("\\c asks about the line; the answer streams in under it", function()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\cwhy 20?<C-s>")
    local t = s.threads:get("f.lua", 2, "+")
    truthy(t, "thread created")
    wait_status(t, "idle")
    eq("hello", t.turns[1].answer)
    eq("sess-ok", t.session_id)
    eq({ "  ⟢ Q: why 20?", "    hello" }, preview_text(s))
  end)

  it("the agent got a hermetic fork of the parent session, prompt on stdin, repo as cwd", function()
    local args = vim.split(vim.trim(read(record .. ".args")), "\n")
    local i = vim.fn.index(args, "--fork-session")
    truthy(i > 0, "forked")
    eq({ "--resume", "parent-123", "--fork-session", "--session-id" }, vim.list_slice(args, i - 1, i + 2))
    local stdin = read(record .. ".stdin")
    truthy(stdin:find("Review: git diff of the working tree against HEAD", 1, true), stdin)
    truthy(stdin:find("Asking about: line 2 (added line)", 1, true), stdin)
    truthy(stdin:find("  local a = 1\n -local b = 2\n>+local b = 20\n  return a + b", 1, true), stdin)
    truthy(stdin:find("Question: why 20?", 1, true))
    eq(repo, vim.trim(read(record .. ".pwd")))
  end)

  it("windows stay aligned with a preview drawn", function()
    vim.cmd("redraw")
    eq(vim.fn.screenpos(s.win_old, 3, 1).row, vim.fn.screenpos(s.win_new, 3, 1).row)
  end)

  it("\\c on the same line opens the thread; c follows up by resuming the session", function()
    api.nvim_set_current_win(s.win_new)
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\c")
    truthy(s.overlay, "thread window open")
    local text = table.concat(api.nvim_buf_get_lines(s.overlay.buf, 0, -1, false), "\n")
    eq("# f.lua:2 (+)\n\n**Q:** why 20?\n\n**A:** hello\n", text)
    press("cand then?<C-s>") -- one feed: separate "x" feeds end insert mode
    local t = s.threads:get("f.lua", 2, "+")
    wait_status(t, "idle")
    eq(2, #t.turns)
    local args = vim.split(vim.trim(read(record .. ".args")), "\n")
    local i = vim.fn.index(args, "--resume")
    eq("sess-ok", args[i + 2])
    eq(-1, vim.fn.index(args, "--fork-session"))
    eq("Follow-up question about f.lua line 2:\n\nand then?\n", read(record .. ".stdin"))
  end)

  it("y promotes the answer to an annotation", function()
    api.nvim_set_current_win(s.win_new)
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\c")
    press("y")
    eq("hello", api.nvim_get_current_line())
    press("<C-s>")
    local a = s.store:find("f.lua", 2, "+")
    eq("hello", a.text)
    eq("local b = 20", a.anchor)
    -- the annotation's rows come before the thread's on the same line, in one mark
    local rows = preview_text(s)
    eq("  ▍ hello", rows[1])
    eq("  ⟢ Q: and then?", rows[2])
  end)

  it("a failing agent shows its stderr; c in the thread retries", function()
    vim.env.FAKE_CLAUDE_MODE = "stderr"
    api.nvim_set_current_win(s.win_new)
    api.nvim_win_set_cursor(s.win_new, { 3, 0 })
    press("\\cexplain<C-s>")
    local t = s.threads:get("f.lua", 3, " ")
    wait_status(t, "failed")
    eq("Error: not logged in", t.err)
    truthy(vim.tbl_contains(preview_text(s), "    ✗ Error: not logged in"))
    vim.env.FAKE_CLAUDE_MODE = "ok"
    press("\\c")
    press("c")
    wait_status(t, "idle")
    eq("hello", t.turns[1].answer)
    eq(1, #t.turns)
  end)

  it("x cancels a hung agent and kills its whole process group", function()
    vim.env.FAKE_CLAUDE_MODE = "hang"
    api.nvim_set_current_win(s.win_new)
    press("\\Cfile question<C-s>")
    local t = s.threads:get("f.lua", 0, "")
    vim.wait(3000, function()
      return read(record .. ".child") ~= nil and t.turns[1].answer == "thinking"
    end, 20)
    eq("thinking", t.turns[1].answer)
    local child = tonumber(vim.trim(read(record .. ".child")))
    press("\\C")
    press("x")
    wait_status(t, "failed")
    eq("canceled", t.err)
    vim.wait(3000, function()
      return vim.uv.kill(child, 0) ~= 0
    end, 50)
    eq(false, pcall(function()
      assert(vim.uv.kill(child, 0) == 0)
    end), "child of the agent still alive")
    vim.env.FAKE_CLAUDE_MODE = "ok"
  end)

  it("d deletes a thread", function()
    local t = s.threads:get("f.lua", 0, "")
    api.nvim_set_current_win(s.win_new)
    press("\\C")
    press("d")
    eq(nil, s.threads:by(t.id))
  end)

  it("closing records the Q&A in history (not in the export)", function()
    local hist = vim.fn.tempname()
    config.options.history_dir = hist
    quiet(function()
      vim.cmd("AnnodiffClose")
    end)
    local files = vim.fn.glob(hist .. "/*/*.md", false, true)
    eq(1, #files)
    local text = read(files[1])
    truthy(text:find("\n## Annotations\n\n## f.lua:2 (+)\nhello\n\n## Agent Q&A\n\n### f.lua:2 (+)\n\n**Q:** why 20?\n\n**A:** hello\n\n**Q:** and then?\n\n**A:** hello\n\n### f.lua:3 ( )\n\n**Q:** explain\n\n**A:** hello\n\n", 1, true), text)
    eq(nil, read(repo .. "/.git/annodiff/annotations.md"):find("Agent", 1, true))
    config.options.history_dir = nil
    config.options.agent = vim.deepcopy(config.defaults.agent)
    vim.env.ANNODIFF_AGENT_PARENT_SESSION = nil
  end)
end)
