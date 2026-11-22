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
---@field ref? string the ref / range as typed (revdiff history "refs:")
---@field mode? "base"|"pr" set by --base / --pr; resolve() fills in the sides
---@field base? string --base branch (nil: the default branch)
---@field pr? string --pr number or URL (nil: this branch's PR)
---@field title? string tree header, when the side names alone say too little
---@field scope? string what the review covers, for the inline agent's prompt

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
  local mode, mode_arg -- "base" | "pr", with its optional value
  args = args or {}
  local i = 1
  while i <= #args do
    local a = args[i]
    local flag, value = a:match("^%-%-(%a+)=(.*)$")
    flag = flag or a:match("^%-%-(%a+)$")
    if a == "--staged" or a == "--cached" then
      staged = true
    elseif flag == "base" or flag == "pr" then
      if mode then
        return nil, "--" .. mode .. " and --" .. flag .. " cannot be combined"
      end
      mode = flag
      if value then
        mode_arg = value ~= "" and value or nil
      elseif args[i + 1] and args[i + 1]:sub(1, 2) ~= "--" then
        mode_arg = args[i + 1]
        i = i + 1
      end
    elseif a:sub(1, 2) == "--" then
      return nil, "unknown option " .. a
    else
      table.insert(refs, a)
    end
    i = i + 1
  end
  if mode then
    if staged or #refs > 0 then
      return nil, "--" .. mode .. " takes no other ref or --staged"
    end
    if mode == "pr" and mode_arg and not (mode_arg:match("^#?%d+$") or mode_arg:match("^https?://")) then
      return nil, "--pr wants a PR number or URL, got " .. mode_arg
    end
    -- resolve() fills in both sides, the diff args and the label
    return {
      mode = mode,
      base = mode == "base" and mode_arg or nil,
      pr = mode == "pr" and mode_arg and mode_arg:gsub("^#", "") or nil,
      left = { kind = "rev" },
      right = { kind = "worktree" },
      diff_args = {},
      label = mode == "pr" and ("PR " .. (mode_arg or "of this branch")) or ("since " .. (mode_arg or "the base branch")),
    }
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
      ref = ref,
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
      ref = ref,
    }
  end

  if ref then
    return {
      left = { kind = "rev", rev = ref },
      right = { kind = "worktree" },
      diff_args = { ref },
      label = ref .. " → worktree",
      ref = ref,
    }
  end

  return {
    left = { kind = "index" },
    right = { kind = "worktree" },
    diff_args = {},
    label = "index → worktree",
  }
end

local function commit_exists(root, rev)
  return (M.run(root, { "rev-parse", "--verify", "--quiet", "--end-of-options", rev .. "^{commit}" }))
end

local function short(root, rev)
  local ok, out = M.run(root, { "rev-parse", "--short", rev })
  return ok and vim.trim(out) or rev:sub(1, 8)
end

--- The branch a feature branch is measured against, as Plannotator picks it: the
--- remote's default (origin/HEAD) when fetched, else origin/main, main,
--- origin/master, master. nil when none of them exists.
---@param root string
---@return string?
function M.default_branch(root)
  local ok, out = M.run(root, { "symbolic-ref", "-q", "refs/remotes/origin/HEAD" })
  if ok then
    local ref = vim.trim(out)
    if M.run(root, { "show-ref", "--verify", "--quiet", ref }) then
      return (ref:gsub("^refs/remotes/", ""))
    end
  end
  for _, ref in ipairs({ "refs/remotes/origin/main", "refs/heads/main", "refs/remotes/origin/master", "refs/heads/master" }) do
    if M.run(root, { "show-ref", "--verify", "--quiet", ref }) then
      return (ref:gsub("^refs/remotes/", ""):gsub("^refs/heads/", ""))
    end
  end
end

--- --base [branch]: everything since the branch forked, the merge base against the
--- worktree (commits + uncommitted changes), like Plannotator's "since base".
---@param root string
---@param spec annodiff.Spec
---@return annodiff.Spec? spec, string? err
function M.resolve_base(root, spec)
  local base = spec.base or M.default_branch(root)
  if not base then
    return nil, "no base branch: none of origin/HEAD, main, master exists; pass --base <branch>"
  end
  if not commit_exists(root, base) then
    return nil, "unknown revision: " .. base
  end
  local ok, out, err = M.run(root, { "merge-base", "--end-of-options", base, "HEAD" })
  if not ok then
    return nil, "no merge base for " .. base .. " and HEAD: " .. vim.trim(err)
  end
  local mb = vim.trim(out)
  spec.left = { kind = "rev", rev = mb }
  spec.right = { kind = "worktree" }
  spec.diff_args = { mb }
  spec.ref = mb
  spec.label = "since " .. base
  spec.title = "since " .. base .. " (" .. short(root, mb) .. ") → worktree"
  spec.scope = "git diff of the working tree against " .. mb .. ", the merge base with " .. base
  return spec
end

