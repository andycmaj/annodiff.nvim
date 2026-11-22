-- End-to-end: a real git repo, :Annodiff, native diff windows, navigation.
local api = vim.api

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

local function make_repo()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  sh(dir, { "git", "init", "-q", "-b", "main" })
  write(dir, "src/app.lua", { "local a = 1", "local b = 2", "local c = 3", "return a + b + c" })
  write(dir, "src/old_name.lua", { "return 'moved'", "-- same", "-- content", "-- here" })
  write(dir, "gone.txt", { "bye" })
  write(dir, "README.md", { "# demo", "", "text" })
  sh(dir, { "git", "add", "-A" })
  sh(dir, { "git", "commit", "-q", "-m", "init" })
  -- working changes vs HEAD
  write(dir, "src/app.lua", { "local a = 1", "local b = 20", "local c = 3", "return a + b + c", "-- tail" })
  sh(dir, { "git", "mv", "src/old_name.lua", "src/new_name.lua" })
  sh(dir, { "git", "rm", "-q", "gone.txt" })
  write(dir, "docs/new.md", { "fresh" })
  sh(dir, { "git", "add", "docs/new.md" })
  return dir
end

local function tree_lines(s)
  return api.nvim_buf_get_lines(s.buf_tree, 0, -1, false)
end

local function buf_lines(win)
  return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
end

local function path_of(s)
  return s.files[s.current].path
end

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

