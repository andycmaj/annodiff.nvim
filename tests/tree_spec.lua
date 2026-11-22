local tree = require("annodiff.tree")

local entries = {
  { path = "README.md", status = "M" },
  { path = "lua/annodiff/view.lua", status = "A" },
  { path = "lua/annodiff/git.lua", status = "M" },
  { path = "tests/run.lua", status = "R", old_path = "spec/run.lua" },
  { path = "a/b/c/deep.txt", status = "D" },
}

describe("tree.build", function()
  it("orders files dirs-first, alphabetical", function()
    local _, files = tree.build(entries)
    eq({
      "a/b/c/deep.txt",
      "lua/annodiff/git.lua",
      "lua/annodiff/view.lua",
      "tests/run.lua",
      "README.md",
    }, vim.tbl_map(function(e)
      return e.path
    end, files))
  end)
end)

describe("tree.render", function()
  it("compresses single-child dirs and shows renames", function()
    local root, files = tree.build(entries)
    local lines, map = tree.render(root, files, { header = "HEAD → worktree", collapsed = {} })
    eq({
      "HEAD → worktree",
      "5 files",
      "▾ a/b/c/",
      "  D deep.txt",
      "▾ lua/annodiff/",
      "  M git.lua",
      "  A view.lua",
      "▾ tests/",
      "  R run.lua ← spec/run.lua",
      "M README.md",
    }, lines)
    eq({ kind = "dir", path = "a/b/c" }, map[3])
    eq({ kind = "file", index = 1 }, map[4])
    eq({ kind = "file", index = 5 }, map[10])
  end)

  it("collapses directories", function()
    local root, files = tree.build(entries)
    local lines = tree.render(root, files, { header = "h", collapsed = { ["lua/annodiff"] = true } })
    eq("▸ lua/annodiff/", lines[5])
    eq("▾ tests/", lines[6])
  end)

  it("highlights the current file and status letters", function()
    local root, files = tree.build(entries)
    local _, _, hls = tree.render(root, files, { header = "h", collapsed = {}, current = 2 })
    local current = vim.tbl_filter(function(h)
      return h.group == "AnnodiffCurrent"
    end, hls)
    eq(1, #current)
    eq(5, current[1].line) -- 0-based line of "  M git.lua"
    local added = vim.tbl_filter(function(h)
      return h.group == "AnnodiffStatusAdded"
    end, hls)
    eq({ { line = 6, col_start = 2, col_end = 3, group = "AnnodiffStatusAdded" } }, added)
  end)
end)

describe("tree.ancestors", function()
  it("lists parent dirs", function()
    eq({ "a", "a/b" }, tree.ancestors("a/b/c.txt"))
    eq({}, tree.ancestors("top.txt"))
  end)
end)