--- Run gh in the repo. Returns its decoded JSON output.
---@param root string
---@param args string[]
---@return table? data, string? err
function M.gh_json(root, args)
  local cmd = vim.list_extend({ "gh" }, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { cwd = root, text = true }):wait()
  end)
  if not ok then
    return nil, "gh not found (needed for --pr): " .. tostring(res)
  end
  if res.code ~= 0 then
    return nil, "gh " .. table.concat(args, " ") .. ": " .. vim.trim(res.stderr or "")
  end
  local dok, data = pcall(vim.json.decode, res.stdout or "")
  if not dok or type(data) ~= "table" then
    return nil, "gh " .. table.concat(args, " ") .. ": unreadable output"
  end
  return data
end

--- The remote whose URL is github's owner/repo; nil when none is.
---@param root string
---@param slug string owner/repo
---@return string?
function M.remote_for(root, slug)
  local ok, out = M.run(root, { "remote", "-v" })
  if not ok then
    return nil
  end
  slug = slug:lower()
  for line in out:gmatch("[^\n]+") do
    local name, url = line:match("^(%S+)%s+(%S+)")
    if url then
      local path = url:lower():gsub("%.git$", ""):gsub("/$", "")
      if path:sub(-#slug - 1) == "/" .. slug or path:sub(-#slug - 1) == ":" .. slug then
        return name
      end
    end
  end
end

--- --pr [N|URL]: a GitHub pull request, reviewed locally against its own base, the way
--- GitHub shows it (merge base of base and head ... head), so line numbers match the
--- PR head. Nothing is checked out: when the PR head is not this worktree's clean HEAD,
--- its head and base are fetched into the object store (refs/pull/N/head) and the
--- right side is read from the head commit. When it is, the right side is the
--- worktree, so edits made during the review show live.
---@param root string
---@param spec annodiff.Spec
---@return annodiff.Spec? spec, string? err
function M.resolve_pr(root, spec)
  local args = { "pr", "view" }
  if spec.pr then
    table.insert(args, spec.pr)
  end
  vim.list_extend(args, { "--json", "number,url,title,headRefOid,baseRefName,baseRefOid" })
  local pr, err = M.gh_json(root, args)
  if not pr then
    return nil, spec.pr and err or ("no PR for this branch (" .. err .. ")")
  end
  local slug = type(pr.url) == "string" and pr.url:match("^https?://[^/]+/([^/]+/[^/]+)/pull/%d+")
  if not slug or type(pr.headRefOid) ~= "string" or type(pr.baseRefOid) ~= "string" then
    return nil, "unexpected PR url: " .. tostring(pr.url)
  end
  if not (commit_exists(root, pr.headRefOid) and commit_exists(root, pr.baseRefOid)) then
    local remote = M.remote_for(root, slug)
    if not remote then
      return nil, ("PR #%d is in %s, and no remote of this repo points there"):format(pr.number, slug)
    end
    local fok, _, ferr = M.run(root, {
      "fetch", "--no-tags", "--quiet", remote,
      ("refs/pull/%d/head"):format(pr.number),
      "refs/heads/" .. pr.baseRefName,
    })
    if not fok then
      return nil, ("fetching PR #%d from %s: %s"):format(pr.number, remote, vim.trim(ferr))
    end
    if not (commit_exists(root, pr.headRefOid) and commit_exists(root, pr.baseRefOid)) then
      return nil, ("PR #%d moved while fetching; run it again"):format(pr.number)
    end
  end
  local ok, out, merr = M.run(root, { "merge-base", pr.baseRefOid, pr.headRefOid })
  if not ok then
    return nil, ("no merge base for PR #%d: %s"):format(pr.number, vim.trim(merr))
  end
  local mb = vim.trim(out)
  local _, head = M.run(root, { "rev-parse", "--verify", "--quiet", "HEAD" })
  local _, status = M.run(root, { "status", "--porcelain", "--untracked-files=no" })
  local live = vim.trim(head) == pr.headRefOid and vim.trim(status) == ""
  spec.left = { kind = "rev", rev = mb }
  if live then
    spec.right = { kind = "worktree" }
    spec.diff_args = { mb }
  else
    spec.right = { kind = "rev", rev = pr.headRefOid }
    spec.diff_args = { mb, pr.headRefOid }
  end
  spec.ref = mb .. "..." .. pr.headRefOid
  spec.label = ("PR #%d"):format(pr.number)
  spec.title = ("PR #%d %s → %s%s"):format(
    pr.number,
    pr.baseRefName,
    short(root, pr.headRefOid),
    live and " (checked out)" or ""
  )
  spec.scope = ("GitHub pull request #%d (%s) %q: head %s against the merge base %s with its base branch %s%s"):format(
    pr.number,
    pr.url,
    pr.title or "",
    pr.headRefOid,
    mb,
    pr.baseRefName,
    live and "; the head is checked out here, so the right side is the working tree"
      or "; the head is not checked out here, so files on disk may differ from the reviewed lines"
  )
  return spec
end

--- Validate revisions and resolve the merge base for A...B.
---@param root string
---@param spec annodiff.Spec
---@return annodiff.Spec? spec, string? err
function M.resolve(root, spec)
  if spec.mode == "base" then
    return M.resolve_base(root, spec)
  elseif spec.mode == "pr" then
    return M.resolve_pr(root, spec)
  end
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
