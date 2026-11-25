-- The Claude Code integration: plugin manifests, the /annodiff skill's scripts and the
-- annodiff-planning ExitPlanMode hook. Scripts run for real; tmux, nvim and the plan
-- launcher are replaced by stubs on PATH / in the plugin's user override layer.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

local function run(cmd, opts)
  opts = opts or {}
  return vim.system(cmd, { cwd = opts.cwd, env = opts.env, stdin = opts.stdin, text = true }):wait()
end

local function sh(dir, cmd)
  local res = run(cmd, { cwd = dir })
  assert(res.code == 0, table.concat(cmd, " ") .. "\n" .. (res.stderr or ""))
  return res.stdout
end

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local t = f:read("*a")
  f:close()
  return t
end

local function write(path, text, mode)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
  if mode then
    vim.uv.fs_chmod(path, tonumber(mode, 8))
  end
end

local function json(path)
  return vim.json.decode((assert(read(path), "missing " .. path)))
end

local function repo_with(files, branch)
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", branch or "main" })
  for name, text in pairs(files) do
    write(repo .. "/" .. name, text)
  end
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "init" })
  return repo
end

describe("plugin manifests", function()
  it("marketplace lists both plugins and each source has a manifest", function()
    local m = json(root .. "/.claude-plugin/marketplace.json")
    eq("annodiff", m.name)
    local names = {}
    for _, p in ipairs(m.plugins) do
      table.insert(names, p.name)
      local manifest = json(vim.fs.normalize(root .. "/" .. p.source .. "/.claude-plugin/plugin.json"))
      eq(p.name, manifest.name)
      eq(p.version, manifest.version, p.name .. " version matches the marketplace entry")
      eq("MIT", manifest.license, p.name .. " license")
    end
    eq({ "annodiff", "annodiff-planning" }, names)
    truthy(read(root .. "/LICENSE"):find("MIT License", 1, true))
  end)

  it("the skill sits where the main plugin discovers it, with executable scripts", function()
    truthy(read(root .. "/skills/annodiff/SKILL.md"):find("name: annodiff", 1, true))
    for _, s in ipairs({ "open.sh", "deliver.sh", "read-latest.sh" }) do
      eq(1, vim.fn.executable(root .. "/skills/annodiff/scripts/" .. s), s)
    end
  end)

  it("the planning hook runs the bundled hook script on ExitPlanMode", function()
    local h = json(root .. "/plugins/annodiff-planning/hooks/hooks.json").hooks.PreToolUse[1]
    eq("ExitPlanMode", h.matcher)
    truthy(h.hooks[1].command:find("${CLAUDE_PLUGIN_ROOT}/scripts/plan-review-hook.py", 1, true))
    for _, s in ipairs({ "plan-review-hook.py", "launch-plan-review.sh", "resolve-launcher.sh" }) do
      eq(1, vim.fn.executable(root .. "/plugins/annodiff-planning/scripts/" .. s), s)
    end
  end)
end)

