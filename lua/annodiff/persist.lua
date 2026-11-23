-- On-disk state: per-review JSON under <git-dir>/annodiff/reviews/, and the
-- revdiff-format history entry written when a review closes.
local git = require("annodiff.git")

local M = {}

M.VERSION = 1

--- Atomic write (temp file + rename), mode 0600.
---@return boolean? ok, string? err
function M.write_atomic(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p", tonumber("700", 8))
  local tmp = ("%s.tmp%d"):format(path, vim.uv.os_getpid())
  local fd, err = vim.uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then
    return nil, err
  end
  local _, werr = vim.uv.fs_write(fd, content)
  vim.uv.fs_close(fd)
  if werr then
    vim.uv.fs_unlink(tmp)
    return nil, werr
  end
  local ok, rerr = vim.uv.fs_rename(tmp, path)
  if not ok then
    vim.uv.fs_unlink(tmp)
    return nil, rerr
  end
  return true
end

---@param root string
---@return string
function M.git_dir(root)
  local ok, out = git.run(root, { "rev-parse", "--absolute-git-dir" })
  return ok and vim.trim(out) or vim.fs.joinpath(root, ".git")
end

--- File-name-safe key for a review spec ("HEAD → worktree" -> "HEAD_worktree").
---@param spec annodiff.Spec
function M.key(spec)
  return (spec.label:gsub("[^%w%._%-]+", "_"))
end

---@param root string
---@param spec annodiff.Spec
function M.state_path(root, spec)
  if spec.state_dir then
    return vim.fs.joinpath(spec.state_dir, "review.json")
  end
  return vim.fs.joinpath(M.git_dir(root), "annodiff", "reviews", M.key(spec) .. ".json")
end

---@class annodiff.State
---@field annotations annodiff.Annotation[]
---@field reviewed table<string, boolean>

--- Serialize a store + reviewed set.
---@param store annodiff.Store
---@param reviewed table<string, boolean>
---@param label string
function M.encode(store, reviewed, label)
  local list = {}
  for _, file in ipairs(store:files()) do
    for _, a in ipairs(store:get(file)) do
      table.insert(list, {
        file = a.file,
        line = a.line,
        end_line = a.end_line,
        type = a.type,
        text = a.text,
        anchor = a.anchor,
        orphan = a.orphan or nil,
      })
    end
  end
  local paths = vim.tbl_keys(reviewed)
  table.sort(paths)
  return vim.json.encode({ version = M.VERSION, label = label, annotations = list, reviewed = paths })
end

---@param text string
---@return annodiff.State? state, string? err
function M.decode(text)
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    return nil, "unreadable review state"
  end
  if data.version ~= M.VERSION then
    return nil, ("unsupported review state version %s"):format(tostring(data.version))
  end
  local state = { annotations = {}, reviewed = {} }
  for _, a in ipairs(data.annotations or {}) do
    if type(a.file) == "string" and type(a.line) == "number" and type(a.text) == "string" then
      table.insert(state.annotations, {
        file = a.file,
        line = a.line,
        end_line = a.end_line,
        type = a.type or "",
        text = a.text,
        anchor = a.anchor,
        orphan = a.orphan,
      })
    end
  end
  for _, p in ipairs(data.reviewed or {}) do
    state.reviewed[p] = true
  end
  return state
end

---@param path string
---@return annodiff.State? state, string? err
function M.load(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return M.decode(text)
end

--- revdiff history dir for a repo: $REVDIFF_HISTORY_DIR or ~/.config/revdiff/history, then <basename(root)>.
---@param root string
function M.history_dir(root, base)
  base = base or vim.env.REVDIFF_HISTORY_DIR
  if not base or base == "" then
    base = vim.fs.joinpath(vim.uv.os_homedir(), ".config", "revdiff", "history")
  end
  return vim.fs.joinpath(base, vim.fs.basename(root))
end

--- History entry in revdiff's layout (app/history Save), so the revdiff skill's
--- read-latest-history.sh picks annodiff reviews up too.
---@param p {root: string, ref?: string, diff_args: string[], annotations: string, agent_qa?: string, files: string[], now?: integer}
---@return string content
function M.history_content(p)
  local now = p.now or os.time()
  local out = {
    "# Review: " .. os.date("%Y-%m-%d %H:%M:%S", now),
    "path: " .. p.root,
  }
  if p.ref and p.ref ~= "" then
    table.insert(out, "refs: " .. p.ref)
  end
  local ok, hash = git.run(p.root, { "rev-parse", "--short", "HEAD" })
  if ok and vim.trim(hash) ~= "" then
    table.insert(out, "commit: " .. vim.trim(hash))
  end
  local content = table.concat(out, "\n") .. "\n"
  if p.annotations ~= "" then
    content = content .. "\n## Annotations\n\n" .. p.annotations
  end
  if p.agent_qa and p.agent_qa ~= "" then
    content = content .. "\n## Agent Q&A\n\n" .. p.agent_qa
  end
  if #p.files > 0 then
    local args = { "diff", "--no-color", "--no-ext-diff" }
    vim.list_extend(args, p.diff_args)
    table.insert(args, "--")
    vim.list_extend(args, p.files)
    local dok, diff = git.run(p.root, args)
    if dok and diff ~= "" then
      content = content .. "\n---\n\n## Diff\n\n" .. diff
      if diff:sub(-1) ~= "\n" then
        content = content .. "\n"
      end
    end
  end
  return content
end

--- Write a history entry; returns its path.
function M.save_history(p, base)
  if p.annotations == "" and (p.agent_qa or "") == "" then
    return nil
  end
  local now = p.now or os.time()
  local ms = math.floor((vim.uv.hrtime() / 1e6) % 1000)
  local name = ("%s.%03d-%s.md"):format(os.date("%Y-%m-%dT%H-%M-%S", now), ms, vim.uv.random(4):gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
  local path = vim.fs.joinpath(M.history_dir(p.root, base), name)
  local ok, err = M.write_atomic(path, M.history_content(p))
  if not ok then
    return nil, err
  end
  return path
end

return M