describe(":Annodiff HEAD", function()
  local repo = make_repo()
  vim.cmd.cd(repo)
  local tabs_before = #api.nvim_list_tabpages()
  vim.cmd("Annodiff HEAD")
  local s = require("annodiff.view").current()

  it("opens a review tab with tree + two diff windows", function()
    truthy(s, "session")
    eq(tabs_before + 1, #api.nvim_list_tabpages())
    eq(3, #api.nvim_tabpage_list_wins(s.tab))
    eq(true, vim.wo[s.win_old].diff)
    eq(true, vim.wo[s.win_new].diff)
    eq(false, vim.wo[s.win_tree].diff)
    eq(35, api.nvim_win_get_width(s.win_tree))
    eq(s.win_new, api.nvim_get_current_win())
  end)

  it("renders the tree", function()
    eq({
      "HEAD → worktree",
      "4 files",
      "▾ docs/",
      "  A new.md",
      "▾ src/",
      "  M app.lua",
      "  R new_name.lua ← src/old_name.lua",
      "D gone.txt",
    }, tree_lines(s))
  end)

  it("first file: added file, empty left side", function()
    eq("docs/new.md", path_of(s))
    eq({ "" }, buf_lines(s.win_old))
    eq({ "fresh" }, buf_lines(s.win_new))
  end)

  it("worktree side is the real, editable file buffer", function()
    local buf = api.nvim_win_get_buf(s.win_new)
    eq(vim.fs.joinpath(repo, "docs/new.md"), api.nvim_buf_get_name(buf))
    eq("", vim.bo[buf].buftype)
    eq(true, vim.bo[buf].modifiable)
    eq("markdown", vim.bo[buf].filetype)
  end)

  it("<Tab> moves to the next file; left side is HEAD content, read-only", function()
    press("<Tab>")
    eq("src/app.lua", path_of(s))
    eq({ "local a = 1", "local b = 2", "local c = 3", "return a + b + c" }, buf_lines(s.win_old))
    local old = api.nvim_win_get_buf(s.win_old)
    eq("nofile", vim.bo[old].buftype)
    eq(false, vim.bo[old].modifiable)
    eq("lua", vim.bo[old].filetype)
    eq(s.win_new, api.nvim_get_current_win())
  end)

  it("lands on the first hunk", function()
    eq(2, api.nvim_win_get_cursor(s.win_new)[1])
  end)

  it("]c walks hunks, then crosses into the next file", function()
    press("]c")
    eq("src/app.lua", path_of(s))
    eq(5, api.nvim_win_get_cursor(s.win_new)[1])
    press("]c")
    eq("src/new_name.lua", path_of(s))
  end)

  it("renames diff against the old path", function()
    eq(buf_lines(s.win_old), buf_lines(s.win_new))
  end)

  it("[c at the first hunk goes back to the previous file's last hunk", function()
    press("[c")
    eq("src/app.lua", path_of(s))
    eq(5, api.nvim_win_get_cursor(s.win_new)[1])
  end)

  it("deleted file: right side empty scratch", function()
    press("<Tab><Tab>")
    eq("gone.txt", path_of(s))
    eq({ "bye" }, buf_lines(s.win_old))
    eq({ "" }, buf_lines(s.win_new))
    eq("nofile", vim.bo[api.nvim_win_get_buf(s.win_new)].buftype)
  end)

  it("<Tab> past the last file stays put", function()
    press("<Tab>")
    eq("gone.txt", path_of(s))
  end)

  it("tree <CR> opens a file and focuses the diff", function()
    api.nvim_set_current_win(s.win_tree)
    api.nvim_win_set_cursor(s.win_tree, { 6, 0 }) -- "  M app.lua"
    press("<CR>")
    eq("src/app.lua", path_of(s))
    eq(s.win_new, api.nvim_get_current_win())
  end)

  it("tree <CR> on a directory collapses it", function()
    api.nvim_set_current_win(s.win_tree)
    api.nvim_win_set_cursor(s.win_tree, { 3, 0 })
    press("<CR>")
    eq("▸ docs/", tree_lines(s)[3])
    eq("▾ src/", tree_lines(s)[4])
    press("<CR>")
    eq("  A new.md", tree_lines(s)[4])
  end)

  it("edits in the real buffer update the diff live", function()
    api.nvim_set_current_win(s.win_new)
    local buf = api.nvim_win_get_buf(s.win_new)
    api.nvim_buf_set_lines(buf, 1, 2, false, { "local b = 2" })
    vim.cmd("diffupdate")
    eq(0, vim.fn.diff_hlID(2, 1), "line 2 no longer differs")
    vim.cmd("silent write")
  end)

  it("R refreshes the file list", function()
    vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "return a + b + c" }, repo .. "/src/app.lua")
    vim.cmd("checktime")
    api.nvim_set_current_win(s.win_tree)
    press("R")
    eq("3 files", tree_lines(s)[2])
    eq(nil, vim.tbl_contains(tree_lines(s), "  M app.lua") or nil)
  end)

  it("navigation maps leave the real buffer when the review moves on", function()
    local real = api.nvim_win_get_buf(s.win_new)
    eq("", vim.bo[real].buftype)
    truthy(vim.fn.maparg("<Tab>", "n", false, true).buffer == 1)
    press("<Tab>")
    local has = false
    for _, m in ipairs(api.nvim_buf_get_keymap(real, "n")) do
      if m.lhs == "<Tab>" then
        has = true
      end
    end
    eq(false, has)
  end)

  it("q closes the review tab", function()
    api.nvim_set_current_win(s.win_tree)
    press("q")
    eq(tabs_before, #api.nvim_list_tabpages())
    eq(nil, require("annodiff.view").current())
  end)
end)

describe(":Annodiff ranges and modes", function()
  local repo = make_repo()
  vim.cmd.cd(repo)
  sh(repo, { "git", "commit", "-qam", "second" })
  sh(repo, { "git", "checkout", "-q", "-b", "feature" })
  write(repo, "README.md", { "# demo", "", "text", "feature line" })
  sh(repo, { "git", "commit", "-q", "-am", "feature" })

  it("A...B uses the merge base and read-only sides", function()
    vim.cmd("Annodiff main...feature")
    local s = require("annodiff.view").current()
    eq({ "README.md" }, vim.tbl_map(function(e)
      return e.path
    end, s.files))
    eq({ "# demo", "", "text" }, buf_lines(s.win_old))
    eq({ "# demo", "", "text", "feature line" }, buf_lines(s.win_new))
    eq("nofile", vim.bo[api.nvim_win_get_buf(s.win_new)].buftype)
    vim.cmd("AnnodiffClose")
  end)

  it("--staged compares HEAD to the index", function()
    write(repo, "README.md", { "staged" })
    sh(repo, { "git", "add", "README.md" })
    write(repo, "README.md", { "unstaged" })
    vim.cmd("Annodiff --staged")
    local s = require("annodiff.view").current()
    eq({ "staged" }, buf_lines(s.win_new))
    vim.cmd("AnnodiffClose")
  end)

  it("no args compares the index to the worktree", function()
    vim.cmd("Annodiff")
    local s = require("annodiff.view").current()
    eq({ "staged" }, buf_lines(s.win_old))
    eq({ "unstaged" }, buf_lines(s.win_new))
    vim.cmd("AnnodiffClose")
  end)

  it("binary files get a placeholder, no diff", function()
    local f = io.open(repo .. "/img.bin", "wb")
    f:write("\0\1\2\3")
    f:close()
    sh(repo, { "git", "add", "img.bin" })
    vim.cmd("Annodiff --staged")
    local s = require("annodiff.view").current()
    local idx
    for i, e in ipairs(s.files) do
      if e.path == "img.bin" then
        idx = i
      end
    end
    require("annodiff.view").open_file(s, idx)
    eq("Binary file: img.bin", buf_lines(s.win_new)[1])
    eq(false, vim.wo[s.win_new].diff)
    vim.cmd("AnnodiffClose")
  end)

  it("bad ref reports an error and opens nothing", function()
    local tabs = #api.nvim_list_tabpages()
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m)
      table.insert(msgs, m)
    end
    vim.cmd("Annodiff nope-not-a-ref")
    vim.notify = orig
    eq(tabs, #api.nvim_list_tabpages())
    eq("annodiff: unknown revision: nope-not-a-ref", msgs[1])
  end)
end)