describe("open.sh", function()
  local open = root .. "/skills/annodiff/scripts/open.sh"
  -- stub tmux: logs its argv, answers display-message from $STUB_TOOLS
  local bin = vim.fn.tempname()
  local log = bin .. "/tmux.log"
  write(
    bin .. "/tmux",
    ([[#!/bin/sh
if [ "$1" = display-message ]; then
  case "$*" in *riker_tools*) printf '%%s\n' "${STUB_TOOLS:-}" ;; *) echo ;; esac
  exit 0
fi
# the review lock (pane options): nothing held; real tmux covers it below
case "$1" in show-options | set-option) exit 0 ;; esac
printf '%%s\n' "$*" >> %s
]]):format(vim.fn.shellescape(log)),
    "755"
  )
  write(bin .. "/nvim", "#!/bin/sh\n", "755")
  -- stub gh: `pr view` prints $STUB_GH_PR (what --jq would print), or fails like gh
  -- does on a branch with no PR
  write(
    bin .. "/gh",
    [[#!/bin/sh
[ -n "${STUB_GH_PR:-}" ] || { echo "no pull requests found for branch" >&2; exit 1; }
printf '%s\n' "$STUB_GH_PR"
]],
    "755"
  )
  local env = { PATH = bin .. ":" .. vim.env.PATH, TMUX = "/tmp/stub,1,0", TMUX_PANE = "%99", CLAUDE_PLUGIN_DATA = "" }

  local function open_in(repo, args, extra)
    os.remove(log)
    local res = run(vim.list_extend({ open }, args or {}), { cwd = repo, env = vim.tbl_extend("force", env, extra or {}) })
    -- the command line arrives printf %q-quoted; drop the backslashes to match on it
    return res, ((read(log) or ""):gsub("\\(.)", "%1"))
  end

  local function options(stdout)
    local out = {}
    for label, args in stdout:gmatch("option: ([^|\n]-) | ([^|\n]-) |") do
      table.insert(out, label .. " = " .. args)
    end
    return out
  end

  it("explicit args open :Annodiff in a new window, notes back to this pane", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    write(repo .. "/a.txt", "b\n")
    local res, calls = open_in(repo, { "HEAD" })
    eq(0, res.code, res.stderr)
    truthy(calls:find("new-window -n annodiff", 1, true), calls)
    truthy(calls:find("Annodiff HEAD", 1, true), calls)
    truthy(calls:find("deliver.sh", 1, true) and calls:find("%99", 1, true), "deliver.sh targets the calling pane")
    truthy(calls:find("set rtp^=" .. root, 1, true), "loads this checkout's annodiff")
    truthy(calls:find("ANNODIFF_SEND_ON_CLOSE=always", 1, true), "every close reaches this pane, notes or not")
    truthy(calls:find("ANNODIFF_REVIEW_LABEL=HEAD", 1, true), "notes name the review they came from")
    truthy(calls:find("review-lock.sh attach %99", 1, true), "the review pane takes this pane's lock")
    truthy(calls:find("export ANNODIFF_CLOSED_MARK=", 1, true), calls)
    truthy(calls:find("; ANNODIFF_SEND_REASON=exit [^;]*deliver%.sh %%99 </dev/null"), "an exit with no close is reported")
  end)

  it("no args on main with uncommitted changes: asks, uncommitted first, opens nothing", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    write(repo .. "/a.txt", "b\n")
    local res, calls = open_in(repo)
    eq(0, res.code, res.stderr)
    truthy(res.stdout:find("needs_ask: true", 1, true), res.stdout)
    eq({
      "Uncommitted changes = HEAD",
      "A pull request = --pr <number or URL>",
      "A ref or range = <ref>",
    }, options(res.stdout))
    eq("", calls)
  end)

  it("no args on a clean main: the last commit instead of uncommitted", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    write(repo .. "/a.txt", "b\n")
    sh(repo, { "git", "commit", "-qam", "two" })
    local res = open_in(repo)
    eq("Last commit = HEAD~1", options(res.stdout)[1], res.stdout)
    eq(nil, res.stdout:find("--base", 1, true), "nothing since the base on the base branch itself")
  end)

  it("no args on a dirty feature branch: since base first, then uncommitted", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    sh(repo, { "git", "checkout", "-qb", "feature" })
    write(repo .. "/a.txt", "b\n")
    sh(repo, { "git", "commit", "-qam", "feat" })
    write(repo .. "/a.txt", "c\n")
    local res, calls = open_in(repo)
    eq({
      "Everything since main = --base main",
      "Uncommitted changes = HEAD",
      "A pull request = --pr <number or URL>",
      "A ref or range = <ref>",
    }, options(res.stdout))
    truthy(res.stdout:find("1 commit(s) on feature plus uncommitted changes", 1, true), res.stdout)
    truthy(res.stdout:find("base_branch: main", 1, true), res.stdout)
    eq("", calls)
  end)

  it("no args on a branch with a PR offers that PR by number", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    sh(repo, { "git", "checkout", "-qb", "feature" })
    write(repo .. "/a.txt", "b\n")
    sh(repo, { "git", "commit", "-qam", "feat" })
    local head = vim.trim(sh(repo, { "git", "rev-parse", "HEAD" }))
    local res = open_in(repo, {}, { STUB_GH_PR = "12\tmain\t" .. head .. "\tFix | the thing" })
    eq({
      "Everything since main = --base main",
      "Last commit = HEAD~1",
      "PR #12: Fix / the thing = --pr 12",
      "A ref or range = <ref>",
    }, options(res.stdout))
    truthy(res.stdout:find("checked out here", 1, true), res.stdout)
    -- the same PR, but this worktree is somewhere else: read-only
    sh(repo, { "git", "commit", "-q", "--allow-empty", "-m", "local only" })
    res = open_in(repo, {}, { STUB_GH_PR = "12\tmain\t" .. head .. "\tFix" })
    truthy(res.stdout:find("fetched read-only", 1, true), res.stdout)
  end)

  it("a PR number or URL alone means --pr", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    local _, calls = open_in(repo, { "#12" })
    truthy(calls:find("Annodiff --pr 12", 1, true), calls)
    _, calls = open_in(repo, { "https://github.com/o/r/pull/7" })
    truthy(calls:find("Annodiff --pr https://github.com/o/r/pull/7", 1, true), calls)
    _, calls = open_in(repo, { "--base", "stack-1" })
    truthy(calls:find("Annodiff --base stack-1", 1, true), calls)
  end)

  it("passes explicit args through, quoted", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    local _, calls = open_in(repo, { "--staged", "HEAD" })
    truthy(calls:find("Annodiff --staged HEAD", 1, true), calls)
  end)

  it("a document outside any repo opens doc mode from its directory, by absolute path", function()
    local dir = vim.fn.resolve(vim.fn.tempname())
    write(dir .. "/turn.md", "# Q\n")
    local cwd = vim.fn.resolve(vim.fn.tempname()) -- not a repo either
    vim.fn.mkdir(cwd, "p")
    local res, calls = open_in(cwd, { dir .. "/turn.md" })
    eq(0, res.code, res.stderr)
    truthy(calls:find("Annodiff --doc " .. dir .. "/turn.md", 1, true), calls)
    truthy(calls:find("-c " .. dir, 1, true), calls)
    truthy(res.stdout:find("in " .. dir, 1, true), res.stdout)
    -- --doc forces it for any file; a relative path is made absolute
    res, calls = open_in(dir, { "--doc", "turn.md" })
    eq(0, res.code, res.stderr)
    truthy(calls:find("Annodiff --doc " .. dir .. "/turn.md", 1, true), calls)
  end)

  it("a document in a repo keeps its ref; a non-document outside a repo is still an error", function()
    local repo = repo_with({ ["docs/plan.md"] = "# P\n" })
    local _, calls = open_in(repo, { "docs/plan.md", "HEAD~1" })
    truthy(calls:find("Annodiff --doc " .. repo .. "/docs/plan.md HEAD~1", 1, true), calls)
    local res = open_in(vim.fn.tempname():match("^(.*)/"), { "HEAD" })
    eq(1, res.code)
    truthy(res.stderr:find("not in a git repo", 1, true), res.stderr)
    res = open_in(repo, { "--doc", "nope.md" })
    eq(1, res.code)
    truthy(res.stderr:find("not a file: nope.md", 1, true), res.stderr)
  end)

  it("in a riker task window opens a zoomed split through riker-tools pane", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    local tools_log = bin .. "/tools.log"
    write(bin .. "/riker-tools", ('#!/bin/sh\nprintf "%%s\\n" "$*" > %s\n'):format(tools_log), "755")
    local res = open_in(repo, { "HEAD" }, { STUB_TOOLS = bin .. "/riker-tools" })
    eq(0, res.code, res.stderr)
    local t = (read(tools_log) or ""):gsub("\\(.)", "%1")
    truthy(t:find("^pane %-%-zoom %-%-cwd"), t)
    truthy(t:find("Annodiff HEAD", 1, true), t)
  end)

  it("a user override in $CLAUDE_PLUGIN_DATA replaces the bundled launcher", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    local data = vim.fn.tempname()
    write(data .. "/scripts/open.sh", '#!/bin/sh\necho "override $*"\n', "755")
    local res = open_in(repo, { "main" }, { CLAUDE_PLUGIN_DATA = data })
    eq("override main\n", res.stdout)
  end)

  it("outside tmux says so", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    local res = open_in(repo, {}, { TMUX = "" })
    eq(1, res.code)
    eq("error: not inside tmux\n", res.stderr)
  end)
