-- Inline layout: one window, added lines highlighted, removed lines as ghost rows.
local api = vim.api
local annotate = require("annodiff.annotate")
local config = require("annodiff.config")

local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

local function sh(dir, cmd)
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. "\n" .. (res.stderr or ""))
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

--- Choose picker items by label pattern instead of a real UI.
local picked_labels
local function pick(pattern)
  vim.ui.select = function(items, opts, cb)
    picked_labels = vim.tbl_map(function(it)
      return opts.format_item(it)
    end, items)
    for _, it in ipairs(items) do
      if opts.format_item(it):find(pattern, 1, true) then
        return cb(it)
      end
    end
    cb(nil)
  end
end

--- Virtual rows at a row: { above = {...}, below = {...} } as plain text, trailing spaces trimmed.
local function rows_at(buf, row)
  local out = { above = {}, below = {} }
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, annotate.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, line in ipairs(m[4].virt_lines or {}) do
      local parts = {}
      for _, chunk in ipairs(line) do
        table.insert(parts, chunk[1])
      end
      table.insert(m[4].virt_lines_above and out.above or out.below, (table.concat(parts):gsub("%s+$", "")))
    end
  end
  return out
end

local function line_hl(buf, row)
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, annotate.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].line_hl_group then
      return m[4].line_hl_group
    end
  end
end

vim.g.maplocalleader = "\\"

