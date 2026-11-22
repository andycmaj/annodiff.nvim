-- File tree for the changed-file list: pure build + render, no Neovim UI calls.
local M = {}

---@class annodiff.TreeDir
---@field name string
---@field path string
---@field dirs table<string, annodiff.TreeDir>
---@field files annodiff.Entry[]

---@class annodiff.TreeLine
---@field kind "header"|"dir"|"file"
---@field path? string   dir path (dir lines)
---@field index? integer index into the ordered file list (file lines)

---@class annodiff.TreeHighlight
---@field line integer  0-based
---@field col_start integer
---@field col_end integer  -1 for end of line
---@field group string

local status_groups = {
  M = "AnnodiffStatusModified",
  A = "AnnodiffStatusAdded",
  D = "AnnodiffStatusDeleted",
  R = "AnnodiffStatusRenamed",
  C = "AnnodiffStatusRenamed",
}

local function new_dir(name, path)
  return { name = name, path = path, dirs = {}, files = {} }
end

local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  return keys
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

--- Build the directory tree and the display-ordered file list.
---@param entries annodiff.Entry[]
---@return annodiff.TreeDir root, annodiff.Entry[] files
function M.build(entries)
  local root = new_dir("", "")
  for _, entry in ipairs(entries) do
    local node = root
    local parts = vim.split(entry.path, "/", { plain = true })
    for i = 1, #parts - 1 do
      local part = parts[i]
      if not node.dirs[part] then
        node.dirs[part] = new_dir(part, node.path == "" and part or (node.path .. "/" .. part))
      end
      node = node.dirs[part]
    end
    table.insert(node.files, entry)
  end

  -- Directories first, then files, each alphabetical; this is the order the
  -- tree shows them fully expanded and the order file navigation follows.
  local files = {}
  local function walk(node)
    for _, key in ipairs(sorted_keys(node.dirs)) do
      walk(node.dirs[key])
    end
    table.sort(node.files, function(a, b)
      return a.path < b.path
    end)
    for _, entry in ipairs(node.files) do
      table.insert(files, entry)
    end
  end
  walk(root)
  return root, files
end

--- Follow single-child directory chains (a/b/c with nothing else) into one row.
---@param node annodiff.TreeDir
---@return annodiff.TreeDir last, string name
local function compress(node)
  local name = node.name
  while #node.files == 0 do
    local keys = vim.tbl_keys(node.dirs)
    if #keys ~= 1 then
      break
    end
    node = node.dirs[keys[1]]
    name = name .. "/" .. node.name
  end
  return node, name
end

---@class annodiff.RenderOpts
---@field header string
---@field collapsed table<string, boolean>
---@field current? integer index of the open file
---@field counts? table<string, integer> annotation count per path
---@field reviewed? table<string, boolean>
---@field hidden? table<string, boolean> paths filtered out
---@field summary? string extra text for the count line

--- Render the tree to lines.
---@param root annodiff.TreeDir
---@param files annodiff.Entry[]
---@param opts annodiff.RenderOpts
---@return string[] lines, annodiff.TreeLine[] map, annodiff.TreeHighlight[] highlights
function M.render(root, files, opts)
  local index_of = {}
  for i, entry in ipairs(files) do
    index_of[entry] = i
  end

  local lines, map, hls = {}, {}, {}
  local function add(text, item)
    table.insert(lines, text)
    table.insert(map, item)
    return #lines - 1
  end

  local count = (#files == 1 and "1 file" or (#files .. " files")) .. (opts.summary or "")
  local hidden = opts.hidden or {}
  local visible_cache = {}
  local function has_visible(node)
    if visible_cache[node] == nil then
      local v = false
      for _, e in ipairs(node.files) do
        if not hidden[e.path] then
          v = true
          break
        end
      end
      if not v then
        for _, d in pairs(node.dirs) do
          if has_visible(d) then
            v = true
            break
          end
        end
      end
      visible_cache[node] = v
    end
    return visible_cache[node]
  end
  local l = add(opts.header, { kind = "header" })
  table.insert(hls, { line = l, col_start = 0, col_end = -1, group = "AnnodiffHeader" })
  l = add(count, { kind = "header" })
  table.insert(hls, { line = l, col_start = 0, col_end = -1, group = "AnnodiffDim" })

  local function walk(node, depth)
    local indent = string.rep("  ", depth)
    for _, key in ipairs(sorted_keys(node.dirs)) do
      local dir, name = compress(node.dirs[key])
      if not has_visible(dir) then
        goto continue
      end
      local closed = opts.collapsed[dir.path]
      local icon = closed and "▸ " or "▾ "
      local line = add(indent .. icon .. name .. "/", { kind = "dir", path = dir.path })
      table.insert(hls, { line = line, col_start = #indent + #icon, col_end = -1, group = "AnnodiffDirectory" })
      if not closed then
        walk(dir, depth + 1)
      end
      ::continue::
    end
    for _, entry in ipairs(node.files) do
      if hidden[entry.path] then
        goto next_file
      end
      local idx = index_of[entry]
      local text = indent .. entry.status .. " " .. basename(entry.path)
      local origin_col
      if entry.old_path then
        origin_col = #text
        text = text .. " ← " .. entry.old_path
      end
      local reviewed_col
      if opts.reviewed and opts.reviewed[entry.path] then
        reviewed_col = #text
        text = text .. " ✓"
      end
      local count_col
      local n = opts.counts and opts.counts[entry.path]
      if n and n > 0 then
        count_col = #text
        text = text .. " [" .. n .. "]"
      end
      local line = add(text, { kind = "file", index = idx })
      if count_col then
        table.insert(hls, { line = line, col_start = count_col + 1, col_end = -1, group = "AnnodiffAnnotationCount" })
      end
      if reviewed_col then
        table.insert(hls, { line = line, col_start = reviewed_col + 1, col_end = reviewed_col + 4, group = "AnnodiffReviewed" })
      end
      table.insert(hls, {
        line = line,
        col_start = #indent,
        col_end = #indent + 1,
        group = status_groups[entry.status] or "AnnodiffStatusOther",
      })
      if origin_col then
        table.insert(hls, { line = line, col_start = origin_col, col_end = -1, group = "AnnodiffDim" })
      end
      if idx == opts.current then
        table.insert(hls, { line = line, col_start = 0, col_end = -1, group = "AnnodiffCurrent", line_hl = true })
      end
      ::next_file::
    end
  end
  walk(root, 0)
  return lines, map, hls
end

--- Directory paths that contain a file path (for expanding on navigation).
---@param path string
---@return string[]
function M.ancestors(path)
  local out = {}
  local acc
  local parts = vim.split(path, "/", { plain = true })
  for i = 1, #parts - 1 do
    acc = acc and (acc .. "/" .. parts[i]) or parts[i]
    table.insert(out, acc)
  end
  return out
end

return M