end)

-- Two opens from one Claude pane, on a real (private) tmux server: open.sh, the review
-- wrapper, deliver.sh and review-lock.sh all run for real. Only Neovim is a stand-in, and
-- the "Claude" pane runs `cat` into a file, so what was pasted there can be read back.
describe("one review per Claude pane (real tmux)", function()
  if vim.fn.executable("tmux") == 0 then
    it("skipped: no tmux", function() end)
    return
  end
  local open = root .. "/skills/annodiff/scripts/open.sh"
  local lock = root .. "/skills/annodiff/scripts/review-lock.sh"
  local tmp = vim.fn.resolve(vim.fn.tempname())
  local bin, ctl, docs = tmp .. "/bin", tmp .. "/ctl", tmp .. "/docs"
  local pasted = tmp .. "/claude.txt"
  vim.fn.mkdir(ctl, "p")
  write(docs .. "/a.md", "# A\n")
  write(docs .. "/b.md", "# B\n")
  write(docs .. "/c.md", "# C\n")
  -- stand-in Neovim: obeys $ctl/<its pane>: "close" runs the send command as a review
  -- close does (the real one: deliver.sh), "quit" exits
  write(
    bin .. "/nvim",
    ([[#!/bin/sh
f=%s/"$TMUX_PANE"
while :; do
  if [ -e "$f" ]; then
    order="$(cat "$f")"; rm -f "$f"
    case "$order" in
      close) ANNODIFF_SEND_REASON=close ANNODIFF_ANNOTATION_COUNT=0 sh -c "$ANNODIFF_SEND_COMMAND" </dev/null ;;
      quit) exit 0 ;;
    esac
  fi
  sleep 0.05
done
]]):format(ctl),
    "755"
  )
  local sock = "annodiff-test-" .. vim.fn.getpid()
  local server_env = { PATH = bin .. ":" .. vim.env.PATH, TMUX = "", TMUX_PANE = "" }
  local function T(args)
    return run(vim.list_extend({ "tmux", "-L", sock }, args), { env = server_env })
  end
  local started = T({
    "-f", "/dev/null", "new-session", "-d", "-s", "t", "-x", "200", "-y", "50",
    "stty -echo; exec cat > " .. vim.fn.shellescape(pasted),
    ";", "set", "-g", "default-shell", "/bin/sh",
  })
  assert(started.code == 0, started.stderr)
  local claude = vim.trim(T({ "display-message", "-p", "-t", "t:0", "#{pane_id}" }).stdout)
  local socket_path = vim.trim(T({ "display-message", "-p", "#{socket_path}" }).stdout)
  local env = { PATH = server_env.PATH, TMUX = socket_path .. ",0,0", TMUX_PANE = claude, CLAUDE_PLUGIN_DATA = "" }

  local function open_doc(name)
    return run({ open, "--doc", docs .. "/" .. name }, { env = env })
  end
  local function option(name)
    return vim.trim(T({ "show-options", "-pqv", "-t", claude, name }).stdout)
  end
  local function windows()
    return #vim.split(vim.trim(T({ "list-windows", "-t", "t", "-F", "#{window_id}" }).stdout), "\n")
  end
  -- the review pane holding the lock, once it has started
  local function attached(not_pane)
    local p
    vim.wait(5000, function()
      p = option("@annodiff_review_pane")
      return p ~= "" and p ~= not_pane
    end, 20)
    assert(p ~= "" and p ~= not_pane, "the review never attached to the lock")
    return p
  end
  local function order(pane, what)
    write(ctl .. "/" .. pane, what)
  end
  local function claude_saw(text)
    vim.wait(5000, function()
      return (read(pasted) or ""):find(text, 1, true) ~= nil
    end, 20)
    return read(pasted) or ""
  end

  it("a second open is refused while the first review is open; the close frees the pane", function()
    local res = open_doc("a.md")
    eq(0, res.code, res.stderr)
    local a = attached()
    eq("a.md", option("@annodiff_review"))
    eq(2, windows())

    res = open_doc("b.md")
    eq(1, res.code)
    eq(1, res.stderr:find("error: a review opened from this pane is still open (a.md, pane " .. a .. ")", 1, true), res.stderr)
    truthy(res.stderr:find("wait for its close message", 1, true), res.stderr)
    eq(2, windows(), "nothing opened over the first review")
    -- no-args (which would ask which diff) is refused too, before asking
    res = run({ open }, { env = env, cwd = root })
    eq(1, res.code)
    eq(nil, res.stdout:find("needs_ask", 1, true))

    order(a, "close")
    local seen = claude_saw("review closed (from /annodiff nvim, review: a.md)")
    truthy(seen:find("annodiff review closed (from /annodiff nvim, review: a.md): no annotations", 1, true), seen)
    eq("", option("@annodiff_review"), "a close frees the lock, even while Neovim stays open")

    res = open_doc("b.md")
    eq(0, res.code, res.stderr)
    local b = attached(a)
    eq("b.md", option("@annodiff_review"))

    -- the first review's Neovim quits late: it must not free b's lock
    order(a, "quit")
    vim.wait(3000, function()
      return windows() == 2
    end, 20)
    eq(2, windows(), "a's window is gone")
    eq(b, option("@annodiff_review_pane"))
    res = open_doc("c.md")
    eq(1, res.code)
    truthy(res.stderr:find("(b.md, pane " .. b .. ")", 1, true), res.stderr)

    -- Neovim exiting with no close frees it too, and says which review it was
    order(b, "quit")
    seen = claude_saw("annodiff exited (from /annodiff nvim, review: b.md)")
    truthy(seen:find("annodiff exited (from /annodiff nvim, review: b.md) without closing a review", 1, true), seen)
    eq("", option("@annodiff_review"))
  end)

  it("a lock whose review pane is gone, or that never attached, is stale", function()
    local res = open_doc("c.md")
    eq(0, res.code, res.stderr)
    local c = attached()
    T({ "kill-pane", "-t", c }) -- killed, so nothing ran deliver.sh
    eq("c.md", option("@annodiff_review"))
    res = open_doc("a.md")
    eq(0, res.code, res.stderr)
    local a = attached(c)
    order(a, "quit")
    vim.wait(3000, function()
      return option("@annodiff_review") == ""
    end, 20)

    -- taken but never attached (the launch failed): busy for the grace period, then stale
    eq(0, run({ lock, "take", claude, "x.md" }, { env = env }).code)
    res = run({ lock, "check", claude }, { env = env })
    eq(1, res.code)
    eq("x.md\tstarting\n", res.stdout)
    res = run({ lock, "check", claude }, { env = vim.tbl_extend("force", env, { ANNODIFF_LOCK_GRACE = "0" }) })
    eq(0, res.code)
    eq("", option("@annodiff_review"), "check clears a stale lock")
  end)

  T({ "kill-server" })
