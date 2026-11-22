-- Line classification for a two-sided diff, in revdiff terms:
--   "-"  removed line, numbered on the old side
--   "+"  added line, numbered on the new side
--   " "  context line, numbered on the new side (revdiff diffLineNum semantics)
local M = {}

---@alias annodiff.Hunk {[1]: integer, [2]: integer, [3]: integer, [4]: integer} start_a, count_a, start_b, count_b

--- vim.diff options mirroring 'diffopt', so hunks match what diff mode shows.
---@param diffopt? string
function M.diff_opts(diffopt)
  local opts = { result_type = "indices" }
  for item in (diffopt or vim.o.diffopt):gmatch("[^,]+") do
    local key, val = item:match("^([^:]+):?(.*)$")
    if key == "algorithm" and val ~= "" then
      opts.algorithm = val
    elseif key == "linematch" and tonumber(val) then
      opts.linematch = tonumber(val)
    elseif key == "indent-heuristic" then
      opts.indent_heuristic = true
    elseif key == "iwhite" then
      opts.ignore_whitespace_change = true
    elseif key == "iwhiteall" then
      opts.ignore_whitespace = true
    elseif key == "iwhiteeol" then
      opts.ignore_whitespace_change_at_eol = true
    elseif key == "iblank" then
      opts.ignore_blank_lines = true
    end
  end
  return opts
end

---@param old string[]
---@param new string[]
---@param diffopt? string
---@return annodiff.Hunk[]
function M.compute(old, new, diffopt)
  local a = #old > 0 and (table.concat(old, "\n") .. "\n") or ""
  local b = #new > 0 and (table.concat(new, "\n") .. "\n") or ""
  return vim.diff(a, b, M.diff_opts(diffopt)) --[[@as annodiff.Hunk[] ]]
end

-- start/count of a hunk on one side; count 0 means "after line start"
local function range(h, side)
  if side == "old" then
    return h[1], h[2]
  end
  return h[3], h[4]
end

--- Classify a line on one side of the diff.
---@param hunks annodiff.Hunk[]
---@param side "old"|"new"
---@param lnum integer 1-based line on that side
---@return string type, integer line, annodiff.Hunk? hunk
function M.classify(hunks, side, lnum)
  local offset = 0
  for _, h in ipairs(hunks) do
    local start, count = range(h, side)
    if count > 0 and lnum >= start and lnum < start + count then
      return side == "old" and "-" or "+", lnum, h
    end
    local before = (count > 0 and start + count - 1 < lnum) or (count == 0 and start < lnum)
    if before and side == "old" then
      offset = offset + h[4] - h[2]
    end
  end
  return " ", lnum + offset, nil
end

--- Line on the other side that sits on the same screen row in diff mode.
--- Inside a hunk, lines pair up by offset; past the shorter side, the last
--- line of that side (or the line the hunk sits after). 0 means above line 1.
---@param hunks annodiff.Hunk[]
---@param side "old"|"new"
---@param lnum integer
---@return integer
function M.counterpart(hunks, side, lnum)
  local other = side == "old" and "new" or "old"
  local offset = 0
  for _, h in ipairs(hunks) do
    local start, count = range(h, side)
    local ostart, ocount = range(h, other)
    if count > 0 and lnum >= start and lnum < start + count then
      local k = lnum - start
      if k < ocount then
        return ostart + k
      end
      return ocount > 0 and (ostart + ocount - 1) or ostart
    end
    local before = (count > 0 and start + count - 1 < lnum) or (count == 0 and start < lnum)
    if before then
      offset = offset + ocount - count
    end
  end
  return lnum + offset
end

--- Last line of the changed block a "+" / "-" line belongs to (revdiff hunkEndLine).
---@param hunk annodiff.Hunk
---@param type string
function M.block_end(hunk, type)
  local start, count = range(hunk, type == "-" and "old" or "new")
  return start + count - 1
end

return M
