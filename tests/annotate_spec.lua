-- End-to-end annotations: real repo, real keys, extmarks, export.
local api = vim.api
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

-- annotation marks only (padding marks have no sign)
local function marks(buf)
  return vim.tbl_filter(function(m)
    return m[4].sign_text ~= nil
  end, api.nvim_buf_get_extmarks(buf, annotate.ns, 0, -1, { details = true }))
end

--- Every context line sits on the same screen row as its counterpart.
local function assert_aligned(s)
  vim.cmd("redraw")
  local hunks = require("annodiff.hunks")
  local old = api.nvim_buf_get_lines(api.nvim_win_get_buf(s.win_old), 0, -1, false)
  local new = api.nvim_buf_get_lines(api.nvim_win_get_buf(s.win_new), 0, -1, false)
  local h = hunks.compute(old, new)
  for l = 1, #old do
    local type, nl = hunks.classify(h, "old", l)
    if type == " " then
      local ro = vim.fn.screenpos(s.win_old, l, 1).row
      local rn = vim.fn.screenpos(s.win_new, nl, 1).row
      eq(ro, rn, ("old line %d / new line %d on different rows"):format(l, nl))
    end
  end
end

local function virt_text(mark)
  local out = {}
  for _, line in ipairs(mark[4].virt_lines or {}) do
    local parts = {}
    for _, chunk in ipairs(line) do
      table.insert(parts, chunk[1])
    end
    table.insert(out, table.concat(parts))
  end
  return out
end

--- Text rows drawn at a row (above or below it), from every mark there.
local function text_at(buf, row, above)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, annotate.ns, { row, 0 }, { row, -1 }, { details = true })) do
    if m[4].virt_lines and (m[4].virt_lines_above or false) == above then
      vim.list_extend(out, virt_text(m))
    end
  end
  return out
end

local function records(s)
  local out = {}
  for _, file in ipairs(s.store:files()) do
    for _, a in ipairs(s.store:get(file)) do
      table.insert(out, { a.file, a.line, a.end_line or false, a.type, a.text })
    end
  end
  return out
end

vim.g.maplocalleader = "\\"