end)

describe("deliver.sh: portability and failures", function()
  local script = root .. "/skills/annodiff/scripts/deliver.sh"
  local real_mktemp = vim.fn.exepath("mktemp")
  -- stub tmux: logs argv, and load-buffer's stdin (the message)
  local bin = vim.fn.tempname()
  local log = bin .. "/tmux.log"
  write(
    bin .. "/tmux",
    ([[#!/bin/sh
printf '%%s\n' "$*" >> %s
[ "$1" = load-buffer ] && cat >> %s
exit 0
]]):format(vim.fn.shellescape(log), vim.fn.shellescape(log)),
    "755"
  )
  -- GNU coreutils mktemp (Linux): a template needs at least three X's, so the macOS-only
  -- `mktemp -t prefix` fails there. Mimic that on every platform.
  write(
    bin .. "/mktemp",
    ([[#!/bin/sh
for a in "$@"; do last="$a"; done
case "$last" in
  *XXX*) exec %s "$@" ;;
  *) echo "mktemp: too few X's in template '$last'" >&2; exit 1 ;;
esac
]]):format(vim.fn.shellescape(real_mktemp)),
    "755"
  )
  local env = { PATH = bin .. ":" .. vim.env.PATH }
  local note = "## x.md:1 ( )\ntest\n"

  it("pastes the annotations into the pane and submits them, with GNU mktemp too", function()
    os.remove(log)
    local res = run({ script, "%99" }, { env = env, stdin = note })
    eq(0, res.code, res.stderr)
    eq(
      table.concat({
        "load-buffer -b annodiff -",
        "annodiff annotations (from /annodiff nvim):",
        "",
        "## x.md:1 ( )",
        "test",
        "paste-buffer -b annodiff -p -d -t %99",
        "send-keys -t %99 Enter",
        "",
      }, "\n"),
      read(log)
    )
  end)

  it("sends nothing for an empty snapshot", function()
    os.remove(log)
    local res = run({ script, "%99" }, { env = env, stdin = "" })
    eq(0, res.code, res.stderr)
    eq(nil, read(log))
  end)

  it("fails (so annodiff says send failed, not sent) when it cannot make its temp file", function()
    os.remove(log)
    write(bin .. "/fail/mktemp", "#!/bin/sh\necho 'mktemp: nope' >&2\nexit 1\n", "755")
    local res = run({ script, "%99" }, { env = { PATH = bin .. "/fail:" .. env.PATH }, stdin = note })
    eq(1, res.code)
    truthy(res.stderr:find("deliver: mktemp failed", 1, true), res.stderr)
    eq(nil, read(log), "tmux never called")
  end)

  it("fails when tmux cannot paste", function()
    write(bin .. "/fail2/tmux", "#!/bin/sh\necho \"can't find pane: %99\" >&2\nexit 1\n", "755")
    local res = run({ script, "%99" }, { env = { PATH = bin .. "/fail2:" .. env.PATH }, stdin = note })
    eq(1, res.code)
  end)
