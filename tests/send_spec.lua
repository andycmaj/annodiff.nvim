-- :AnnodiffSend: revdiff's O flush + post-flush command.
local api = vim.api
local config = require("annodiff.config")

local function sh(dir, cmd)
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. "\n" .. (res.stderr or ""))
  return res.stdout
end

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
  vim.wait(20, function()
    return false
  end)
end

local function quiet(fn)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    table.insert(msgs, m)
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  assert(ok, err)
  return msgs
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

vim.g.maplocalleader = "\\"

describe("send", function()
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  vim.fn.writefile({ "a", "b" }, repo .. "/f.txt")
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "init" })
  vim.fn.writefile({ "a", "B" }, repo .. "/f.txt")
  vim.cmd.cd(repo)
  local out = repo .. "/sent.txt"
  local count = repo .. "/count.txt"
  -- appends each send, so tests can count invocations
  local cmd = ("cat > %s; echo x >> %s"):format(vim.fn.shellescape(out), vim.fn.shellescape(count))

  it("without a command it says how to set one and runs nothing", function()
    vim.env.ANNODIFF_SEND_COMMAND = nil
    vim.env.REVDIFF_POST_FLUSH_COMMAND = nil
    quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    local s = require("annodiff.view").current()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\anote one<C-s>")
    local msgs = quiet(function()
      press("\\s")
    end)
    truthy(msgs[1]:find("no send command", 1, true), msgs[1])
  end)

  it("\\s pipes the full set to the command on stdin", function()
    config.options.send_command = cmd
    local msgs = quiet(function()
      press("\\s")
      vim.wait(2000, function()
        return read(count) ~= nil
      end)
      vim.wait(50, function()
        return false
      end)
    end)
    eq("## f.txt:2 (+)\nnote one\n", read(out))
    truthy(vim.tbl_contains(vim.tbl_map(function(m)
      return m:match("^annodiff: sent 1 annotation") and true or false
    end, msgs), true), vim.inspect(msgs))
  end)

  it("O in the tree sends too; $REVDIFF_POST_FLUSH_COMMAND is honored", function()
    config.options.send_command = nil
    vim.env.REVDIFF_POST_FLUSH_COMMAND = cmd
    local s = require("annodiff.view").current()
    api.nvim_set_current_win(s.win_tree)
    quiet(function()
      press("O")
      vim.wait(2000, function()
        return #vim.split(vim.trim(read(count) or ""), "\n") == 2
      end)
    end)
    eq(2, #vim.split(vim.trim(read(count)), "\n"))
    vim.env.REVDIFF_POST_FLUSH_COMMAND = nil
  end)

  it("a failing command reports its stderr", function()
    config.options.send_command = "echo 'pane gone' >&2; exit 3"
    local s = require("annodiff.view").current()
    local msgs = quiet(function()
      require("annodiff.send").send(s, { wait = true })
    end)
    eq("annodiff: send command failed (exit 3): pane gone", msgs[1])
  end)

  it("close sends unsent changes when ANNODIFF_SEND_ON_CLOSE=1, once", function()
    config.options.send_command = cmd
    vim.env.ANNODIFF_SEND_ON_CLOSE = "1"
    local s = require("annodiff.view").current()
    quiet(function()
      require("annodiff.send").send(s, { wait = true })
    end)
    local before = #vim.split(vim.trim(read(count)), "\n")
    quiet(function()
      vim.cmd("AnnodiffClose")
    end)
    eq(before, #vim.split(vim.trim(read(count)), "\n"), "same set already sent: no resend")

    quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    s = require("annodiff.view").current()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\a")
    press("ccnote two<C-s>")
    quiet(function()
      vim.cmd("AnnodiffClose")
    end)
    eq(before + 1, #vim.split(vim.trim(read(count)), "\n"))
    eq("## f.txt:2 (+)\nnote two\n", read(out))
  end)

  it("exiting Neovim finishes open reviews (state, export, send)", function()
    quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    local s = require("annodiff.view").current()
    api.nvim_win_set_cursor(s.win_new, { 1, 0 })
    press("\\aon exit<C-s>")
    local before = #vim.split(vim.trim(read(count)), "\n")
    quiet(function()
      vim.api.nvim_exec_autocmds("VimLeavePre", {})
    end)
    eq(before + 1, #vim.split(vim.trim(read(count)), "\n"))
    truthy(read(out):find("on exit", 1, true))
    eq(nil, require("annodiff.view").current())
    vim.env.ANNODIFF_SEND_ON_CLOSE = nil
    config.options.send_command = nil
    vim.cmd("tabnew")
    vim.cmd("silent! tabonly")
  end)
end)

-- The /annodiff skill does not block: Claude ends its turn once Neovim is open. Every
-- close must reach the send command, notes or not, or a review closed with no notes
-- leaves the agent waiting on nothing.
describe("close notice (send_on_close = always)", function()
  local repo = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  vim.fn.writefile({ "a", "b" }, repo .. "/f.txt")
  sh(repo, { "git", "add", "-A" })
  sh(repo, { "git", "commit", "-q", "-m", "init" })
  vim.fn.writefile({ "a", "B" }, repo .. "/f.txt")
  local out = repo .. "/sent.txt"
  local calls = repo .. "/calls.txt"
  -- stdin to out; one line per run: reason, count, stdin bytes
  local cmd = ([[cat > %s; printf '%%s %%s %%s\n' "$ANNODIFF_SEND_REASON" "$ANNODIFF_ANNOTATION_COUNT" "$(wc -c < %s | tr -d ' ')" >> %s]]):format(
    vim.fn.shellescape(out),
    vim.fn.shellescape(out),
    vim.fn.shellescape(calls)
  )
  local function runs()
    local t = vim.trim(read(calls) or "")
    return t == "" and {} or vim.split(t, "\n")
  end
  local function open()
    vim.cmd.cd(repo)
    quiet(function()
      vim.cmd("Annodiff HEAD")
    end)
    return require("annodiff.view").current()
  end
  local function close()
    return quiet(function()
      vim.cmd("AnnodiffClose")
    end)
  end
  local function setup(on_close, keep_state)
    os.remove(calls)
    os.remove(out)
    if not keep_state then
      vim.fn.delete(repo .. "/.git/annodiff", "rf") -- no notes restored from an earlier test
    end
    config.options.send_command = cmd
    config.options.send_on_close = on_close
  end

  it("closing with no annotations runs the command with empty stdin, reason close, count 0", function()
    setup("always")
    open()
    local msgs = close()
    eq({ "close 0 0" }, runs())
    truthy(vim.tbl_contains(msgs, "annodiff: closed with no annotations (told the agent)"), vim.inspect(msgs))
  end)

  it("the env var turns it on too: ANNODIFF_SEND_ON_CLOSE=always", function()
    setup(false)
    vim.env.ANNODIFF_SEND_ON_CLOSE = "always"
    open()
    close()
    vim.env.ANNODIFF_SEND_ON_CLOSE = nil
    eq({ "close 0 0" }, runs())
  end)

  it("plain send_on_close (=1) still runs nothing when there is nothing to send", function()
    setup(false)
    vim.env.ANNODIFF_SEND_ON_CLOSE = "1"
    open()
    close()
    vim.env.ANNODIFF_SEND_ON_CLOSE = nil
    eq({}, runs())
  end)

  it("\\s says reason send; closing after it with nothing new sends an empty notice with the count", function()
    setup("always")
    local s = open()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\anote<C-s>")
    quiet(function()
      require("annodiff.send").send(s, { wait = true })
    end)
    eq({ "send 1 " .. #"## f.txt:2 (+)\nnote\n" }, runs())
    local msgs = close()
    eq({ "send 1 20", "close 1 0" }, runs())
    truthy(vim.tbl_contains(msgs, "annodiff: closed, nothing new to send (told the agent)"), vim.inspect(msgs))
  end)

  it("closing with unsent notes sends them once, as the close", function()
    setup("always")
    local s = open()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\a")
    press("ccchanged<C-s>")
    close()
    eq({ "close 1 23" }, runs())
    eq("## f.txt:2 (+)\nchanged\n", read(out))
  end)

  it("\\q sends unsent notes and quits, even with send_on_close off", function()
    setup(false)
    local view = require("annodiff.view")
    local quit_ran = false
    view.quit_command = "lua _G.__annodiff_quit()"
    _G.__annodiff_quit = function()
      quit_ran = true
      vim.api.nvim_exec_autocmds("VimLeavePre", {}) -- what :qall does on the way out
    end
    local s = open()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\a")
    press("ccflushed<C-s>")
    quiet(function()
      press("\\q")
    end)
    truthy(quit_ran, "\\q quits Neovim")
    eq({ "close 1 23" }, runs())
    eq("## f.txt:2 (+)\nflushed\n", read(out))
    eq(nil, view.current(), "the review is finished")
  end)

  -- RIKER-0255: a note typed in the editor but not saved with <C-s> was dropped on close
  it("a note still open in the editor is kept and sent when the review closes", function()
    setup("always")
    local s = open()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\a")
    press("ccunsaved draft") -- typed, never saved
    eq(0, s.store:count())
    quiet(function()
      vim.cmd("AnnodiffClose") -- typed in the editor, like :qa
    end)
    eq("## f.txt:2 (+)\nunsaved draft\n", read(out))
    eq({ "close 1 " .. #read(out) }, runs())
  end)

  it("exiting Neovim with a draft open keeps it; an empty draft deletes nothing", function()
    setup("always")
    local s = open()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\a")
    press("ccdraft on exit")
    quiet(function()
      vim.api.nvim_exec_autocmds("VimLeavePre", {})
    end)
    eq("## f.txt:2 (+)\ndraft on exit\n", read(out))
    eq({ "close 1 " .. #read(out) }, runs())

    -- reopen: the note is restored; clear it in the editor and close without saving
    setup("always", true)
    s = open()
    eq(1, s.store:count())
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\a")
    press("gg\"_dG") -- the editor opens in normal mode on an existing note
    eq("", vim.trim(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "")), "editor emptied")
    close()
    eq(1, s.store:count(), "an empty draft is dropped, not taken as a delete")
    eq("## f.txt:2 (+)\ndraft on exit\n", read(out), "the restored note is still there")
  end)

  it("a draft cancelled with <Esc> is not kept", function()
    setup("always")
    local s = open()
    eq(0, s.store:count())
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\a")
    press("ccthrown away<Esc><Esc>")
    close()
    eq(0, s.store:count())
    eq({ "close 0 0" }, runs())
  end)

  it("\\q inside the editor keeps the draft, sends it and quits", function()
    setup(false)
    local view = require("annodiff.view")
    local quit_ran = false
    view.quit_command = "lua _G.__annodiff_quit()"
    _G.__annodiff_quit = function()
      quit_ran = true
      vim.api.nvim_exec_autocmds("VimLeavePre", {})
    end
    local s = open()
    api.nvim_win_set_cursor(s.win_new, { 2, 0 })
    press("\\a")
    press("ccfrom the editor<Esc>")
    quiet(function()
      press("\\q")
    end)
    truthy(quit_ran, "\\q in the editor quits")
    eq("## f.txt:2 (+)\nfrom the editor\n", read(out))
    eq({ "close 1 " .. #read(out) }, runs())
    eq(nil, view.current())
    view.quit_command = "confirm qall"
  end)

  it("\\q with nothing new and send_on_close off sends nothing; a cancelled quit keeps the review", function()
    setup(false)
    local view = require("annodiff.view")
    view.quit_command = "lua _G.__annodiff_quit()"
    _G.__annodiff_quit = function() end -- the confirm prompt was cancelled
    local s = open()
    quiet(function()
      press("\\q")
    end)
    eq({}, runs())
    eq(s, view.current(), "still open")
    eq(nil, s.flush, "a later close is an ordinary close")
    view.quit_command = "confirm qall"
    config.options.send_on_close = false
    config.options.send_command = nil
    close()
    vim.cmd("tabnew")
    vim.cmd("silent! tabonly")
  end)
end)