describe("inline layout", function()
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  vim.fn.writefile({ "top", "a", "b", "c", "d", "e", "end1", "end2" }, repo .. "/m.txt")
  vim.fn.writefile({ "one", "two" }, repo .. "/gone.txt")
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "init" })
  -- top removed; b changed to B; x inserted after c; e removed; end2 removed
  vim.fn.writefile({ "a", "B", "c", "x", "d", "end1" }, repo .. "/m.txt")
  sh(repo, { "git", "rm", "-q", "gone.txt" })
  vim.fn.writefile({ "brand new" }, repo .. "/new.txt")
  sh(repo, { "git", "add", "new.txt" })
  vim.cmd.cd(repo)
  quiet(function()
    vim.cmd("Annodiff --inline HEAD")
  end)
  local s = require("annodiff.view").current()
  local function open(path)
    for i, e in ipairs(s.files) do
      if e.path == path then
        quiet(function()
          require("annodiff.view").open_file(s, i, { focus = "new" })
        end)
      end
    end
  end

  it("one diff window, the real file, no diff mode", function()
    eq(2, #api.nvim_tabpage_list_wins(s.tab))
    eq(nil, s.win_old)
    open("m.txt")
    local buf = api.nvim_win_get_buf(s.win_new)
    eq(repo .. "/m.txt", api.nvim_buf_get_name(buf))
    eq(false, vim.wo[s.win_new].diff)
  end)

  it("removed lines are ghost rows above where they were; added lines highlighted", function()
    local buf = s.buf_new
    eq({ "top" }, rows_at(buf, 1).above) -- removed at the top
    eq({ "b" }, rows_at(buf, 2).above) -- b replaced by B
    eq("AnnodiffInlineAdd", line_hl(buf, 2))
    eq("AnnodiffInlineAdd", line_hl(buf, 4)) -- x inserted
    eq(nil, line_hl(buf, 3))
    eq({ "e" }, rows_at(buf, 6).above) -- e removed before end1
    eq({ "end2" }, rows_at(buf, 6).below) -- removed at the end: below the last line
  end)

  it("]c walks the hunks, then moves to the next file", function()
    api.nvim_win_set_cursor(s.win_new, { 1, 0 })
    press("]c")
    eq(2, api.nvim_win_get_cursor(s.win_new)[1])
    press("]c")
    eq(4, api.nvim_win_get_cursor(s.win_new)[1])
    press("]c")
    eq(6, api.nvim_win_get_cursor(s.win_new)[1])
    press("[c[c")
    eq(2, api.nvim_win_get_cursor(s.win_new)[1])
  end)

  it("\\a on a plain added line annotates it directly", function()
    api.nvim_win_set_cursor(s.win_new, { 4, 0 })
    press("\\anew x<C-s>")
    eq("new x", s.store:find("m.txt", 4, "+").text)
  end)

  it("\\a on a line with ghost rows offers the removed lines", function()
    pick("removed 3")
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\awas lowercase<C-s>")
    eq({ "this line 2 (+): B", "removed 3: b" }, picked_labels)
    local a = s.store:find("m.txt", 3, "-")
    eq("was lowercase", a.text)
    eq("b", a.anchor)
    -- the note sits right under its ghost row
    eq({ "b", "  ▍ was lowercase" }, rows_at(s.buf_new, 2).above)
  end)

  it("\\d on that line picks among the notes there", function()
    pick("(-)")
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\d")
    eq(nil, s.store:find("m.txt", 3, "-"))
    eq({ "b" }, rows_at(s.buf_new, 2).above)
  end)

  it("removed block at the end: picker covers it; export uses old numbers", function()
    pick("removed 8")
    api.nvim_win_set_cursor(s.win_new, { 6, 0 })
    press("\\agone at end<C-s>")
    eq(true, vim.tbl_contains(picked_labels, "removed 6: e"))
    eq("gone at end", s.store:find("m.txt", 8, "-").text)
    eq({ "end2", "  ▍ gone at end" }, rows_at(s.buf_new, 6).below)
  end)

  it("edits in the real file move the ghost rows", function()
    api.nvim_buf_set_lines(s.buf_new, 0, 0, false, { "inserted" })
    api.nvim_exec_autocmds("TextChanged", { buffer = s.buf_new })
    vim.wait(50, function()
      return false
    end)
    eq({ "b" }, rows_at(s.buf_new, 3).above)
    api.nvim_buf_set_lines(s.buf_new, 0, 1, false, {})
    api.nvim_exec_autocmds("TextChanged", { buffer = s.buf_new })
    vim.wait(50, function()
      return false
    end)
    vim.cmd("silent write")
  end)

  it("a deleted file shows its old content, all removed; \\a annotates old lines", function()
    open("gone.txt")
    eq({ "one", "two" }, api.nvim_buf_get_lines(api.nvim_win_get_buf(s.win_new), 0, -1, false))
    eq("AnnodiffInlineDelete", line_hl(s.buf_old, 1))
    eq("AnnodiffInlineDelete", line_hl(s.buf_old, 2))
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\adropped two<C-s>")
    eq("dropped two", s.store:find("gone.txt", 2, "-").text)
  end)

  it("an added file is all highlighted, no ghosts", function()
    open("new.txt")
    eq("AnnodiffInlineAdd", line_hl(s.buf_new, 1))
    eq({ above = {}, below = {} }, rows_at(s.buf_new, 1))
  end)

  it("\\n lands on the row a removed line's note sits above", function()
    open("m.txt")
    api.nvim_win_set_cursor(s.win_new, { 5, 0 })
    press("\\n")
    eq(6, api.nvim_win_get_cursor(0)[1]) -- m.txt:8 (-), drawn at the end
  end)

  it("\\i switches to split and back, keeping notes", function()
    press("\\i")
    eq("split", s.layout)
    eq(3, #api.nvim_tabpage_list_wins(s.tab))
    eq(true, vim.wo[s.win_old].diff)
    eq(true, vim.wo[s.win_new].diff)
    eq("gone at end", s.store:find("m.txt", 8, "-").text)
    quiet(function()
      vim.cmd("AnnodiffLayout inline")
    end)
    eq("inline", s.layout)
    eq(2, #api.nvim_tabpage_list_wins(s.tab))
    eq(require("annodiff.view").current(), s, "session survives the switch")
  end)

  it("\\c on a ghost line asks about the removed line", function()
    config.options.agent = { binary = vim.fs.joinpath(root, "tests", "fixtures", "fake-claude.sh") }
    vim.env.FAKE_CLAUDE_MODE = "ok"
    vim.env.FAKE_CLAUDE_RECORD = repo .. "/rec"
    pick("removed 6")
    api.nvim_set_current_win(s.win_new)
    api.nvim_win_set_cursor(s.win_new, { 6, 0 })
    press("\\cwhy remove e?<C-s>")
    local t = s.threads:get("m.txt", 6, "-")
    truthy(t, "thread on the removed line")
    vim.wait(5000, function()
      return t.status == "idle"
    end, 20)
    vim.wait(80, function()
      return false
    end)
    eq({ "e", "  ⟢ Q: why remove e?", "    hello" }, rows_at(s.buf_new, 6).above)
    local f = io.open(repo .. "/rec.stdin")
    local stdin = f:read("*a")
    f:close()
    truthy(stdin:find("Asking about: line 6 (removed line)", 1, true), stdin)
    truthy(stdin:find(">-e\n", 1, true), stdin)
    config.options.agent = vim.deepcopy(config.defaults.agent)
  end)

  it("closing restores nothing odd: one tab fewer, no leftover hidden buffers", function()
    local hidden = vim.deepcopy(s.hidden_bufs)
    quiet(function()
      vim.cmd("AnnodiffClose")
    end)
    for _, b in ipairs(hidden) do
      eq(false, api.nvim_buf_is_valid(b), "hidden buffer " .. b .. " still around")
    end
    eq(nil, require("annodiff.view").current())
  end)
end)