end)

describe("deliver.sh", function()
  local deliver = root .. "/skills/annodiff/scripts/deliver.sh"
  -- stub tmux: load-buffer keeps stdin as the pasted text; every call logs its argv
  local bin = vim.fn.tempname()
  local pasted, log = bin .. "/pasted.txt", bin .. "/tmux.log"
  write(
    bin .. "/tmux",
    ([[#!/bin/sh
[ "$1" = load-buffer ] && cat > %s
printf '%%s\n' "$*" >> %s
]]):format(vim.fn.shellescape(pasted), vim.fn.shellescape(log)),
    "755"
  )
  local nowhere = vim.fn.tempname() -- not a repo: read-latest.sh (exit) sees no checkout's notes
  vim.fn.mkdir(nowhere, "p")
  local function deliver_with(stdin, extra)
    os.remove(pasted)
    os.remove(log)
    -- TMUX_PANE: not the review's pane (as when the tests run inside tmux), so no lock calls
    local env = vim.tbl_extend("force", { PATH = bin .. ":" .. vim.env.PATH, TMUX_PANE = "" }, extra or {})
    local res = run({ deliver, "%7" }, { env = env, stdin = stdin, cwd = nowhere })
    eq(0, res.code, res.stderr)
    return read(pasted), read(log) or ""
  end

  it("a send pastes the notes under the usual header and submits", function()
    local text, calls = deliver_with("## a.txt:1 (+)\nfix\n", { ANNODIFF_SEND_REASON = "send", ANNODIFF_ANNOTATION_COUNT = "1" })
    eq("annodiff annotations (from /annodiff nvim):\n\n## a.txt:1 (+)\nfix\n", text)
    truthy(calls:find("paste-buffer -b annodiff -p -d -t %7", 1, true), calls)
    truthy(calls:find("send-keys -t %7 Enter", 1, true), calls)
  end)

  it("an empty send (no reason: an older annodiff) pastes nothing", function()
    local text, calls = deliver_with("", {})
    eq(nil, text)
    eq("", calls)
  end)

  it("closing with no annotations tells the agent there are no edits or suggestions", function()
    local text = deliver_with("", { ANNODIFF_SEND_REASON = "close", ANNODIFF_ANNOTATION_COUNT = "0" })
    eq(
      "annodiff review closed (from /annodiff nvim): no annotations, so no edits or suggestions. The review is done; nothing to change.\n",
      text
    )
  end)

  it("closing with nothing new since the last send says the sent set is final", function()
    local text = deliver_with("", { ANNODIFF_SEND_REASON = "close", ANNODIFF_ANNOTATION_COUNT = "3" })
    truthy(text:find("^annodiff review closed .*nothing new since the last send; the 3 annotation%(s%) already sent are the final set"), text)
  end)

  it("every header names the review when open.sh gave its label", function()
    local text = deliver_with("## a.txt:1 (+)\nfix\n", { ANNODIFF_REVIEW_LABEL = "--base main" })
    eq("annodiff annotations (from /annodiff nvim, review: --base main):\n\n## a.txt:1 (+)\nfix\n", text)
    text = deliver_with("", { ANNODIFF_SEND_REASON = "close", ANNODIFF_REVIEW_LABEL = "plan.md" })
    truthy(text:find("^annodiff review closed %(from /annodiff nvim, review: plan%.md%): no annotations"), text)
    text = deliver_with("", { ANNODIFF_SEND_REASON = "exit", ANNODIFF_REVIEW_LABEL = "HEAD~1" })
    truthy(text:find("^annodiff exited %(from /annodiff nvim, review: HEAD~1%) without"), text)
  end)

  it("closing with unsent notes sends them as the final set", function()
    local text = deliver_with("## a.txt:1 (+)\nfix\n", { ANNODIFF_SEND_REASON = "close", ANNODIFF_ANNOTATION_COUNT = "1" })
    eq("annodiff annotations (from /annodiff nvim; the review is closed, this is the final set):\n\n## a.txt:1 (+)\nfix\n", text)
  end)

  it("Neovim exiting after a close says nothing more; exiting without one says so", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local mark = dir .. "/closed"
    deliver_with("", { ANNODIFF_SEND_REASON = "close", ANNODIFF_CLOSED_MARK = mark })
    truthy(vim.uv.fs_stat(mark), "close leaves the mark")
    local text, calls = deliver_with("", { ANNODIFF_SEND_REASON = "exit", ANNODIFF_CLOSED_MARK = mark })
    eq(nil, text)
    eq("", calls)
    eq(nil, vim.uv.fs_stat(dir), "the mark and its directory are gone")

    text = deliver_with("", { ANNODIFF_SEND_REASON = "exit", ANNODIFF_CLOSED_MARK = vim.fn.tempname() .. "/closed" })
    truthy(text:find("^annodiff exited %(from /annodiff nvim%) without closing a review"), text)
    truthy(text:find("no edits or suggestions", 1, true), text)
  end)

  it("exit waits for a close still on its way (the TUI gone, its server finishing)", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local mark = dir .. "/closed"
    vim.system({ "sh", "-c", "sleep 0.5; : > " .. vim.fn.shellescape(mark) })
    local text, calls = deliver_with("", { ANNODIFF_SEND_REASON = "exit", ANNODIFF_CLOSED_MARK = mark })
    eq(nil, text, "the close reported it; exit adds nothing")
    eq("", calls)
  end)

  it("Neovim killed before a close: notes saved since the review opened are pasted, older ones are not", function()
    local state = vim.fn.tempname()
    local notes = state .. "/nvim/annodiff/docs/0123456789ab-turn.md/annotations.md"
    local function exit_with_notes(note_time)
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      run({ "touch", "-t", "202501010000", dir }) -- the review opened then
      write(notes, "## turn.md:3 ( )\nsaved, never sent\n")
      run({ "touch", "-t", note_time, notes })
      local env = { ANNODIFF_SEND_REASON = "exit", ANNODIFF_CLOSED_MARK = dir .. "/closed" }
      env.XDG_STATE_HOME, env.REVDIFF_HISTORY_DIR = state, vim.fn.tempname()
      return deliver_with("", env), dir
    end
    local text, dir = exit_with_notes("202601010000")
    eq(
      "annodiff exited (from /annodiff nvim) before the review closed (Neovim was killed?); these notes were saved during it but never sent:\n\nsource: "
        .. notes
        .. "\n\n## turn.md:3 ( )\nsaved, never sent\n",
      text
    )
    eq(nil, vim.uv.fs_stat(dir), "mark directory removed")
    text = exit_with_notes("202401010000") -- from an earlier review
    truthy(text:find("no edits or suggestions", 1, true), text)
  end)
end)

