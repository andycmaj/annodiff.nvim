-- Agent pieces: stream parser (revdiff's recorded fixtures), claude args, thread store.
local stream = require("annodiff.agent.stream")
local claude = require("annodiff.agent.claude")
local threads = require("annodiff.threads")

local fixtures = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))), "tests", "fixtures")

local function parse(name, work_dir)
  local p = stream.new(work_dir)
  local events = {}
  for _, line in ipairs(vim.fn.readfile(vim.fs.joinpath(fixtures, name))) do
    vim.list_extend(events, p:line(line))
  end
  return events
end

local function split(events)
  local text, tools, last = {}, {}, nil
  for _, ev in ipairs(events) do
    if ev.kind == "text" then
      table.insert(text, ev.text)
    elseif ev.kind == "tool" then
      table.insert(tools, ev.text)
    else
      last = ev
    end
  end
  return table.concat(text), tools, last
end

describe("stream parser (revdiff fixtures)", function()
  it("real answer with a tool call between two messages", function()
    local text, tools, last = split(parse("real-tool-answer.jsonl", "/work/repo"))
    eq("ok\n\nFile contains: `hello` on line 1, blank line 2.", text)
    eq({ "read x.txt" }, tools)
    eq("done", last.kind)
    eq("File contains: `hello` on line 1, blank line 2.", last.text)
    eq("8dcdd477-c11e-4d71-95a7-7001128bf160", last.session_id)
  end)

  it("error result joins the errors", function()
    local _, _, last = split(parse("error-result.jsonl"))
    eq({ kind = "failed", text = "Invalid API key; run /login" }, last)
  end)

  it("skips subagent output, garbage and thinking", function()
    local text, tools, last = split(parse("subagent-and-garbage.jsonl"))
    eq("top", text)
    eq({ "$ git log -1" }, tools)
    eq(nil, last)
  end)

  it("ignores a side-turn result from a forked session", function()
    local text, _, last = split(parse("task-notification-first.jsonl"))
    eq("Strength counts corrections.", text)
    eq("done", last.kind)
    eq("Strength counts corrections.", last.text)
  end)

  it("feed buffers partial lines", function()
    local p = stream.new()
    local line = '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}\n'
    eq({}, p:feed(line:sub(1, 20)))
    eq({ { kind = "text", text = "hi" } }, p:feed(line:sub(21)))
  end)
end)

describe("claude args", function()
  local function has_seq(args, seq)
    for i = 1, #args - #seq + 1 do
      if vim.deep_equal(vim.list_slice(args, i, i + #seq - 1), seq) then
        return true
      end
    end
    return false
  end

  it("is hermetic and read-only", function()
    local args = claude.args({}, { prompt = "q", session_id = "u1" })
    eq("claude", args[1])
    truthy(has_seq(args, { "--permission-mode", "dontAsk" }))
    truthy(has_seq(args, { "--setting-sources", "user" }))
    truthy(vim.tbl_contains(args, "--strict-mcp-config"))
    local allowed = args[vim.fn.index(args, "--allowedTools") + 2]
    truthy(allowed:find("Bash(git diff:*)", 1, true))
    eq(nil, allowed:find("Edit", 1, true))
    local denied = args[vim.fn.index(args, "--disallowedTools") + 2]
    truthy(denied:find("Edit,Write", 1, true))
    eq(false, vim.tbl_contains(args, "q"), "prompt goes on stdin, not argv")
  end)

  it("fresh, fork, resume", function()
    truthy(has_seq(claude.args({}, { session_id = "u1" }), { "--session-id", "u1" }))
    truthy(has_seq(claude.args({}, { session_id = "u1", parent_session = "p" }), {
      "--resume",
      "p",
      "--fork-session",
      "--session-id",
      "u1",
    }))
    local resume = claude.args({}, { session_id = "u1", resume = true, parent_session = "p" })
    truthy(has_seq(resume, { "--resume", "u1" }))
    eq(false, vim.tbl_contains(resume, "--fork-session"))
  end)

  it("model and extra args come last", function()
    local args = claude.args({ binary = "/x/claude", model = "haiku", args = { "--foo" } }, { session_id = "u" })
    eq("/x/claude", args[1])
    eq({ "--model", "haiku", "--foo" }, vim.list_slice(args, #args - 2))
  end)

  it("parent session from env, tagged by host", function()
    vim.env.ANNODIFF_AGENT_PARENT_SESSION = "claude:abc"
    eq("abc", claude.parent_session())
    vim.env.ANNODIFF_AGENT_PARENT_SESSION = "codex:abc"
    eq(nil, claude.parent_session())
    vim.env.ANNODIFF_AGENT_PARENT_SESSION = nil
    vim.env.REVDIFF_AGENT_PARENT_SESSION = "plain-id"
    eq("plain-id", claude.parent_session())
    vim.env.REVDIFF_AGENT_PARENT_SESSION = nil
    eq(nil, claude.parent_session())
  end)

  it("uuid is v4-shaped and unique", function()
    local a, b = claude.uuid(), claude.uuid()
    truthy(a:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x+$"), a)
    truthy(a ~= b)
  end)
end)

describe("threads", function()
  it("formats history like revdiff", function()
    local t = threads.new()
    local a = t:ask({ file = "b.go", line = 0, type = "" }, "what is this file?")
    t:apply(a.id, { kind = "text", text = "a parser" })
    t:apply(a.id, { kind = "done", text = "a parser", session_id = "s1" })
    local b = t:ask({ file = "a.go", line = 3, end_line = 5, type = "+" }, "why?")
    t:apply(b.id, { kind = "failed", text = "not logged in" })
    eq(
      "### a.go:3-5 (+)\n\n**Q:** why?\n\n**Error:** not logged in\n\n### b.go (file-level)\n\n**Q:** what is this file?\n\n**A:** a parser\n\n",
      t:format_history()
    )
    eq("s1", a.session_id)
  end)

  it("one thread per anchor; retry resets the last turn", function()
    local t = threads.new()
    local a = t:ask({ file = "f", line = 1, type = "+" }, "q1")
    t:apply(a.id, { kind = "failed", text = "x" })
    eq(nil, t:retry(999))
    local r = t:retry(a.id)
    eq("streaming", r.status)
    local same = t:ask({ file = "f", line = 1, type = "+" }, "q2")
    eq(a.id, same.id)
    eq(2, #same.turns)
    eq(1, t:streaming())
  end)
end)
