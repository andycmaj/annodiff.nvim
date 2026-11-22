local git = require("annodiff.git")

describe("parse_spec", function()
  it("no args: index vs worktree", function()
    local spec = git.parse_spec({})
    eq({ kind = "index" }, spec.left)
    eq({ kind = "worktree" }, spec.right)
    eq({}, spec.diff_args)
  end)

  it("ref: ref vs worktree", function()
    local spec = git.parse_spec({ "main" })
    eq({ kind = "rev", rev = "main" }, spec.left)
    eq({ kind = "worktree" }, spec.right)
    eq({ "main" }, spec.diff_args)
  end)

  it("--staged: HEAD vs index", function()
    local spec = git.parse_spec({ "--staged" })
    eq({ kind = "rev", rev = "HEAD" }, spec.left)
    eq({ kind = "index" }, spec.right)
    eq({ "--cached" }, spec.diff_args)
  end)

  it("--staged ref", function()
    local spec = git.parse_spec({ "--staged", "v1" })
    eq({ kind = "rev", rev = "v1" }, spec.left)
    eq({ "--cached", "v1" }, spec.diff_args)
  end)

  it("two-dot range, empty end means HEAD", function()
    local spec = git.parse_spec({ "main.." })
    eq({ kind = "rev", rev = "main" }, spec.left)
    eq({ kind = "rev", rev = "HEAD" }, spec.right)
    eq({ "main.." }, spec.diff_args)
    eq(nil, spec.merge_base)
  end)

  it("three-dot range asks for a merge base", function()
    local spec = git.parse_spec({ "main...feature" })
    eq({ from = "main", to = "feature" }, spec.merge_base)
    eq({ kind = "rev", rev = "feature" }, spec.right)
  end)

  it("rejects bad input", function()
    eq(nil, (git.parse_spec({ "a", "b" })))
    eq(nil, (git.parse_spec({ "--staged", "a..b" })))
    eq(nil, (git.parse_spec({ "--bogus" })))
  end)

  it("--base with and without a branch, also --base=branch", function()
    eq({ mode = "base", base = nil }, { mode = git.parse_spec({ "--base" }).mode, base = git.parse_spec({ "--base" }).base })
    eq("stack-1", git.parse_spec({ "--base", "stack-1" }).base)
    eq("stack-1", git.parse_spec({ "--base=stack-1" }).base)
    eq("since stack-1", git.parse_spec({ "--base", "stack-1" }).label)
  end)

  it("--pr with a number, #number, URL or nothing", function()
    eq(nil, git.parse_spec({ "--pr" }).pr)
    eq("12", git.parse_spec({ "--pr", "12" }).pr)
    eq("12", git.parse_spec({ "--pr", "#12" }).pr)
    eq("https://github.com/o/r/pull/12", git.parse_spec({ "--pr=https://github.com/o/r/pull/12" }).pr)
  end)

  it("--base and --pr stand alone", function()
    eq(nil, (git.parse_spec({ "--base", "main", "HEAD" })))
    eq(nil, (git.parse_spec({ "--staged", "--base" })))
    eq(nil, (git.parse_spec({ "--pr", "--base" })))
    eq(nil, (git.parse_spec({ "--pr", "feature" })))
  end)
end)

describe("parse_name_status", function()
  it("parses statuses, renames and copies", function()
    local out = table.concat({ "M", "a.lua", "R087", "old/x.lua", "new/x.lua", "A", "b c.txt", "C100", "s", "t", "D", "gone" }, "\0")
      .. "\0"
    eq({
      { path = "a.lua", status = "M" },
      { path = "new/x.lua", old_path = "old/x.lua", status = "R" },
      { path = "b c.txt", status = "A" },
      { path = "t", old_path = "s", status = "C" },
      { path = "gone", status = "D" },
    }, git.parse_name_status(out))
  end)

  it("empty output", function()
    eq({}, git.parse_name_status(""))
  end)
end)

describe("to_lines", function()
  it("drops the trailing newline", function()
    eq({ { "a", "b" }, false }, { git.to_lines("a\nb\n") })
  end)
  it("keeps a missing final newline", function()
    eq({ { "a", "b" }, false }, { git.to_lines("a\nb") })
  end)
  it("strips CR when every line has one", function()
    eq({ { "a", "b" }, false }, { git.to_lines("a\r\nb\r\n") })
  end)
  it("keeps CR when mixed", function()
    eq({ { "a\r", "b" }, false }, { git.to_lines("a\r\nb\n") })
  end)
  it("flags binary content", function()
    eq({ {}, true }, { git.to_lines("PNG\0\1\2") })
  end)
  it("empty file", function()
    eq({ {}, false }, { git.to_lines("") })
  end)
end)