describe("read-latest.sh", function()
  local script = root .. "/skills/annodiff/scripts/read-latest.sh"

  it("prints the newest of the export and this checkout's history entries", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    local hist = vim.fn.tempname()
    local dir = hist .. "/" .. vim.fs.basename(repo)
    write(dir .. "/old.md", "path: " .. repo .. "\n\n## Annotations\n## a.txt:1 (+)\nold\n")
    write(dir .. "/other.md", "path: /somewhere/else\n\n## a.txt:1 (+)\nnot ours\n")
    local env = { REVDIFF_HISTORY_DIR = hist }
    local res = run({ script }, { cwd = repo, env = env })
    truthy(res.stdout:find("source: " .. dir .. "/old.md", 1, true), res.stdout)

    run({ "touch", "-t", "202001010000", dir .. "/old.md" })
    write(repo .. "/.git/annodiff/annotations.md", "## a.txt:1 (+)\nnewest\n")
    res = run({ script }, { cwd = repo, env = env })
    truthy(res.stdout:find("newest", 1, true), res.stdout)
    eq(nil, res.stdout:find("not ours", 1, true))
  end)

  it("prints nothing when nothing was saved", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    local env = { REVDIFF_HISTORY_DIR = vim.fn.tempname(), XDG_STATE_HOME = vim.fn.tempname() }
    local res = run({ script }, { cwd = repo, env = env })
    eq(0, res.code)
    eq("", res.stdout)
  end)

  -- RIKER-0255: a last-turn review (open.sh --doc on a scratch .md outside any repo)
  -- keeps its notes under Neovim's state dir; read-latest.sh used to miss them.
  it("finds notes on a document reviewed outside any repo, under Neovim's state dir", function()
    local repo = repo_with({ ["a.txt"] = "a\n" })
    local state = vim.fn.tempname()
    local docs = state .. "/nvim/annodiff/docs"
    write(docs .. "/0123456789ab-grill-round.md/annotations.md", "## grill-round.md:3 ( )\nno need\n")
    write(docs .. "/ba9876543210-empty.md/annotations.md", "") -- every note deleted: not a candidate
    run({ "touch", "-t", "203001010000", docs .. "/ba9876543210-empty.md/annotations.md" })
    local env = { REVDIFF_HISTORY_DIR = vim.fn.tempname(), XDG_STATE_HOME = state }
    for _, cwd in ipairs({ repo, vim.fs.dirname(state) }) do -- the session's repo, or no repo at all
      local res = run({ script }, { cwd = cwd, env = env })
      eq("source: " .. docs .. "/0123456789ab-grill-round.md/annotations.md\n\n## grill-round.md:3 ( )\nno need\n", res.stdout, cwd)
    end

    -- newest wins against this repo's own export; $NVIM_APPNAME moves the state dir
    run({ "touch", "-t", "202001010000", docs .. "/0123456789ab-grill-round.md/annotations.md" })
    write(repo .. "/.git/annodiff/annotations.md", "## a.txt:1 (+)\nrepo note\n")
    local res = run({ script }, { cwd = repo, env = env })
    truthy(res.stdout:find("repo note", 1, true), res.stdout)
    write(state .. "/other/annodiff/docs/x-n.md/annotations.md", "## n.md:1 ( )\nappname note\n")
    res = run({ script }, { cwd = repo, env = vim.tbl_extend("force", env, { NVIM_APPNAME = "other" }) })
    truthy(res.stdout:find("appname note", 1, true), res.stdout)
  end)
end)

