local hunks = require("annodiff.hunks")

describe("hunks.classify", function()
  local old = { "a", "b", "c", "d", "e" }
  local new = { "a", "B", "c", "x", "y", "d" } -- b changed, x/y inserted, e removed
  local h = hunks.compute(old, new, "internal")
  local function at(side, l)
    local t, n = hunks.classify(h, side, l)
    return { t, n }
  end

  it("removed and changed lines on the old side are '-'", function()
    eq({ "-", 2 }, at("old", 2))
    eq({ "-", 5 }, at("old", 5))
  end)

  it("added lines on the new side are '+'", function()
    eq({ "+", 2 }, at("new", 2))
    eq({ "+", 4 }, at("new", 4))
    eq({ "+", 5 }, at("new", 5))
  end)

  it("context lines use new-side numbers from either side", function()
    eq({ " ", 3 }, at("old", 3))
    eq({ " ", 6 }, at("old", 4)) -- old d is new line 6
    eq({ " ", 6 }, at("new", 6))
    eq({ " ", 1 }, at("old", 1))
  end)

  it("block_end gives the last line of the changed block", function()
    local _, _, hunk = hunks.classify(h, "new", 4)
    eq(5, hunks.block_end(hunk, "+"))
  end)
end)

describe("hunks.diff_opts", function()
  it("mirrors diffopt", function()
    eq(
      { result_type = "indices", algorithm = "histogram", linematch = 40, ignore_whitespace_change = true },
      hunks.diff_opts("internal,filler,algorithm:histogram,linematch:40,iwhite")
    )
  end)
end)

describe("hunks.counterpart", function()
  local old = { "a", "b", "c", "d", "e" }
  local new = { "a", "B", "c", "x", "y", "d" }
  local h = hunks.compute(old, new, "internal")

  it("maps context lines both ways", function()
    eq(6, hunks.counterpart(h, "old", 4))
    eq(4, hunks.counterpart(h, "new", 6))
    eq(1, hunks.counterpart(h, "new", 1))
  end)

  it("pairs changed lines by offset", function()
    eq(2, hunks.counterpart(h, "new", 2))
    eq(2, hunks.counterpart(h, "old", 2))
  end)

  it("lines past the shorter side land on the line the hunk sits after", function()
    eq(3, hunks.counterpart(h, "new", 4)) -- inserted x: old has nothing, sits after old c
    eq(3, hunks.counterpart(h, "new", 5))
    eq(6, hunks.counterpart(h, "old", 5)) -- removed e: after new d
  end)

  it("insertion at the very top maps above line 1", function()
    local h2 = hunks.compute({ "a" }, { "x", "a" }, "internal")
    eq(0, hunks.counterpart(h2, "new", 1))
  end)
end)