describe("annotations in a review", function()
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  write(repo, "app.lua", { "local a = 1", "local b = 2", "local c = 3", "return a + b + c" })
  write(repo, "lib.lua", { "return {}" })
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "init" })
  write(repo, "app.lua", { "local a = 1", "local b = 20", "local c = 3", "local d = 4", "local e = 5", "return a + b + c" })
  write(repo, "lib.lua", { "return { x = 1 }" })
  vim.cmd.cd(repo)
  vim.cmd("Annodiff HEAD")
  local s = require("annodiff.view").current()

  it("\\a on a changed line in the new window records a '+' annotation", function()
    eq("app.lua", s.files[s.current].path)
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\abump b<C-s>")
    eq({ { "app.lua", 2, false, "+", "bump b" } }, records(s))
    local m = marks(api.nvim_win_get_buf(s.win_new))
    eq(1, #m)
    eq(1, m[1][2]) -- row 1 = line 2
    eq({ "  ▍ bump b" }, text_at(api.nvim_win_get_buf(s.win_new), 1, false))
  end)

  it("tree shows the count", function()
    eq(true, vim.tbl_contains(api.nvim_buf_get_lines(s.buf_tree, 0, -1, false), "M app.lua [1]"))
  end)

  it("old window: changed line is '-', context line maps to new numbering", function()
    api.nvim_set_current_win(s.win_old)
    api.nvim_win_set_cursor(s.win_old, { 2, 0 })
    press("\\awas 2<C-s>")
    api.nvim_win_set_cursor(s.win_old, { 4, 0 }) -- "return ..." is new line 6
    press("\\acontext<C-s>")
    eq({
      { "app.lua", 2, false, "+", "bump b" },
      { "app.lua", 2, false, "-", "was 2" },
      { "app.lua", 6, false, " ", "context" },
    }, records(s))
    eq(1, #marks(api.nvim_win_get_buf(s.win_old)), "'-' drawn on the old side")
    eq(2, #marks(api.nvim_win_get_buf(s.win_new)), "'+' and context drawn on the new side")
  end)

  it("visual range sets end_line; 'hunk' widens to the changed block", function()
    api.nvim_set_current_win(s.win_new)
    api.nvim_win_set_cursor(s.win_new, { 1, 0 })
    press("Vj\\arange note<C-s>")
    eq({ "app.lua", 1, 2, " ", "range note" }, records(s)[1])
    api.nvim_win_set_cursor(s.win_new, { 4, 0 })
    press("\\athis hunk is new<C-s>")
    local a = s.store:find("app.lua", 4, "+")
    eq(5, a.end_line)
  end)

  it("\\a on an annotated line edits it; saving empty deletes it", function()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\a")
    eq("bump b", api.nvim_get_current_line())
    press("ccbump b to 20<C-s>")
    eq("bump b to 20", s.store:find("app.lua", 2, "+").text)
    press("\\a")
    press("dd<C-s>")
    eq(nil, s.store:find("app.lua", 2, "+"))
  end)

  it("file-level annotation shows above line 1", function()
    press("\\Awhole file note<C-s>")
    local a = s.store:find("app.lua", 0, "")
    eq("whole file note", a.text)
    eq({ "  ▍ file: whole file note" }, text_at(api.nvim_win_get_buf(s.win_new), 0, true))
  end)

  it("both windows stay row-aligned with annotations drawn", function()
    api.nvim_win_set_cursor(s.win_new, { 1, 0 })
    assert_aligned(s)
  end)

  it("edits in the real buffer move annotations with their lines", function()
    local buf = api.nvim_win_get_buf(s.win_new)
    api.nvim_buf_set_lines(buf, 0, 0, false, { "-- header" })
    annotate.sync(s)
    eq(5, s.store:find("app.lua", 5, "+") and 5 or nil, "hunk annotation moved 4 -> 5")
    eq(6, s.store:find("app.lua", 5, "+").end_line)
    eq(7, s.store:find("app.lua", 7, " ") and 7 or nil, "context moved 6 -> 7")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.wait(50, function() return false end)
    assert_aligned(s)
    api.nvim_buf_set_lines(buf, 0, 1, false, {})
    annotate.sync(s)
    vim.cmd("silent write")
  end)

  it("\\n / \\N walk annotations across files", function()
    api.nvim_set_current_win(s.win_new)
    api.nvim_win_set_cursor(s.win_new, { 1, 0 })
    press("\\n")
    eq({ s.win_old, 2 }, { api.nvim_get_current_win(), api.nvim_win_get_cursor(0)[1] }, "'-' note on the old side")
    press("\\n")
    eq({ s.win_new, 4 }, { api.nvim_get_current_win(), api.nvim_win_get_cursor(0)[1] })
    -- add one in lib.lua, then come back
    press("<Tab>")
    api.nvim_set_current_win(s.win_new)
    eq("lib.lua", s.files[s.current].path)
    api.nvim_win_set_cursor(s.win_new, { 1, 0 })
    press("\\alib note<C-s>")
    press("\\N")
    eq("app.lua", s.files[s.current].path)
    eq(6, api.nvim_win_get_cursor(0)[1], "last annotation in app.lua (context, new line 6)")
    press("\\n")
    eq("lib.lua", s.files[s.current].path)
  end)

  it("annotations on the real buffer are cleared when the review moves on", function()
    local lib = api.nvim_win_get_buf(s.win_new)
    eq(1, #marks(lib))
    press("<S-Tab>")
    eq(0, #marks(lib))
  end)

  it("\\d deletes the annotation under the cursor", function()
    api.nvim_set_current_win(s.win_old)
    api.nvim_win_set_cursor(s.win_old, { 2, 0 })
    press("\\d")
    eq(nil, s.store:find("app.lua", 2, "-"))
  end)

  it(":AnnodiffExport writes revdiff format, mode 0600", function()
    local path = repo .. "/out.md"
    vim.cmd("AnnodiffExport " .. path)
    eq(
      table.concat({
        "## app.lua (file-level)",
        "whole file note",
        "",
        "## app.lua:1-2 ( )",
        "range note",
        "",
        "## app.lua:4-5 (+)",
        "this hunk is new",
        "",
        "## app.lua:6 ( )",
        "context",
        "",
        "## lib.lua:1 (+)",
        "lib note",
        "",
      }, "\n"),
      table.concat(vim.fn.readfile(path, "b"), "\n")
    )
    eq("rw-------", vim.fn.getfperm(path))
  end)

  it("closing the review saves to .git/annodiff/annotations.md", function()
    api.nvim_set_current_win(s.win_tree)
    press("q")
    local saved = repo .. "/.git/annodiff/annotations.md"
    eq(1, vim.fn.filereadable(saved))
    eq(vim.fn.readfile(repo .. "/out.md"), vim.fn.readfile(saved))
  end)
end)
