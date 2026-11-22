-- Review state on disk, re-anchoring, reviewed marks, filters, history.
local api = vim.api
local annotations = require("annodiff.annotations")
local persist = require("annodiff.persist")
local annotate = require("annodiff.annotate")

local function sh(dir, cmd)
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. "\n" .. (res.stderr or ""))
  return res.stdout
end

local function write(dir, path, lines)
  local full = vim.fs.joinpath(dir, path)
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  vim.fn.writefile(lines, full)
end

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
  vim.wait(20, function()
    return false
  end)
end

local function quiet(fn)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    table.insert(msgs, m)
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  assert(ok, err)
  return msgs
end

local function tree_lines(s)
  return api.nvim_buf_get_lines(s.buf_tree, 0, -1, false)
end

local function current()
  return require("annodiff.view").current()
end

vim.g.maplocalleader = "\\"

describe("persist encode / decode", function()
  it("round-trips records and reviewed paths", function()
    local s = annotations.new()
    s:add({ file = "a.lua", line = 3, end_line = 4, type = "+", text = "x", anchor = "local x = 1" })
    s:add({ file = "a.lua", line = 0, type = "", text = "file" })
    local state = assert(persist.decode(persist.encode(s, { ["a.lua"] = true }, "HEAD → worktree")))
    eq({ ["a.lua"] = true }, state.reviewed)
    eq({ file = "a.lua", line = 3, end_line = 4, type = "+", text = "x", anchor = "local x = 1" }, state.annotations[2])
    eq({ file = "a.lua", line = 0, type = "", text = "file" }, state.annotations[1])
  end)

  it("rejects other versions and garbage", function()
    eq(nil, (persist.decode('{"version": 99}')))
    eq(nil, (persist.decode("not json")))
  end)

  it("keys are file-name safe", function()
    eq("HEAD_worktree", persist.key({ label = "HEAD → worktree" }))
    eq("origin_main...feat_x", persist.key({ label = "origin/main...feat/x" }))
  end)
end)

