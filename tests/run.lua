-- Dependency-free test runner.
--   nvim --clean --headless -l tests/run.lua [spec-file ...]
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
vim.cmd.runtime("plugin/annodiff.lua")

-- Keep the owner's git config (signing, hooks, aliases) out of test repos.
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_AUTHOR_NAME, vim.env.GIT_AUTHOR_EMAIL = "test", "test@example.com"
vim.env.GIT_COMMITTER_NAME, vim.env.GIT_COMMITTER_EMAIL = "test", "test@example.com"

local results = { pass = 0, fail = 0 }
local prefix = {}

_G.describe = function(name, fn)
  table.insert(prefix, name)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    results.fail = results.fail + 1
    io.stdout:write("  FAIL " .. table.concat(prefix, " > ") .. " (setup)\n" .. tostring(err) .. "\n")
  end
  table.remove(prefix)
end

_G.it = function(name, fn)
  local full = table.concat(prefix, " > ") .. " > " .. name
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results.pass = results.pass + 1
    io.stdout:write("  ok   " .. full .. "\n")
  else
    results.fail = results.fail + 1
    io.stdout:write("  FAIL " .. full .. "\n" .. tostring(err):gsub("\n", "\n       ") .. "\n")
  end
end

_G.eq = function(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      ("%sexpected:\n%s\nactual:\n%s"):format(msg and (msg .. "\n") or "", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

_G.truthy = function(v, msg)
  if not v then
    error(msg or "expected truthy value", 2)
  end
end

local files = _G.arg and #_G.arg > 0 and _G.arg or vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(files)
for _, file in ipairs(files) do
  io.stdout:write(vim.fs.basename(file) .. "\n")
  local chunk, err = loadfile(file)
  if not chunk then
    results.fail = results.fail + 1
    io.stdout:write("  FAIL load: " .. err .. "\n")
  else
    chunk()
  end
end

io.stdout:write(("\n%d passed, %d failed\n"):format(results.pass, results.fail))
os.exit(results.fail == 0 and 0 or 1)
