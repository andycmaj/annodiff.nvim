-- Store + revdiff `##` format. Expected strings are copied from revdiff's
-- app/annotation/store_test.go so the export stays byte-compatible.
local annotations = require("annodiff.annotations")

local function store(list)
  local s = annotations.new()
  for _, a in ipairs(list) do
    s:add(a)
  end
  return s
end

describe("format (revdiff FormatOutput)", function()
  it("empty", function()
    eq("", annotations.new():format())
  end)

  it("single", function()
    local s = store({ { file = "handler.go", line = 43, type = "+", text = "use errors.Is() instead of direct comparison" } })
    eq("## handler.go:43 (+)\nuse errors.Is() instead of direct comparison\n", s:format())
  end)

  it("multi file", function()
    local s = store({
      { file = "store.go", line = 18, type = "-", text = "don't remove this validation" },
      { file = "handler.go", line = 43, type = "+", text = "use errors.Is() instead of direct comparison" },
    })
    eq(
      "## handler.go:43 (+)\nuse errors.Is() instead of direct comparison\n\n## store.go:18 (-)\ndon't remove this validation\n",
      s:format()
    )
  end)

  it("same file sorted by line, context type", function()
    local s = store({
      { file = "handler.go", line = 43, type = "+", text = "fix this" },
      { file = "handler.go", line = 10, type = " ", text = "add docs" },
    })
    eq("## handler.go:10 ( )\nadd docs\n\n## handler.go:43 (+)\nfix this\n", s:format())
  end)

  it("file-level first, ranges", function()
    local s = store({
      { file = "handler.go", line = 43, end_line = 47, type = "+", text = "fix this hunk" },
      { file = "handler.go", line = 0, type = "", text = "file needs refactoring" },
    })
    eq("## handler.go (file-level)\nfile needs refactoring\n\n## handler.go:43-47 (+)\nfix this hunk\n", s:format())
  end)

  it("escapes body lines that look like headers", function()
    local s = store({ { file = "a.go", line = 1, type = "+", text = "see\n## not a header\n  ## indented\n### fine" } })
    eq("## a.go:1 (+)\nsee\n ## not a header\n   ## indented\n### fine\n", s:format())
  end)
end)

describe("store", function()
  it("add replaces same file/line/type, keeps others", function()
    local s = store({
      { file = "f", line = 5, type = "+", text = "one" },
      { file = "f", line = 5, type = "-", text = "old side" },
      { file = "f", line = 5, type = "+", text = "two" },
    })
    eq(2, s:count())
    eq("two", s:find("f", 5, "+").text)
  end)

  it("delete", function()
    local s = store({ { file = "f", line = 0, type = "", text = "x" }, { file = "f", line = 3, type = "+", text = "y" } })
    eq(true, s:delete("f", 0, ""))
    eq(false, s:delete("f", 0, ""))
    eq(1, s:count("f"))
    s:delete("f", 3, "+")
    eq({}, s:files())
  end)
end)

describe("parse (revdiff Parse)", function()
  it("round-trips format output", function()
    local s = store({
      { file = "b.go", line = 0, type = "", text = "file note" },
      { file = "a.go", line = 3, end_line = 9, type = "-", text = "multi\nline\n## tricky\n\nwith blank" },
      { file = "a (copy).go:2", line = 7, type = " ", text = "odd path" },
    })
    local text = s:format()
    local parsed = assert(annotations.parse(text))
    eq(text, store(parsed):format())
    eq("multi\nline\n## tricky\n\nwith blank", parsed[2].text)
    eq({ file = "a (copy).go:2", line = 7, type = " ", text = "odd path" }, parsed[1])
  end)

  it("file-level path that ends in :N keeps it", function()
    local parsed = assert(annotations.parse("## weird:12 (file-level)\nnote\n"))
    eq({ file = "weird:12", line = 0, type = "", text = "note" }, parsed[1])
  end)

  it("rejects content before the first header", function()
    eq(nil, (annotations.parse("hello\n## a:1 (+)\nx\n")))
    eq(nil, (annotations.parse("## nope\n")))
  end)
end)
