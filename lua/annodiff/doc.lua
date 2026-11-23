-- Doc mode: one document reviewed in a single buffer, its markdown headings as the
-- tree. Pure parsing and rendering here; view.lua owns the windows.
local M = {}

---@class annodiff.Heading
---@field line integer   1-based line the heading starts on
---@field level integer  1-6
---@field depth integer  nesting depth in the index (0 = top)
---@field text string

---@class annodiff.DocArgs
---@field path string  the document, as given (relative to the cwd or absolute)
---@field ref? string  revision to mark changes against

local MARKDOWN = { md = true, markdown = true, mdx = true, mkd = true, mdown = true }

--- Whether a path names a markdown file (by extension).
---@param path string
function M.is_markdown(path)
  local ext = path:match("%.([%w]+)$")
  return ext ~= nil and MARKDOWN[ext:lower()] == true
end

--- Decide whether :Annodiff arguments ask for doc mode.
---
--- Explicit: `--doc [file] [ref]`. The file defaults to the current buffer's file.
--- Auto: a first argument that is a readable markdown file (a path wins over a ref of
--- the same name), optionally followed by a ref.
--- Returns nil (and no error) when the arguments are a diff review.
---@param args string[]
---@param current_file? string the current buffer's file, for a bare --doc
---@return annodiff.DocArgs? doc, string? err
function M.parse_args(args, current_file)
  local explicit = false
  local positional = {}
  local other_flag
  for _, a in ipairs(args) do
    if a == "--doc" then
      explicit = true
    elseif a:sub(1, 2) == "--" then
      other_flag = other_flag or a
    else
      table.insert(positional, a)
    end
  end
  local readable = function(p)
    return vim.fn.filereadable(vim.fn.expand(p)) == 1
  end
  if not explicit then
    if other_flag or #positional == 0 or #positional > 2 then
      return nil
    end
    if not (M.is_markdown(positional[1]) and readable(positional[1])) then
      return nil
    end
    return { path = positional[1], ref = positional[2] }
  end
  if other_flag then
    return nil, "--doc takes a file and a ref, not " .. other_flag
  end
  if #positional > 2 then
    return nil, "--doc takes at most a file and a ref"
  end
  local path, ref = positional[1], positional[2]
  if not path then
    if not current_file or current_file == "" then
      return nil, "--doc needs a file (the current buffer has none)"
    end
    path = current_file
  end
  if not readable(path) then
    return nil, "not a readable file: " .. path
  end
  return { path = path, ref = ref }
end