describe("side_label", function()
  it("shortens full hashes only", function()
    eq("main", git.side_label({ kind = "rev", rev = "main" }))
    eq("0123abcd", git.side_label({ kind = "rev", rev = string.rep("0123abcd", 5) }))
    eq("index", git.side_label({ kind = "index" }))
  end)
end)

-- Real repos for --base and --pr. gh is a stub on PATH that prints canned JSON; the
-- PR's "GitHub" is a local bare repo at .../owner/repo.git carrying refs/pull/7/head.
local function sh(dir, cmd)
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. "\n" .. (res.stderr or ""))
  return vim.trim(res.stdout)
end

local function put(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function commit(repo, files, msg)
  for name, text in pairs(files) do
    put(repo .. "/" .. name, text)
  end
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-qm", msg })
  return sh(repo, { "git", "rev-parse", "HEAD" })
end

local function new_repo(branch)
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", branch or "main" })
  return repo
end

local function read_file(p)
  local f = assert(io.open(p, "r"))
  local t = f:read("*a")
  f:close()
  return t
end

local function paths(root, spec)
  local out = {}
  for _, e in ipairs(assert(git.changed_files(root, spec))) do
    table.insert(out, e.path)
  end
  table.sort(out)
  return out
end

local function resolved(root, args)
  local spec, err = git.parse_spec(args)
  assert(spec, err)
  return git.resolve(root, spec)
end

describe("--base", function()
  it("defaults to main: merge base vs worktree, commits and uncommitted changes", function()
    local repo = new_repo()
    local mb = commit(repo, { ["a.txt"] = "a\n", ["b.txt"] = "b\n", ["c.txt"] = "c\n" }, "init")
    sh(repo, { "git", "checkout", "-qb", "feature" })
    commit(repo, { ["a.txt"] = "A\n" }, "feat")
    sh(repo, { "git", "checkout", "-q", "main" })
    commit(repo, { ["c.txt"] = "C\n" }, "main moves on")
    sh(repo, { "git", "checkout", "-q", "feature" })
    put(repo .. "/b.txt", "B\n")
    local spec = assert(resolved(repo, { "--base" }))
    eq({ kind = "rev", rev = mb }, spec.left)
    eq({ kind = "worktree" }, spec.right)
    eq("since main", spec.label)
    eq({ "a.txt", "b.txt" }, paths(repo, spec), "main's own later commit stays out")
  end)

  it("prefers origin's default branch over a local main", function()
    local origin = new_repo("trunk")
    commit(origin, { ["a.txt"] = "a\n" }, "init")
    local repo = vim.fn.resolve(vim.fn.tempname())
    sh(vim.fs.dirname(repo), { "git", "clone", "-q", origin, repo })
    sh(repo, { "git", "branch", "main" })
    eq("origin/trunk", git.default_branch(repo))
  end)

  it("a stacked branch reviews just its own layer with --base <branch below>", function()
    local repo = new_repo()
    commit(repo, { ["a.txt"] = "a\n" }, "init")
    sh(repo, { "git", "checkout", "-qb", "stack-1" })
    commit(repo, { ["one.txt"] = "1\n" }, "layer 1")
    sh(repo, { "git", "checkout", "-qb", "stack-2" })
    commit(repo, { ["two.txt"] = "2\n" }, "layer 2")
    eq({ "one.txt", "two.txt" }, paths(repo, assert(resolved(repo, { "--base" }))))
    eq({ "two.txt" }, paths(repo, assert(resolved(repo, { "--base", "stack-1" }))))
  end)

  it("says when there is no base branch", function()
    local repo = new_repo("trunk")
    commit(repo, { ["a.txt"] = "a\n" }, "init")
    local spec, err = resolved(repo, { "--base" })
    eq(nil, spec)
    truthy(err:find("no base branch", 1, true), err)
  end)
end)

describe("--pr", function()
  -- author pushes main and a PR head; main then moves on, as it does on GitHub
  local gh_home = vim.fn.resolve(vim.fn.tempname())
  local remote = gh_home .. "/owner/repo.git"
  vim.fn.mkdir(remote, "p")
  sh(remote, { "git", "init", "-q", "--bare", "-b", "main" })
  local author = new_repo()
  sh(author, { "git", "remote", "add", "origin", remote })
  local mb = commit(author, { ["a.txt"] = "a\n", ["c.txt"] = "c\n" }, "init")
  sh(author, { "git", "push", "-q", "origin", "main" })
  sh(author, { "git", "checkout", "-qb", "feature" })
  local head = commit(author, { ["a.txt"] = "PR\n", ["new.txt"] = "n\n" }, "pr")
  sh(author, { "git", "push", "-q", "origin", "HEAD:refs/pull/7/head" })
  sh(author, { "git", "checkout", "-q", "main" })
  local base = commit(author, { ["c.txt"] = "C\n" }, "main moves on")
  sh(author, { "git", "push", "-q", "origin", "main" })

  local bin = vim.fn.tempname()
  local gh_log = bin .. "/gh.log"
  local function stub_gh(json, code)
    put(bin .. "/gh", ("#!/bin/sh\necho \"$*\" >> %s\ncat <<'JSON'\n%s\nJSON\nexit %d\n"):format(gh_log, json, code or 0))
    vim.uv.fs_chmod(bin .. "/gh", tonumber("755", 8))
  end
  local function pr_json(slug)
    return vim.json.encode({
      number = 7,
      url = "https://github.com/" .. (slug or "owner/repo") .. "/pull/7",
      title = "Add new.txt",
      headRefOid = head,
      baseRefName = "main",
      baseRefOid = base,
    })
  end
  local path = vim.env.PATH
  local function with_gh(fn)
    vim.env.PATH = bin .. ":" .. path
    os.remove(gh_log)
    local ok, err = pcall(fn)
    vim.env.PATH = path
    assert(ok, err)
  end
  local function reviewer()
    local repo = vim.fn.resolve(vim.fn.tempname())
    sh(vim.fs.dirname(repo), { "git", "clone", "-q", "--no-local", remote, repo })
    return repo
  end

  it("fetches a PR that is not checked out and reviews it read-only against its merge base", function()
    local repo = reviewer()
    eq(false, (git.run(repo, { "cat-file", "-e", head .. "^{commit}" })), "clone has no PR head yet")
    stub_gh(pr_json())
    with_gh(function()
      local spec = assert(resolved(repo, { "--pr", "7" }))
      eq({ kind = "rev", rev = mb }, spec.left)
      eq({ kind = "rev", rev = head }, spec.right, "right side is the PR head, so line numbers match it")
      eq("PR #7", spec.label)
      eq({ "a.txt", "new.txt" }, paths(repo, spec), "main's later commit stays out")
      eq({ "PR", "" }, { git.show(repo, spec.right, "a.txt")[1], "" })
      truthy(read_file(gh_log):find("pr view 7 --json", 1, true))
      eq("main", sh(repo, { "git", "rev-parse", "--abbrev-ref", "HEAD" }), "nothing checked out")
    end)
  end)

  it("with no number asks gh for this branch's PR; checked out and clean, the right side is the worktree", function()
    local repo = reviewer()
    sh(repo, { "git", "fetch", "-q", "origin", "refs/pull/7/head" })
    sh(repo, { "git", "checkout", "-q", head })
    stub_gh(pr_json())
    with_gh(function()
      local spec = assert(resolved(repo, { "--pr" }))
      eq({ kind = "worktree" }, spec.right)
      eq({ kind = "rev", rev = mb }, spec.left)
      truthy(spec.title:find("(checked out)", 1, true), spec.title)
      truthy(read_file(gh_log):find("^pr view %-%-json"), read_file(gh_log))
    end)
  end)

  it("checked out but dirty: reads the PR head, not the worktree", function()
    local repo = reviewer()
    sh(repo, { "git", "fetch", "-q", "origin", "refs/pull/7/head" })
    sh(repo, { "git", "checkout", "-q", head })
    put(repo .. "/a.txt", "local edit\n")
    stub_gh(pr_json())
    with_gh(function()
      eq({ kind = "rev", rev = head }, assert(resolved(repo, { "--pr" })).right)
    end)
  end)

  it("a PR in a repo no remote points at is refused", function()
    local repo = reviewer()
    stub_gh(pr_json("someone/else"))
    with_gh(function()
      local spec, err = resolved(repo, { "--pr", "https://github.com/someone/else/pull/7" })
      eq(nil, spec)
      truthy(err:find("no remote of this repo points there", 1, true), err)
    end)
  end)

  it("no PR for this branch says so", function()
    local repo = reviewer()
    stub_gh("", 1)
    with_gh(function()
      local spec, err = resolved(repo, { "--pr" })
      eq(nil, spec)
      truthy(err:find("no PR for this branch", 1, true), err)
    end)
  end)
end)
