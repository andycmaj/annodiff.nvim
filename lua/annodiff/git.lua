-- Git source: which files changed between two sides, and what each side holds.
--
-- A side is one of:
--   { kind = "worktree" }            the files on disk
--   { kind = "index" }               the staging area (stage 0)
--   { kind = "rev", rev = "<rev>" }  any commit-ish
local M = {}

---@class annodiff.Side
---@field kind "worktree"|"index"|"rev"
---@field rev? string

---@class annodiff.Spec
---@field left annodiff.Side
---@field right annodiff.Side
---@field diff_args string[]
---@field label string
---@field merge_base? {from: string, to: string}

---@class annodiff.Entry
---@field path string        path on the right side, relative to the repo root
---@field old_path? string   rename / copy origin (left side path)
---@field status string      single letter: M A D R C T U X

---@param root? string
---@param args string[]
---@param opts? {raw: boolean}
---@return boolean ok, string stdout, string stderr
function M.run(root, args, opts)
  local cmd = { "git", "--no-pager" }
  if root then
    vim.list_extend(cmd, { "-C", root })
  end
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = not (opts and opts.raw) }):wait()
  end)
  if not ok then
    return false, "", tostring(res)
  end
  return res.code == 0, res.stdout or "", res.stderr or ""
end

--- Repo root for a directory (defaults to the current buffer's dir, then cwd).
---@param dir? string
---@return string? root, string? err
function M.root(dir)
  if not dir then
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= "" and vim.bo.buftype == "" then
      dir = vim.fs.dirname(name)
    end
    if not dir or vim.fn.isdirectory(dir) == 0 then
      dir = vim.fn.getcwd()
    end
  end
  local ok, out, err = M.run(dir, { "rev-parse", "--show-toplevel" })
  if not ok then
    return nil, vim.trim(err) ~= "" and vim.trim(err) or "not a git repository"
  end
  return vim.trim(out)
end

--- Parse :Annodiff arguments into a spec (no git calls).
---@param args string[]
---@return annodiff.Spec? spec, string? err
function M.parse_spec(args)
  local staged = false
  local refs = {}
  for _, a in ipairs(args or {}) do
    if a == "--staged" or a == "--cached" then
      staged = true
    elseif a:sub(1, 2) == "--" then
      return nil, "unknown option " .. a
    else
      table.insert(refs, a)
    end
  end
  if #refs > 1 then
    return nil, "expected at most one ref or range, got " .. #refs
  end
  local ref = refs[1]

  if ref and ref:find("%.%.") then
    if staged then
      return nil, "--staged cannot be combined with a range"
    end
    local from, dots, to = ref:match("^(.-)(%.%.%.?)(.*)$")
    from = from ~= "" and from or "HEAD"
    to = to ~= "" and to or "HEAD"
    local spec = {
      left = { kind = "rev", rev = from },
      right = { kind = "rev", rev = to },
      diff_args = { ref },
      label = ref,
    }
    if dots == "..." then
      spec.merge_base = { from = from, to = to }
    end
    return spec
  end

  if staged then
    local base = ref or "HEAD"
    local diff_args = { "--cached" }
    if ref then
      table.insert(diff_args, ref)
    end
    return {
      left = { kind = "rev", rev = base },
      right = { kind = "index" },
      diff_args = diff_args,
      label = base .. " → index",
    }
  end

  if ref then
    return {
      left = { kind = "rev", rev = ref },
      right = { kind = "worktree" },
      diff_args = { ref },
      label = ref .. " → worktree",
    }
  end

  return {
    left = { kind = "index" },
    right = { kind = "worktree" },
    diff_args = {},
    label = "index → worktree",
  }
end

--- Validate revisions and resolve the merge base for A...B.
---@param root string
---@param spec annodiff.Spec
---@return annodiff.Spec? spec, string? err
function M.resolve(root, spec)
  for _, side in ipairs({ spec.left, spec.right }) do
    if side.kind == "rev" then
      local ok = M.run(root, { "rev-parse", "--verify", "--quiet", side.rev .. "^{commit}" })
      if not ok then
        return nil, "unknown revision: " .. side.rev
      end
    end
  end
  if spec.merge_base then
    local ok, out, err = M.run(root, { "merge-base", spec.merge_base.from, spec.merge_base.to })
    if not ok then
      return nil, "no merge base for " .. spec.label .. ": " .. vim.trim(err)
    end
    spec.left = { kind = "rev", rev = vim.trim(out) }
  end
  return spec
end

--- Parse `git diff --name-status -z` output (port of revdiff parseNameStatusEntries).
---@param out string
---@return annodiff.Entry[]
function M.parse_name_status(out)
  local fields = vim.split(out:gsub("%z+$", ""), "\0", { plain = true })
  local entries = {}
  local i = 1
  while i <= #fields do
    local status = fields[i]
    i = i + 1
    if status ~= "" then
      local path = fields[i]
      i = i + 1
      if not path then
        break
      end
      local letter = status:sub(1, 1)
      local entry = { path = path, status = letter }
      if (letter == "R" or letter == "C") and fields[i] then
        entry.old_path = path
        entry.path = fields[i]
        i = i + 1
      end
      table.insert(entries, entry)
    end
  end
  return entries
end

---@param root string
---@param spec annodiff.Spec
---@return annodiff.Entry[]? entries, string? err
function M.changed_files(root, spec)
  local args = { "diff", "--no-color", "--no-ext-diff", "--name-status", "-M", "-z" }
  vim.list_extend(args, spec.diff_args)
  table.insert(args, "--")
  local ok, out, err = M.run(root, args)
  if not ok then
    return nil, vim.trim(err)
  end
  return M.parse_name_status(out)
end

--- Split raw file content into buffer lines.
---@param content string
---@return string[] lines, boolean binary
function M.to_lines(content)
  if content:sub(1, 8000):find("\0", 1, true) then
    return {}, true
  end
  if content == "" then
    return {}, false
  end
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  -- CRLF files: strip \r when every line has it so the scratch side matches a
  -- real buffer read with fileformat=dos.
  local all_cr = #lines > 0
  for _, l in ipairs(lines) do
    if l:sub(-1) ~= "\r" then
      all_cr = false
      break
    end
  end
  if all_cr then
    for i, l in ipairs(lines) do
      lines[i] = l:sub(1, -2)
    end
  end
  return lines, false
end

--- Content of a path on a side. Returns nil when the path does not exist there.
---@param root string
---@param side annodiff.Side
---@param path string
---@return string[]? lines, boolean binary
function M.show(root, side, path)
  local content
  if side.kind == "worktree" then
    local f = io.open(vim.fs.joinpath(root, path), "rb")
    if not f then
      return nil, false
    end
    content = f:read("*a")
    f:close()
  else
    local object = (side.kind == "index" and ":0" or side.rev) .. ":" .. path
    local ok, out = M.run(root, { "show", object }, { raw = true })
    if not ok then
      return nil, false
    end
    content = out
  end
  return M.to_lines(content)
end

--- Short name for a side, used in buffer names and the tree header.
---@param side annodiff.Side
function M.side_label(side)
  if side.kind == "rev" then
    return side.rev:match("^%x+$") and #side.rev > 12 and side.rev:sub(1, 8) or side.rev
  end
  return side.kind
end

--- Refs for command completion.
---@param root? string
---@return string[]
function M.refs(root)
  local ok, out = M.run(root, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes", "refs/tags" })
  local refs = { "HEAD" }
  if ok then
    vim.list_extend(refs, vim.split(out, "\n", { trimempty = true }))
  end
  return refs
end

return M
