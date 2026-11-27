-- Doc mode: one document in one buffer, its markdown headings as the tree.
local api = vim.api
local doc = require("annodiff.doc")
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
  local orig = vim.notify
  local seen = {}
  vim.notify = function(msg)
    table.insert(seen, msg)
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  assert(ok, err)
  return seen
end

local function heads_of(lines)
  return vim.tbl_map(function(h)
    return { h.line, h.level, h.depth, h.text }
  end, doc.headings(lines))
end

describe("doc.headings", function()
  it("reads ATX headings, nested by level", function()
    eq({
      { 1, 1, 0, "Plan" },
      { 3, 2, 1, "Goals" },
      { 5, 3, 2, "Detail" },
      { 6, 2, 1, "Steps" },
    }, heads_of({ "# Plan", "", "## Goals", "text", "### Detail", "## Steps" }))
  end)

  it("a skipped level nests one step, not two", function()
    eq({ { 1, 1, 0, "A" }, { 2, 3, 1, "C" }, { 3, 2, 1, "B" } }, heads_of({ "# A", "### C", "## B" }))
  end)

  it("drops closing hashes, keeps # inside the text, allows up to 3 spaces of indent", function()
    eq({ { 1, 2, 0, "Title" }, { 2, 1, 0, "C#" }, { 3, 1, 0, "" }, { 4, 2, 1, "Indented" } }, heads_of({
      "## Title ##",
      "# C#",
      "#",
      "   ## Indented",
    }))
  end)

  it("ignores #tags, 7+ hashes and 4-space indented lines", function()
    eq({}, heads_of({ "#tag", "####### seven", "    # code" }))
  end)

  it("reads setext headings, not --- after a blank line or a list item", function()
    eq({ { 1, 1, 0, "Top" }, { 4, 2, 1, "Sub" } }, heads_of({
      "Top",
      "===",
      "",
      "Sub",
      "---",
      "",
      "---",
      "- item",
      "---",
    }))
  end)

  it("skips fenced code and front matter", function()
    eq({ { 4, 1, 0, "Real" }, { 10, 2, 1, "After" } }, heads_of({
      "---",
      "title: x",
      "---",
      "# Real",
      "```sh",
      "# not a heading",
      "~~~",
      "# still code",
      "```",
      "## After",
    }))
  end)
end)

describe("doc.parse_args", function()
  local dir = vim.fn.resolve(vim.fn.tempname())
  write(dir, "notes.md", { "# n" })
  write(dir, "code.lua", { "-- x" })
  local md, lua = dir .. "/notes.md", dir .. "/code.lua"

  it("a markdown file path opens doc mode, an optional ref after it", function()
    eq({ path = md }, doc.parse_args({ md }))
    eq({ path = md, ref = "HEAD" }, doc.parse_args({ md, "HEAD" }))
  end)

  it("refs, ranges, flags and missing files stay diff reviews", function()
    eq(nil, doc.parse_args({ "HEAD" }))
    eq(nil, doc.parse_args({ "main...HEAD" }))
    eq(nil, doc.parse_args({}))
    eq(nil, doc.parse_args({ "--staged", md }))
    eq(nil, doc.parse_args({ dir .. "/missing.md" }))
    eq(nil, doc.parse_args({ dir .. "/missing.lua" }))
  end)

  it("any other existing file opens doc mode too, unless it names a commit (issue #2)", function()
    local never = function()
      return false
    end
    eq({ path = lua }, doc.parse_args({ lua }, nil, never))
    eq({ path = lua, ref = "HEAD" }, doc.parse_args({ lua, "HEAD" }, nil, never))
    -- the default check asks git in the cwd; a temp dir outside any repo has no commits
    eq({ path = lua }, doc.parse_args({ lua }))
    -- a real ref wins over a non-markdown file of the same name
    local asked
    local always = function(name)
      asked = name
      return true
    end
    eq(nil, doc.parse_args({ lua }, nil, always))
    eq(lua, asked)
    -- a markdown path still wins over a ref, without asking
    asked = nil
    eq({ path = md }, doc.parse_args({ md }, nil, always))
    eq(nil, asked)
  end)

  it("--doc takes any readable file, or the current buffer's", function()
    eq({ path = lua }, doc.parse_args({ "--doc", lua }))
    eq({ path = md, ref = "HEAD~1" }, doc.parse_args({ "--doc", md, "HEAD~1" }))
    eq({ path = md }, doc.parse_args({ "--doc" }, md))
    local _, err = doc.parse_args({ "--doc" }, "")
    truthy(err and err:find("needs a file"), err)
    _, err = doc.parse_args({ "--doc", "--staged" })
    truthy(err and err:find("--staged"), err)
    _, err = doc.parse_args({ "--doc", dir .. "/missing.md" })
    truthy(err and err:find("not a readable file"), err)
  end)
end)

