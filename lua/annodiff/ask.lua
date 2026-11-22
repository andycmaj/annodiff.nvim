-- Ask an agent inline (port of revdiff feat/ask-agent). <localleader>c on a
-- line or range (<localleader>C for the file) asks a read-only `claude -p`;
-- the answer streams into a preview under the line. On a line that already
-- has a thread, <localleader>c opens the full thread, where you can follow
-- up, promote the answer to an annotation, cancel, or delete.
local annotate = require("annodiff.annotate")
local claude = require("annodiff.agent.claude")
local config = require("annodiff.config")
local hunks = require("annodiff.hunks")
local threads_mod = require("annodiff.threads")

local api = vim.api
local M = {}

M.PREVIEW_ROWS = 4 -- answer rows shown inline; the thread window shows the rest
M.HUNK_CONTEXT = 3 -- context lines around the asked-about change
M.MAX_HUNK_LINES = 200 -- cap on the excerpt sent with a question

local function notify(msg, level)
  vim.notify("annodiff: " .. msg, level or vim.log.levels.INFO)
end

function M.define_highlights()
  local links = {
    AnnodiffThread = "DiagnosticVirtualTextHint",
    AnnodiffThreadSign = "DiagnosticSignHint",
    AnnodiffThreadQuestion = "DiagnosticHint",
    AnnodiffThreadError = "DiagnosticError",
    AnnodiffThreadDim = "Comment",
  }
  for group, link in pairs(links) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

---@param s annodiff.Session
function M.init(s)
  s.threads = threads_mod.new()
  s.jobs = {}
  s.job_seq = {}
end

local function agent_cfg()
  local a = config.options.agent
  return type(a) == "table" and a or {}
end

function M.enabled()
  local a = config.options.agent
  return a ~= false and not (type(a) == "table" and a.enabled == false)
end

local function entry(s)
  return s.current and s.files[s.current]
end

-- Prompt ----------------------------------------------------------------------

--- What the review covers, in the words revdiff uses.
---@param spec annodiff.Spec
function M.scope(spec)
  if spec.left.kind == "rev" and spec.right.kind == "rev" then
    return "git diff of range " .. spec.label
  elseif spec.right.kind == "index" then
    return "git staged changes" .. (spec.ref and (" against " .. spec.ref) or "")
  elseif spec.left.kind == "rev" then
    return "git diff of the working tree against " .. spec.left.rev
  end
  return "git uncommitted working-tree changes"
end