--- Markdown headings: ATX (`# Title`) and setext (`Title` over `===` / `---`).
--- Lines inside fenced code blocks and YAML front matter are skipped. Depth nests
--- each heading under the nearest earlier heading of a lower level, so a skipped
--- level (# then ###) still indents one step.
---@param lines string[]
---@return annodiff.Heading[]
function M.headings(lines)
  local out = {}
  local stack = {} -- levels of the open ancestors
  local function add(line, level, text)
    while #stack > 0 and stack[#stack] >= level do
      table.remove(stack)
    end
    table.insert(out, { line = line, level = level, depth = #stack, text = text })
    table.insert(stack, level)
  end

  local i = 1
  if lines[1] and lines[1]:match("^%-%-%-%s*$") then
    -- front matter: skip to its closing --- or ...
    for j = 2, #lines do
      if lines[j]:match("^%-%-%-%s*$") or lines[j]:match("^%.%.%.%s*$") then
        i = j + 1
        break
      end
    end
  end

  local fence -- the open fence's marker run, e.g. "```"
  local para -- line number of a paragraph line that a setext underline can turn into a heading
  while i <= #lines do
    local l = lines[i]
    local marker = l:match("^ ? ? ?(```+)") or l:match("^ ? ? ?(~~~+)")
    if fence then
      if marker and marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence and l:match("^%s*[`~]+%s*$") then
        fence = nil
      end
      para = nil
    elseif marker then
      fence = marker
      para = nil
    else
      local hashes, rest = l:match("^ ? ? ?(#+)(.*)$")
      if hashes and #hashes <= 6 and (rest == "" or rest:match("^%s")) then
        local text = vim.trim(rest):gsub("%s+#+$", ""):gsub("^#+$", "")
        add(i, #hashes, text)
        para = nil
      elseif para and l:match("^ ? ? ?=+%s*$") then
        add(para, 1, vim.trim(lines[para]))
        para = nil
      elseif para and l:match("^ ? ? ?%-+%s*$") then
        add(para, 2, vim.trim(lines[para]))
        para = nil
      elseif
        l:match("^%s*$")
        or l:match("^    ") -- indented code
        or l:match("^%s*>") -- block quote
        or l:match("^%s*[-*+]%s") -- list item
        or l:match("^%s*%d+[.)]%s")
        or l:match("^%s*|") -- table row
      then
        para = nil
      else
        para = i
      end
    end
    i = i + 1
  end
  return out
end

--- Index of the heading whose section holds a line (the last heading at or above it).
---@param heads annodiff.Heading[]
---@param line integer
---@return integer?
function M.section_of(heads, line)
  local found
  for i, h in ipairs(heads) do
    if h.line > line then
      break
    end
    found = i
  end
  return found
end

---@class annodiff.DocRenderOpts
---@field header string
---@field current? integer line of the cursor in the document
---@field annotations? annodiff.Annotation[] the document's annotations
---@field summary? string extra text for the count line

--- Render the heading index. Each heading shows the number of annotations in its
--- own section (up to the next heading of any level).
---@param heads annodiff.Heading[]
---@param opts annodiff.DocRenderOpts
---@return string[] lines, annodiff.TreeLine[] map, annodiff.TreeHighlight[] highlights
function M.render(heads, opts)
  local lines, map, hls = {}, {}, {}
  local function add(text, item)
    table.insert(lines, text)
    table.insert(map, item)
    return #lines - 1
  end

  local per = {}
  local total = 0
  for _, a in ipairs(opts.annotations or {}) do
    total = total + 1
    -- removed lines carry old-side numbers; they are not in this buffer's sections
    if a.line > 0 and a.type ~= "-" then
      local idx = M.section_of(heads, a.line)
      if idx then
        per[idx] = (per[idx] or 0) + 1
      end
    end
  end

  local l = add(opts.header, { kind = "header" })
  table.insert(hls, { line = l, col_start = 0, col_end = -1, group = "AnnodiffHeader" })
  local count = #heads == 1 and "1 heading" or (#heads .. " headings")
  if total > 0 then
    count = count .. (" · %d annotation%s"):format(total, total == 1 and "" or "s")
  end
  l = add(count .. (opts.summary or ""), { kind = "header" })
  table.insert(hls, { line = l, col_start = 0, col_end = -1, group = "AnnodiffDim" })

  if #heads == 0 then
    l = add("(no headings)", { kind = "header" })
    table.insert(hls, { line = l, col_start = 0, col_end = -1, group = "AnnodiffDim" })
  end

  local current = opts.current and M.section_of(heads, opts.current)
  for i, h in ipairs(heads) do
    local indent = string.rep("  ", h.depth)
    local text = indent .. (h.text ~= "" and h.text or "(untitled)")
    local count_col
    if per[i] then
      count_col = #text
      text = text .. " [" .. per[i] .. "]"
    end
    local line = add(text, { kind = "heading", line = h.line })
    table.insert(hls, {
      line = line,
      col_start = #indent,
      col_end = count_col or -1,
      group = h.level == 1 and "AnnodiffHeading1" or "AnnodiffHeading",
    })
    if count_col then
      table.insert(hls, { line = line, col_start = count_col + 1, col_end = -1, group = "AnnodiffAnnotationCount" })
    end
    if i == current then
      table.insert(hls, { line = line, col_start = 0, col_end = -1, group = "AnnodiffCurrent", line_hl = true })
    end
  end
  return lines, map, hls
end

--- Path of `file` relative to `root` when it is inside it.
---@param root string
---@param file string
---@return string?
function M.relpath(root, file)
  local r = vim.uv.fs_realpath(root) or root
  local f = vim.uv.fs_realpath(file) or file
  if f:sub(1, #r + 1) == r .. "/" then
    return f:sub(#r + 2)
  end
end

return M