describe("doc.render", function()
  local heads = doc.headings({ "# Plan", "intro", "## Goals", "g1", "g2", "## Steps", "s1" })

  it("indents headings and counts each section's annotations", function()
    local lines, map = doc.render(heads, {
      header = "plan.md",
      current = 4,
      annotations = {
        { line = 4, type = " " },
        { line = 5, type = "+" },
        { line = 2, type = " " },
        { line = 3, type = "-" }, -- old-side number: not counted in a section
        { line = 0, type = "" },
      },
    })
    eq({ "plan.md", "3 headings · 5 annotations", "Plan [1]", "  Goals [2]", "  Steps" }, lines)
    eq({ kind = "heading", line = 3 }, map[4])
  end)

  it("highlights the section holding the cursor", function()
    local _, _, hls = doc.render(heads, { header = "x", current = 7 })
    local current = vim.tbl_filter(function(h)
      return h.group == "AnnodiffCurrent"
    end, hls)
    eq(1, #current)
    eq(4, current[1].line) -- 0-based: "  Steps"
  end)

  it("says when there are no headings", function()
    eq({ "x", "0 headings", "(no headings)" }, (doc.render({}, { header = "x" })))
  end)
end)

describe(":Annodiff <file.md> (doc mode)", function()
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  local plan = {
    "# Plan",
    "",
    "Intro text.",
    "",
    "## Goals",
    "",
    "- ship it",
    "",
    "## Steps",
    "",
    "1. one",
    "2. two",
    "",
    "### Risks",
    "",
    "none",
  }
  write(repo, "docs/plan.md", plan)
  write(repo, "other.txt", { "x" })
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "init" })
  vim.cmd.cd(repo)
  local tabs_before = #api.nvim_list_tabpages()
  quiet(function()
    vim.cmd("Annodiff docs/plan.md")
  end)
  local s = require("annodiff.view").current()

  it("opens one tab with the tree and a single, non-diff window on the real file", function()
    truthy(s and s.doc, "doc session")
    eq(tabs_before + 1, #api.nvim_list_tabpages())
    eq(2, #api.nvim_tabpage_list_wins(s.tab))
    eq(nil, s.win_old)
    eq(false, vim.wo[s.win_new].diff)
    eq(repo .. "/docs/plan.md", api.nvim_buf_get_name(api.nvim_win_get_buf(s.win_new)))
    eq("", vim.bo[api.nvim_win_get_buf(s.win_new)].buftype)
    eq(s.win_new, api.nvim_get_current_win())
  end)

  it("the tree is the heading index, no added-line marks on a plain document", function()
    eq({ "docs/plan.md", "4 headings", "Plan", "  Goals", "  Steps", "    Risks" }, api.nvim_buf_get_lines(s.buf_tree, 0, -1, false))
    local hl = vim.tbl_filter(function(m)
      return m[4].line_hl_group ~= nil
    end, api.nvim_buf_get_extmarks(s.buf_new, annotate.ns, 0, -1, { details = true }))
    eq({}, hl)
  end)

  it("<CR> on a heading jumps the document there", function()
    api.nvim_set_current_win(s.win_tree)
    api.nvim_win_set_cursor(s.win_tree, { 5, 0 }) -- "  Steps"
    press("<CR>")
    eq(s.win_new, api.nvim_get_current_win())
    eq(9, api.nvim_win_get_cursor(s.win_new)[1])
    eq(5, api.nvim_win_get_cursor(s.win_tree)[1], "tree cursor follows the section")
  end)

  it("<Tab> / <S-Tab> step through headings", function()
    press("<Tab>")
    eq(14, api.nvim_win_get_cursor(s.win_new)[1])
    press("<S-Tab><S-Tab>")
    eq(5, api.nvim_win_get_cursor(s.win_new)[1])
  end)

  it("moving the cursor moves the tree's current-section highlight", function()
    api.nvim_win_set_cursor(s.win_new, { 12, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {})
    local rows = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(s.buf_tree, -1, 0, -1, { details = true })) do
      if m[4].line_hl_group == "AnnodiffCurrent" then
        table.insert(rows, m[2])
      end
    end
    eq({ 4 }, rows) -- 0-based row of "  Steps"
  end)

  it("annotations work on the document and count in the index", function()
    api.nvim_set_current_win(s.win_new)
    api.nvim_win_set_cursor(s.win_new, { 11, 0 })
    press("\\asplit this step<C-s>")
    api.nvim_win_set_cursor(s.win_new, { 7, 0 })
    press("\\awhy?<C-s>")
    eq(2, s.store:count())
    eq({ "docs/plan.md", "4 headings · 2 annotations", "Plan", "  Goals [1]", "  Steps [1]", "    Risks" }, api.nvim_buf_get_lines(s.buf_tree, 0, -1, false))
    local path = annotate.export(s)
    eq(
      table.concat({ "## docs/plan.md:7 ( )", "why?", "", "## docs/plan.md:11 ( )", "split this step", "" }, "\n"),
      table.concat(vim.fn.readfile(path, "b"), "\n")
    )
  end)

  it("editing the document re-reads the headings and marks the edit", function()
    local buf = api.nvim_win_get_buf(s.win_new)
    api.nvim_buf_set_lines(buf, 7, 7, false, { "## Non-goals" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.wait(100, function()
      return api.nvim_buf_get_lines(s.buf_tree, 4, 5, false)[1] == "  Non-goals"
    end)
    eq("  Non-goals", api.nvim_buf_get_lines(s.buf_tree, 4, 5, false)[1])
    local added = vim.tbl_filter(function(m)
      return m[4].line_hl_group ~= nil
    end, api.nvim_buf_get_extmarks(buf, annotate.ns, 0, -1, { details = true }))
    eq(1, #added)
    eq(7, added[1][2]) -- 0-based row of the inserted line
    vim.cmd("silent! undo")
  end)

  it("the layout key does not split a document", function()
    local msgs = quiet(function()
      require("annodiff.view").set_layout(s, "split")
    end)
    eq(2, #api.nvim_tabpage_list_wins(s.tab))
    truthy(msgs[1] and msgs[1]:find("one layout"), vim.inspect(msgs))
  end)

  it("closing writes the export the planning launcher reads", function()
    quiet(function()
      api.nvim_buf_call(api.nvim_win_get_buf(s.win_new), function()
        vim.cmd("silent! write")
      end)
      api.nvim_set_current_win(s.win_tree)
      press("q")
    end)
    eq(tabs_before, #api.nvim_list_tabpages())
    local out = vim.fn.readfile(repo .. "/.git/annodiff/annotations.md")
    eq("## docs/plan.md:7 ( )", out[1])
  end)

  it("reopening restores the annotations (same document, same review)", function()
    quiet(function()
      vim.cmd("Annodiff --doc docs/plan.md")
    end)
    local s2 = require("annodiff.view").current()
    eq(2, s2.store:count())
    quiet(function()
      require("annodiff.view").close(s2)
    end)
  end)
end)

describe(":Annodiff --doc <file> <ref> (changes marked)", function()
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  write(repo, "plan.md", {})
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "empty" })
  vim.cmd.cd(repo)

  it("an empty base (first plan round) marks nothing", function()
    write(repo, "plan.md", { "# Plan", "step one", "step two" })
    quiet(function()
      vim.cmd("Annodiff --doc plan.md HEAD")
    end)
    local s = require("annodiff.view").current()
    eq("plan.md", api.nvim_buf_get_lines(s.buf_tree, 0, 1, false)[1])
    local hl = vim.tbl_filter(function(m)
      return m[4].line_hl_group ~= nil
    end, api.nvim_buf_get_extmarks(s.buf_new, annotate.ns, 0, -1, { details = true }))
    eq({}, hl)
    quiet(function()
      require("annodiff.view").close(s)
    end)
  end)

  it("a non-empty base marks added lines and shows removed ones as ghost rows", function()
    sh(repo, { "git", "commit", "-qam", "round 1" })
    write(repo, "plan.md", { "# Plan", "step one", "step 2a", "step 2b" })
    quiet(function()
      vim.cmd("Annodiff --doc plan.md HEAD")
    end)
    local s = require("annodiff.view").current()
    eq("plan.md · changes since HEAD", api.nvim_buf_get_lines(s.buf_tree, 0, 1, false)[1])
    eq(3, api.nvim_win_get_cursor(s.win_new)[1], "opens on the first change")
    local added, ghosts = {}, {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(s.buf_new, annotate.ns, 0, -1, { details = true })) do
      if m[4].line_hl_group then
        table.insert(added, m[2] + 1)
      end
      for _, vl in ipairs(m[4].virt_lines or {}) do
        local t = {}
        for _, c in ipairs(vl) do
          table.insert(t, c[1])
        end
        table.insert(ghosts, vim.trim(table.concat(t)))
      end
    end
    eq({ 3, 4 }, added)
    truthy(vim.tbl_contains(ghosts, "step two"), vim.inspect(ghosts))
    -- an added line annotates as (+), the format the planning hook explains
    press("\\asplit<C-s>")
    eq("## plan.md:3 (+)", vim.split(s.store:format(), "\n")[1])
    quiet(function()
      require("annodiff.view").close(s)
    end)
  end)

  it("errors on an unknown ref and opens nothing", function()
    local before = #api.nvim_list_tabpages()
    local msgs = quiet(function()
      vim.cmd("Annodiff --doc plan.md nope")
    end)
    eq(before, #api.nvim_list_tabpages())
    truthy(msgs[1]:find("unknown revision: nope", 1, true), vim.inspect(msgs))
  end)
end)

describe(":Annodiff <file> for a non-markdown file (issue #2)", function()
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  write(repo, "src/app.ts", { "export const a = 1;", "export const b = 2;" })
  write(repo, "release", { "not a ref, a file" })
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "init" })
  sh(repo, { "git", "branch", "release" })
  write(repo, "src/app.ts", { "export const a = 1;", "export const b = 3;" })
  vim.cmd.cd(repo)

  it("opens doc mode with the review keys, not 'unknown revision'", function()
    local msgs = quiet(function()
      vim.cmd("Annodiff src/app.ts")
    end)
    local s = require("annodiff.view").current()
    truthy(s and s.doc, "doc session; notices: " .. vim.inspect(msgs))
    eq("src/app.ts", s.spec.doc)
    eq(false, s.doc_markdown)
    press("\\anote<C-s>")
    eq("## src/app.ts:1 ( )", vim.split(s.store:format(), "\n")[1])
    quiet(function()
      require("annodiff.view").close(s)
    end)
  end)

  it("takes a ref after the file, as --doc does", function()
    quiet(function()
      vim.cmd("Annodiff src/app.ts HEAD")
    end)
    local s = require("annodiff.view").current()
    truthy(s and s.doc, "doc session")
    eq("HEAD", s.spec.left and s.spec.left.rev)
    quiet(function()
      require("annodiff.view").close(s)
    end)
  end)

  it("a name that resolves as a commit is still a diff review", function()
    local msgs = quiet(function()
      vim.cmd("Annodiff release")
    end)
    local s = require("annodiff.view").current()
    truthy(s and not s.doc, "diff session; notices: " .. vim.inspect(msgs))
    eq("release", s.spec.left.rev)
    quiet(function()
      require("annodiff.view").close(s)
    end)
  end)

  it("when a readable file still fails as a ref, the error suggests --doc", function()
    local msgs = quiet(function()
      vim.cmd("Annodiff --staged src/app.ts")
    end)
    truthy(msgs[1] and msgs[1]:find("--doc src/app.ts", 1, true), vim.inspect(msgs))
  end)
end)

describe(":Annodiff --doc on a file outside any git repo (an agent's message)", function()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  write(dir, "turn.md", { "# Q12", "", "Stable ids?", "", "## Options", "", "a or b" })
  local other = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(other, "p")
  vim.cmd.cd(other) -- not a repo either; the file is named by its absolute path
  local s
  quiet(function()
    vim.cmd("Annodiff --doc " .. vim.fn.fnameescape(dir .. "/turn.md"))
  end)
  s = require("annodiff.view").current()

  it("opens with the file's directory as the root", function()
    truthy(s and s.doc, "doc session")
    eq(dir, s.root)
    eq({ "turn.md", "2 headings", "Q12", "  Options" }, api.nvim_buf_get_lines(s.buf_tree, 0, -1, false))
    eq(dir .. "/turn.md", api.nvim_buf_get_name(api.nvim_win_get_buf(s.win_new)))
  end)

  it("annotates, and keeps state and the export under Neovim's state dir, not next to the file", function()
    api.nvim_set_current_win(s.win_new)
    api.nvim_win_set_cursor(s.win_new, { 3, 0 })
    press("\\ayes, stable<C-s>")
    local path = annotate.export(s)
    truthy(vim.startswith(path, vim.env.XDG_STATE_HOME), path)
    eq({ "## turn.md:3 ( )", "yes, stable" }, vim.fn.readfile(path))
    eq(1, vim.fn.filereadable(s.state_path), s.state_path)
    eq({ "turn.md" }, vim.fn.readdir(dir), "nothing written beside the document")
  end)

  it("read-latest.sh --doc finds that export (the notes-never-arrived fallback)", function()
    local script = api.nvim_get_runtime_file("skills/annodiff/scripts/read-latest.sh", false)[1]
    local path = annotate.export(s)
    -- through a symlink too: annodiff keys the state dir on the real path
    local link = vim.fn.tempname()
    vim.uv.fs_symlink(dir, link)
    for _, arg in ipairs({ dir .. "/turn.md", link .. "/turn.md" }) do
      local res = vim.system({ script, "--doc", arg }, { cwd = other, text = true }):wait()
      eq(0, res.code, res.stderr)
      eq("source: " .. path .. "\n\n## turn.md:3 ( )\nyes, stable\n", res.stdout)
    end
    -- without --doc, from a dir that is not a repo: the newest document notes (RIKER-0255)
    eq("source: " .. path .. "\n\n## turn.md:3 ( )\nyes, stable\n", vim.system({ script }, { cwd = other, text = true }):wait().stdout)
  end)

  it("keeps the export current on every change, before any send or close (RIKER-0255)", function()
    local path = annotate.default_path(s)
    api.nvim_set_current_win(s.win_new)
    api.nvim_win_set_cursor(s.win_new, { 7, 0 })
    press("\\aoption b<C-s>")
    eq({ "## turn.md:3 ( )", "yes, stable", "", "## turn.md:7 ( )", "option b" }, vim.fn.readfile(path))
    api.nvim_win_set_cursor(s.win_new, { 7, 0 })
    press("\\d")
    eq({ "## turn.md:3 ( )", "yes, stable" }, vim.fn.readfile(path), "a delete is written too")
  end)

  it("closing writes no revdiff history entry, and reopening restores the note", function()
    quiet(function()
      require("annodiff.view").close(s)
    end)
    eq(0, vim.fn.isdirectory(vim.fs.joinpath(vim.env.REVDIFF_HISTORY_DIR, vim.fs.basename(dir))))
    quiet(function()
      vim.cmd("Annodiff " .. vim.fn.fnameescape(dir .. "/turn.md"))
    end)
    local s2 = require("annodiff.view").current()
    eq(1, s2.store:count())
    quiet(function()
      require("annodiff.view").close(s2)
    end)
  end)

  it("a ref is refused without a repo", function()
    local msgs = quiet(function()
      vim.cmd("Annodiff --doc " .. vim.fn.fnameescape(dir .. "/turn.md") .. " HEAD")
    end)
    truthy(msgs[1]:find("needs the file in a git repository", 1, true), vim.inspect(msgs))
  end)
end)