describe("review state across sessions", function()
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  write(repo, "app.lua", { "local a = 1", "local b = 2", "return a + b" })
  write(repo, "lib.lua", { "return 1" })
  write(repo, "util.lua", { "return 2" })
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "init" })
  write(repo, "app.lua", { "local a = 1", "local b = 20", "return a + b" })
  write(repo, "lib.lua", { "return 10" })
  write(repo, "util.lua", { "return 20" })
  vim.cmd.cd(repo)
  local state_file = repo .. "/.git/annodiff/reviews/HEAD_worktree.json"

  it("annotations and reviewed marks are saved as they change", function()
    quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    local s = current()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\abump b<C-s>")
    eq(1, vim.fn.filereadable(state_file))
    local state = assert(persist.load(state_file))
    eq("local b = 20", state.annotations[1].anchor)
    api.nvim_set_current_win(s.win_tree)
    api.nvim_win_set_cursor(s.win_tree, { 4, 0 }) -- lib.lua
    press(" ")
    eq("  M lib.lua ✓", tree_lines(s)[4]:gsub("^%s*", "  "))
    eq("3 files · 1 reviewed", tree_lines(s)[2])
    eq({ ["lib.lua"] = true }, assert(persist.load(state_file)).reviewed)
    quiet(function()
      press("q")
    end)
  end)

  it("reopening restores them", function()
    local msgs = quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    eq(true, vim.tbl_contains(msgs, "annodiff: restored 1 annotation(s)"))
    local s = current()
    eq("bump b", s.store:find("app.lua", 2, "+").text)
    eq(true, s.reviewed["lib.lua"])
    eq("M lib.lua ✓", vim.trim(tree_lines(s)[4]))
    quiet(function()
      vim.cmd("AnnodiffClose")
    end)
  end)

  it("re-anchors when the code moved", function()
    write(repo, "app.lua", { "-- one", "-- two", "local a = 1", "local b = 20", "return a + b" })
    quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    local s = current()
    local a = s.store:find("app.lua", 4, "+")
    truthy(a, "moved from line 2 to line 4")
    eq(nil, a.orphan)
    local marks = api.nvim_buf_get_extmarks(api.nvim_win_get_buf(s.win_new), annotate.ns, 0, -1, { details = true })
    local rows = {}
    for _, m in ipairs(marks) do
      if m[4].sign_text then
        table.insert(rows, m[2])
      end
    end
    eq({ 3 }, rows)
    quiet(function()
      vim.cmd("AnnodiffClose")
    end)
  end)

  it("orphans an annotation whose line is gone, and keeps it", function()
    write(repo, "app.lua", { "local a = 1", "local b = 30", "return a + b" })
    quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    local s = current()
    local a = s.store:get("app.lua")[1]
    eq("bump b", a.text)
    eq(true, a.orphan)
    local found = false
    for _, m in ipairs(api.nvim_buf_get_extmarks(api.nvim_win_get_buf(s.win_new), annotate.ns, 0, -1, { details = true })) do
      for _, line in ipairs(m[4].virt_lines or {}) do
        if line[2] and line[2][1] == "orphaned, was here: " then
          found = true
        end
      end
    end
    eq(true, found)
    quiet(function()
      vim.cmd("AnnodiffClose")
    end)
  end)

  it("f shows only annotated files and <Tab> skips the rest", function()
    quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    local s = current()
    local orphan = s.store:get("app.lua")[1]
    eq({ true, "local b = 20", 4 }, { orphan.orphan, orphan.anchor, orphan.line }, "orphan unchanged after a reopen")
    api.nvim_set_current_win(s.win_tree)
    press("f")
    eq({ "HEAD → worktree", "3 files · 1 reviewed · only annotated", "M app.lua [1]" }, vim.tbl_map(vim.trim, tree_lines(s)))
    press("<Tab>")
    eq("app.lua", s.files[s.current].path, "nothing visible after app.lua")
    press("f")
    eq(5, #tree_lines(s))
  end)

  it("F shows only unreviewed files", function()
    local s = current()
    api.nvim_set_current_win(s.win_tree)
    press("F")
    local lines = vim.tbl_map(vim.trim, tree_lines(s))
    eq(false, vim.tbl_contains(lines, "M lib.lua ✓"))
    eq(true, vim.tbl_contains(lines, "M util.lua"))
    press("<Tab>")
    eq("util.lua", s.files[s.current].path, "lib.lua skipped")
    press("F")
  end)

  it("\\r marks the open file reviewed from a diff window", function()
    local s = current()
    api.nvim_set_current_win(s.win_new)
    press("\\r")
    eq(true, s.reviewed["util.lua"])
    press("\\r")
    eq(nil, s.reviewed["util.lua"])
  end)

  it("closing writes a revdiff history entry the revdiff skill can find", function()
    local msgs = quiet(function()
      vim.cmd("AnnodiffClose")
    end)
    local dir = persist.history_dir(repo)
    local path = msgs[1]:match("history (.+%.md)$")
    truthy(path, msgs[1])
    eq(dir, vim.fs.dirname(path))
    local text = table.concat(vim.fn.readfile(path), "\n")
    truthy(text:match("^# Review: %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d\npath: " .. vim.pesc(repo) .. "\nrefs: HEAD\ncommit: %x+\n\n## Annotations\n\n## app%.lua:4 %(%+%)\nbump b\n\n%-%-%-\n\n## Diff\n\ndiff %-%-git a/app%.lua b/app%.lua"), text)
    eq(nil, text:find("lib.lua", 1, true), "only annotated files in the diff")
  end)

  it(":AnnodiffClear! drops everything, on disk too", function()
    quiet(function()
      vim.cmd("Annodiff HEAD")
      vim.cmd("AnnodiffClear!")
    end)
    local s = current()
    eq(0, s.store:count())
    eq({}, s.reviewed)
    local state = assert(persist.load(state_file))
    eq(0, #state.annotations)
    quiet(function()
      vim.cmd("AnnodiffClose")
    end)
  end)

  it("an unreadable state file is left alone", function()
    vim.fn.writefile({ "{broken" }, state_file)
    local msgs = quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    truthy(msgs[1]:find("unreadable review state", 1, true), msgs[1])
    local s = current()
    api.nvim_win_set_cursor(s.win_new, { 1, 0 })
    press("\\anew note<C-s>")
    eq({ "{broken" }, vim.fn.readfile(state_file))
    quiet(function()
      vim.cmd("AnnodiffClose")
    end)
  end)
end)