describe("plan-review-hook.py", function()
  local plugin = root .. "/plugins/annodiff-planning"
  local hook = plugin .. "/scripts/plan-review-hook.py"
  -- The fake launcher (user override layer) records the diff it was shown, then acts
  -- out the review from $FAKE_REVIEW: "note" annotates, "edit" edits plan.md,
  -- "fail" breaks, anything else quits clean.
  local data = vim.fn.tempname()
  local seen = data .. "/seen.diff"
  write(
    data .. "/scripts/launch-plan-review.sh",
    ([[#!/bin/sh
repo="$1"
git -C "$repo" diff HEAD > %s
case "$FAKE_REVIEW" in
  note) printf '## plan.md:2 (+)\nsplit this step\n'; exit 10 ;;
  edit) printf 'step one\nstep 2, edited\n' > "$repo/plan.md"; exit 0 ;;
  fail) echo "error: not inside tmux" >&2; exit 2 ;;
esac
exit 0
]]):format(vim.fn.shellescape(seen)),
    "755"
  )
  local plans = vim.fn.tempname()
  vim.fn.mkdir(plans, "p")
  local env = { CLAUDE_PLUGIN_ROOT = plugin, CLAUDE_PLUGIN_DATA = data, ANNODIFF_PLAN_DIR = plans }

  local function exit_plan(session, plan, review)
    local event = vim.json.encode({ session_id = session, tool_name = "ExitPlanMode", tool_input = { plan = plan } })
    return run({ "python3", hook }, { stdin = event, env = vim.tbl_extend("force", env, { FAKE_REVIEW = review }) })
  end

  it("annotations deny ExitPlanMode with the notes as the reason", function()
    local res = exit_plan("s1", "step one\nstep two\n", "note")
    eq(2, res.code)
    truthy(res.stderr:find("## plan.md:2 (+)\nsplit this step", 1, true), res.stderr)
    truthy(res.stderr:find("call ExitPlanMode again", 1, true), res.stderr)
    -- the first round shows the whole plan as added
    truthy(read(seen):find("+step one\n+step two\n", 1, true), read(seen))
  end)

  it("the next round shows only what changed since the last revision", function()
    local res = exit_plan("s1", "step one\nstep 2a\nstep 2b\n", "clean")
    eq(0, res.code, res.stderr)
    local diff = read(seen)
    truthy(diff:find("-step two\n+step 2a\n+step 2b\n", 1, true), diff)
    truthy(diff:find(" step one", 1, true), diff)
    eq("ask", vim.json.decode(res.stdout).hookSpecificOutput.permissionDecision)
    eq(0, vim.fn.isdirectory(plans .. "/annodiff-plan-s1"), "a clean review drops the session's plan repo")
  end)

  it("edits to plan.md go back as a diff", function()
    local res = exit_plan("s2", "step one\nstep two\n", "edit")
    eq(2, res.code)
    truthy(res.stderr:find("-step two\n+step 2, edited\n", 1, true), res.stderr)
    -- and the next round diffs against what Claude submitted, not the user's edit
    exit_plan("s2", "step one\nstep two\nstep three\n", "clean")
    truthy(read(seen):find(" step two\n+step three\n", 1, true), read(seen))
  end)

  it("sessions do not share a chain", function()
    exit_plan("s3", "alpha\n", "note")
    exit_plan("s4", "beta\n", "clean")
    truthy(read(seen):find("+beta\n", 1, true), read(seen))
    eq(nil, read(seen):find("alpha", 1, true))
  end)

  it("a launcher failure fails open with the reason", function()
    local res = exit_plan("s5", "x\n", "fail")
    eq(0, res.code)
    local reason = vim.json.decode(res.stdout).hookSpecificOutput.permissionDecisionReason
    eq("plan review launcher exited 2: error: not inside tmux; plan not reviewed this round", reason)
  end)

  it("a session id cannot steer the plan repo out of its directory", function()
    exit_plan("../../etc", "x\n", "note")
    eq(1, vim.fn.isdirectory(plans .. "/annodiff-plan-etc"))
  end)