--- Unified view of the whole file: { mark = " "|"-"|"+", text, old, new }.
---@param old string[]
---@param new string[]
---@param h annodiff.Hunk[]
function M.unified(old, new, h)
  local out = {}
  local oi, ni = 1, 1
  local function context_until(old_stop)
    while oi < old_stop and oi <= #old do
      table.insert(out, { mark = " ", text = new[ni] or old[oi], old = oi, new = ni })
      oi, ni = oi + 1, ni + 1
    end
  end
  for _, hk in ipairs(h) do
    local sa, ca, sb, cb = hk[1], hk[2], hk[3], hk[4]
    context_until(ca > 0 and sa or sa + 1)
    for i = 0, ca - 1 do
      table.insert(out, { mark = "-", text = old[sa + i], old = sa + i })
    end
    for i = 0, cb - 1 do
      table.insert(out, { mark = "+", text = new[sb + i], new = sb + i })
    end
    oi = (ca > 0 and sa + ca or sa + 1)
    ni = (cb > 0 and sb + cb or sb + 1)
  end
  context_until(#old + 1)
  return out
end

--- revdiff agentExcerpt: the changed block around the line plus context, line marked with ">".
function M.excerpt(old, new, h, type, line)
  local u = M.unified(old, new, h)
  local idx
  for i, e in ipairs(u) do
    if (type == "-" and e.mark == "-" and e.old == line) or (type ~= "-" and e.mark == type and e.new == line) then
      idx = i
      break
    end
  end
  if not idx then
    return ""
  end
  local function changed(i)
    return u[i] and u[i].mark ~= " "
  end
  local lo, hi = idx, idx
  if changed(idx) then
    while changed(lo - 1) and idx - lo < M.MAX_HUNK_LINES / 2 do
      lo = lo - 1
    end
    while changed(hi + 1) and hi - idx < M.MAX_HUNK_LINES / 2 do
      hi = hi + 1
    end
  end
  for _ = 1, M.HUNK_CONTEXT do
    if u[lo - 1] then
      lo = lo - 1
    end
    if u[hi + 1] then
      hi = hi + 1
    end
  end
  local lines = {}
  for i = lo, hi do
    table.insert(lines, (i == idx and ">" or " ") .. u[i].mark .. (u[i].text or ""))
  end
  return table.concat(lines, "\n") .. "\n"
end

local type_names = { ["+"] = "added line", ["-"] = "removed line", [" "] = "unchanged line" }

--- Prompt for a first question (revdiff agentPrompt), or a follow-up.
---@param s annodiff.Session
---@param t annodiff.Thread
---@param question string
---@param follow_up boolean
function M.prompt(s, t, question, follow_up)
  local where = t.line > 0 and ("%s line %d"):format(t.file, t.line) or t.file
  if follow_up then
    return ("Follow-up question about %s:\n\n%s\n"):format(where, question)
  end
  local out = { "I am reviewing a code change in annodiff and have a question about it.", "" }
  table.insert(out, "Review: " .. M.scope(s.spec))
  table.insert(out, "File: " .. t.file)
  local e = entry(s)
  if e and e.path == t.file and e.old_path and e.old_path ~= t.file then
    table.insert(out, "Renamed from: " .. e.old_path)
  end
  if t.line == 0 then
    table.insert(out, "Asking about: the whole file")
  else
    local span = t.end_line and t.end_line > t.line and ("lines %d-%d"):format(t.line, t.end_line)
      or ("line %d"):format(t.line)
    table.insert(out, ("Asking about: %s (%s)"):format(span, type_names[t.type] or t.type))
    if e and e.path == t.file and vim.wo[s.win_old].diff then
      local old, new = annotate.lines_of(s.win_old), annotate.lines_of(s.win_new)
      local ex = M.excerpt(old, new, hunks.compute(old, new), t.type, t.line)
      if ex ~= "" then
        table.insert(out, "")
        table.insert(out, "Diff around that line (the line asked about is marked with >):")
        table.insert(out, "```diff")
        table.insert(out, (ex:gsub("\n$", "")))
        table.insert(out, "```")
      end
    end
  end
  table.insert(out, "")
  table.insert(out, "Question: " .. question)
  return table.concat(out, "\n") .. "\n"
end

-- Running -------------------------------------------------------------------

local render_pending = {}

--- Redraw the open file's inline rows soon (streaming deltas arrive fast).
local function schedule_render(s)
  if render_pending[s] then
    return
  end
  render_pending[s] = true
  vim.defer_fn(function()
    render_pending[s] = nil
    if s.closing or not api.nvim_win_is_valid(s.win_new) then
      return
    end
    annotate.render(s)
  end, 30)
end

local function refresh_tree(s)
  if not s.closing then
    require("annodiff.view").render_tree(s)
  end
end

---@param s annodiff.Session
---@param t annodiff.Thread
---@param question string
---@param follow_up boolean
local function start(s, t, question, follow_up)
  local cfg = agent_cfg()
  local resume = follow_up and t.session_ok and t.session_id ~= nil
  local session_id = resume and t.session_id or claude.uuid()
  local req = {
    prompt = M.prompt(s, t, question, resume),
    session_id = session_id,
    resume = resume,
    parent_session = not resume and claude.parent_session() or nil,
  }
  t.session_id = session_id
  s.job_seq[t.id] = (s.job_seq[t.id] or 0) + 1
  local seq = s.job_seq[t.id]
  local job, err = claude.ask(cfg, req, s.root, function(ev)
    if s.job_seq[t.id] ~= seq or not s.threads:by(t.id) then
      return -- superseded or deleted
    end
    s.threads:apply(t.id, ev)
    if ev.kind == "done" then
      t.session_ok = true
    end
    if ev.kind == "done" or ev.kind == "failed" then
      s.jobs[t.id] = nil
      refresh_tree(s)
    end
    local e = entry(s)
    if e and e.path == t.file then
      schedule_render(s)
    end
    M.update_overlay(s, t)
  end)
  if not job then
    s.threads:apply(t.id, { kind = "failed", text = err })
  else
    s.jobs[t.id] = job
  end
  refresh_tree(s)
  annotate.render(s)
end

---@param s annodiff.Session
---@param anchor {file: string, line: integer, end_line?: integer, type: string}
local function ask_new(s, anchor)
  local title = "ask agent: " .. threads_mod.heading(anchor)
  annotate.input(title, "", function(text)
    if not text or text == "" then
      return
    end
    local t = s.threads:ask(anchor, text)
    start(s, t, text, false)
  end)
end

--- \c: ask about the cursor line / visual range, or open its thread.
---@param s annodiff.Session
---@param range? {[1]: integer, [2]: integer}
function M.ask(s, range)
  if not M.enabled() then
    notify("agent is off (setup({ agent = ... }))", vim.log.levels.WARN)
    return
  end
  local win = api.nvim_get_current_win()
  local side = annotate.side_of(s, win)
  if not side or not entry(s) then
    notify("ask from a diff window", vim.log.levels.WARN)
    return
  end
  if not vim.wo[win].diff then
    return M.ask_file(s)
  end
  local rec = annotate.target(s, win, side, range)
  local existing = s.threads:get(rec.file, rec.line, rec.type)
  if existing then
    return M.open_thread(s, existing)
  end
  ask_new(s, { file = rec.file, line = rec.line, end_line = rec.end_line, type = rec.type })
end

--- \C: ask about the whole file, or open its thread.
function M.ask_file(s)
  if not M.enabled() then
    notify("agent is off (setup({ agent = ... }))", vim.log.levels.WARN)
    return
  end
  local e = entry(s)
  if not e then
    return
  end
  local existing = s.threads:get(e.path, 0, "")
  if existing then
    return M.open_thread(s, existing)
  end
  ask_new(s, { file = e.path, line = 0, type = "" })
end

function M.follow_up(s, t)
  if t.status == "streaming" then
    notify("agent still answering")
    return
  end
  if t.status == "failed" then
    local retried = s.threads:retry(t.id)
    if retried then
      start(s, retried, retried.turns[#retried.turns].question, t.session_ok == true)
    end
    return
  end
  annotate.input("follow up: " .. threads_mod.heading(t), "", function(text)
    if not text or text == "" then
      return
    end
    s.threads:ask(t, text)
    start(s, t, text, true)
  end)
end

function M.cancel(s, t)
  local job = s.jobs[t.id]
  if job then
    job.cancel()
  end
end

function M.delete(s, t)
  M.cancel(s, t)
  s.job_seq[t.id] = (s.job_seq[t.id] or 0) + 1
  s.jobs[t.id] = nil
  s.threads:delete(t.id)
  refresh_tree(s)
  annotate.render(s)
end

--- y: turn the last answer into an annotation at the same anchor. An existing
--- annotation there is kept above the answer, so nothing is overwritten unseen.
function M.promote(s, t)
  local answer = vim.trim(t.turns[#t.turns] and t.turns[#t.turns].answer or "")
  if answer == "" then
    notify("no answer to promote yet")
    return
  end
  local existing = s.store:find(t.file, t.line, t.type)
  local seed = existing and (existing.text .. "\n\n" .. answer) or answer
  annotate.input("annotate: " .. threads_mod.heading(t), seed, function(text)
    if not text or text == "" then
      return
    end
    local rec = { file = t.file, line = t.line, end_line = t.end_line, type = t.type, text = text }
    if t.line > 0 then
      local win = t.type == "-" and s.win_old or s.win_new
      local buf = api.nvim_win_get_buf(win)
      rec.anchor = api.nvim_buf_get_lines(buf, t.line - 1, t.line, false)[1]
    end
    s.store:add(rec)
    annotate.changed(s)
  end)
end

--- Cancel everything in flight (review closing).
function M.shutdown(s)
  for id, job in pairs(s.jobs or {}) do
    s.job_seq[id] = (s.job_seq[id] or 0) + 1
    job.cancel()
  end
  s.jobs = {}
  M.close_overlay(s)
end

--- Drop threads whose file left the review (refresh).
function M.retain(s)
  local known = {}
  for _, e in ipairs(s.files) do
    known[e.path] = true
  end
  local dropped = 0
  for id, t in pairs(vim.deepcopy(s.threads.by_id, true)) do
    if not known[t.file] then
      M.cancel(s, t)
      s.threads:delete(id)
      dropped = dropped + 1
    end
  end
  return dropped
end

-- Inline preview ----------------------------------------------------------------

local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    if para == "" then
      table.insert(out, "")
    else
      local line = ""
      for word in para:gmatch("%S+") do
        if line == "" then
          line = word
        elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
          line = line .. " " .. word
        else
          table.insert(out, line)
          line = word
        end
        while vim.fn.strdisplaywidth(line) > width do
          table.insert(out, vim.fn.strcharpart(line, 0, width))
          line = vim.fn.strcharpart(line, width)
        end
      end
      table.insert(out, line)
    end
  end
  while out[#out] == "" do
    table.remove(out)
  end
  return out
end

local function open_key()
  local k = config.options.keymaps.ask
  k = type(k) == "table" and k[1] or k
  return type(k) == "string" and k:gsub("<localleader>", vim.g.maplocalleader or "\\") or "the ask key"
end

--- Rows shown under the line (revdiff threadVisualRows).
---@param t annodiff.Thread
---@param width integer
function M.preview(t, width)
  local rows = {}
  local turn = t.turns[#t.turns]
  local q = vim.split(vim.trim(turn.question), "\n", { plain = true })[1]
  table.insert(rows, { { "  ⟢ ", "AnnodiffThreadSign" }, { "Q: " .. q, "AnnodiffThreadQuestion" } })
  local answer = wrap(vim.trim(turn.answer), math.max(20, width))
  if t.status == "failed" then
    table.insert(rows, { { "    ✗ ", "AnnodiffThreadError" }, { t.err or "failed", "AnnodiffThreadError" } })
    return rows
  end
  if #answer == 0 then
    local note = t.status == "streaming" and (t.activity or "…") or "(no answer)"
    table.insert(rows, { { "    ", "AnnodiffThread" }, { note, "AnnodiffThreadDim" } })
    return rows
  end
  local first = math.max(1, #answer - M.PREVIEW_ROWS + 1)
  for i = first, #answer do
    table.insert(rows, { { "    ", "AnnodiffThread" }, { answer[i], "AnnodiffThread" } })
  end
  if t.status == "streaming" and t.activity then
    table.insert(rows, { { "    ", "AnnodiffThread" }, { t.activity, "AnnodiffThreadDim" } })
  end
  if first > 1 then
    table.insert(rows, {
      { "    ", "AnnodiffThread" },
      { ("+%d more · %s to open"):format(first - 1, open_key()), "AnnodiffThreadDim" },
    })
  end
  return rows
end

--- Queue thread previews for the open file (annotate.render draws them after
--- the annotations on the same row).
---@param s annodiff.Session
---@param show fun(buf: integer, row: integer, above: boolean, rows: table, side: string, line: integer)
function M.render(s, show)
  local e = entry(s)
  if not e then
    return
  end
  for _, t in ipairs(s.threads:for_file(e.path)) do
    local side = t.type == "-" and "old" or "new"
    local win = side == "old" and s.win_old or s.win_new
    local buf = api.nvim_win_get_buf(win)
    local count = api.nvim_buf_line_count(buf)
    local last = t.line == 0 and 1 or math.min(t.end_line or t.line, count)
    if t.line > 0 then
      pcall(api.nvim_buf_set_extmark, buf, annotate.ns, math.min(t.line, count) - 1, 0, {
        sign_text = "⟢",
        sign_hl_group = "AnnodiffThreadSign",
      })
      annotate.track(s, buf)
    end
    show(buf, last, t.line == 0, M.preview(t, api.nvim_win_get_width(win) - 12), side, t.line == 0 and 0 or last)
  end
end

-- Thread window -------------------------------------------------------------------

local function thread_markdown(t)
  local out = { "# " .. threads_mod.heading(t), "" }
  for _, turn in ipairs(t.turns) do
    vim.list_extend(out, vim.split("**Q:** " .. vim.trim(turn.question), "\n", { plain = true }))
    table.insert(out, "")
    if vim.trim(turn.answer) ~= "" then
      vim.list_extend(out, vim.split("**A:** " .. vim.trim(turn.answer), "\n", { plain = true }))
      table.insert(out, "")
    end
  end
  if t.status == "streaming" then
    table.insert(out, "_answering…" .. (t.activity and (" " .. t.activity) or "") .. "_")
  elseif t.status == "failed" then
    table.insert(out, "**Error:** " .. (t.err or "failed"))
  end
  return out
end

function M.close_overlay(s)
  local o = s.overlay
  s.overlay = nil
  if o and api.nvim_win_is_valid(o.win) then
    api.nvim_win_close(o.win, true)
  end
end

--- Push fresh content into the open thread window.
function M.update_overlay(s, t)
  local o = s.overlay
  if not o or o.thread ~= t.id or not api.nvim_buf_is_valid(o.buf) then
    return
  end
  local at_end = api.nvim_win_is_valid(o.win)
    and api.nvim_win_get_cursor(o.win)[1] >= api.nvim_buf_line_count(o.buf) - 1
  local lines = thread_markdown(t)
  vim.bo[o.buf].modifiable = true
  api.nvim_buf_set_lines(o.buf, 0, -1, false, lines)
  vim.bo[o.buf].modifiable = false
  if at_end and api.nvim_win_is_valid(o.win) then
    api.nvim_win_set_cursor(o.win, { #lines, 0 })
  end
end

---@param s annodiff.Session
---@param t annodiff.Thread
function M.open_thread(s, t)
  M.close_overlay(s)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(30, math.floor(vim.o.lines * 0.7))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " ⟢ agent thread ",
    footer = " c follow-up/retry · y promote · x cancel · d delete · q close ",
    footer_pos = "right",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  s.overlay = { buf = buf, win = win, thread = t.id }
  M.update_overlay(s, t)
  api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })

  local function current_thread()
    return s.threads:by(t.id)
  end
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, function()
      local th = current_thread()
      if th then
        fn(th)
      else
        M.close_overlay(s)
      end
    end, { buffer = buf, nowait = true, silent = true })
  end
  map("q", function()
    M.close_overlay(s)
  end)
  map("<Esc>", function()
    M.close_overlay(s)
  end)
  map("c", function(th)
    M.close_overlay(s)
    M.follow_up(s, th)
  end)
  map("y", function(th)
    M.close_overlay(s)
    M.promote(s, th)
  end)
  map("x", function(th)
    M.cancel(s, th)
  end)
  map("d", function(th)
    M.close_overlay(s)
    M.delete(s, th)
  end)
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if s.overlay and s.overlay.buf == buf then
          M.close_overlay(s)
        end
      end)
    end,
  })
end

return M
