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