end)

describe("launch-plan-review.sh", function()
  local launcher = root .. "/plugins/annodiff-planning/scripts/launch-plan-review.sh"
  -- stub tmux: new-window runs the command at once (as the review would) and prints a
  -- pane id that list-panes never reports, so the wait ends when the command does
  local bin = vim.fn.tempname()
  write(
    bin .. "/tmux",
    [[#!/bin/sh
case "$1" in
  display-message) echo ;;
  new-window)
    shift
    while [ $# -gt 1 ]; do
      if [ "$1" = -c ]; then cd "$2" || exit 1; shift; fi
      shift
    done
    sh -c "$1" >/dev/null
    echo %1 ;;
esac
]],
    "755"
  )
  -- stub nvim: logs its argv and env, writes an export like a review with one note
  write(
    bin .. "/nvim",
    [[#!/bin/sh
printf '%s\n' "$*" > .git/nvim-args
env > .git/nvim-env
if [ -n "$NOTE" ]; then mkdir -p .git/annodiff; printf '## plan.md:1 (+)\nnote\n' > .git/annodiff/annotations.md; fi
]],
    "755"
  )
  local env = {
    PATH = bin .. ":" .. vim.env.PATH,
    TMUX = "/tmp/stub,1,0",
    TMUX_PANE = "%99",
    ANNODIFF_SEND_COMMAND = "should-not-run",
  }

  it("exits 10 with the annotations, after loading this checkout's annodiff", function()
    local repo = repo_with({ ["plan.md"] = "" })
    local res = run({ launcher, repo }, { env = vim.tbl_extend("force", env, { NOTE = "1" }) })
    eq(10, res.code, res.stderr)
    eq("## plan.md:1 (+)\nnote\n", res.stdout)
    local args = read(repo .. "/.git/nvim-args")
    truthy(args:find("set rtp^=" .. root .. " | runtime plugin/annodiff.lua | Annodiff --doc plan.md HEAD", 1, true), args)
    eq(nil, read(repo .. "/.git/nvim-env"):find("ANNODIFF_SEND_COMMAND", 1, true), "plan notes never go to the send command")
  end)

  it("exits 0 with nothing when the review had no notes, even if an old export was there", function()
    local repo = repo_with({ ["plan.md"] = "" })
    write(repo .. "/.git/annodiff/annotations.md", "## stale\n")
    local res = run({ launcher, repo }, { env = env })
    eq(0, res.code, res.stderr)
    eq("", res.stdout)
  end)
end)
