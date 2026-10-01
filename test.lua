-- E2E test for tele-nvim: opens `:terminal nvim somefile.txt` and checks that
-- the file ends up in this (parent) session.
--
-- The test needs this session to be listening on a socket, because the child
-- nvim spawned inside the :terminal finds its parent through $NVIM:
--
--   nvim --headless -u NONE --cmd "set rtp^=$PWD" -c "so test.lua"
--
-- Exits with status 1 if any check fails.

-- abs path of this checkout, e.g. when sourced as `:so test.lua`
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local failures = 0

local function log(fmt, ...)
	io.stdout:write(string.format(fmt, ...) .. "\n")
end

local function check(name, ok, detail)
	local suffix = detail and ("  -- " .. detail) or ""
	if ok then
		log("  ok   %s%s", name, suffix)
	else
		failures = failures + 1
		log("  FAIL %s%s", name, suffix)
	end
	return ok
end

---Polls `fn` until it returns something truthy, up to `timeout` ms
---@return any value returned by `fn`, or nil on timeout
local function wait_for(what, fn, timeout)
	local now = vim.uv.now()
	local deadline = now + (timeout or 5000)
	while true do
		local res = fn()
		if res then
			return res
		end
		if vim.uv.now() >= deadline then
			failures = failures + 1
			log("  FAIL timed out after %dms waiting for %s", timeout or 5000, what)
			return nil
		end
		vim.wait(20)
	end
end

---@param buf integer
---@return boolean
local function buf_shows(buf, needle)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return table.concat(lines, "\n"):find(needle, 1, true) ~= nil
end

---@param path string
---@return integer?
local function find_win_showing(path)
	local wanted = vim.fn.fnamemodify(path, ":p")
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
		if name ~= "" and vim.fn.fnamemodify(name, ":p") == wanted then
			return win
		end
	end
end

-- prefer this checkout over any installed copy of tele-nvim
vim.opt.runtimepath:prepend(repo)

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local file = tmp .. "/somefile.txt"
vim.fn.writefile({ "some file content" }, file)

-- the child is a separate nvim, so it needs its own runtimepath setup
local init = tmp .. "/init.lua"
vim.fn.writefile({
	("vim.opt.runtimepath:prepend(%q)"):format(repo),
	-- Running manually since we use -u NONE
	'vim.cmd("runtime plugin/tele.lua")',
}, init)

log("parent: %s", vim.v.servername)
log("file:   %s", file)

-- this is what `:terminal nvim somefile.txt` does, with an explicit rtp for the child
vim.cmd("botright new")
local term_win = vim.api.nvim_get_current_win()
local term_buf = vim.api.nvim_get_current_buf()
local wins_before = #vim.api.nvim_list_wins()
local job = vim.fn.jobstart({ "nvim", "-u", init, "-i", "NONE", "-n", "+TeleRemoteWait", file }, { term = true })

if not check("child nvim started", job > 0, "job id " .. job) then
	vim.cmd("cquit!")
end

local file_win = wait_for("parent to open " .. vim.fn.fnamemodify(file, ":."), function()
	return find_win_showing(file)
end)
if not file_win then
	log("  child session said:")
	for _, line in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
		log("    | %s", line:gsub("%s+$", ""))
	end
	vim.cmd("cquit!")
end

check("file opened in parent window", true, ("window %d of %d"):format(file_win, #vim.api.nvim_list_wins()))
check("file content visible in parent", buf_shows(vim.api.nvim_win_get_buf(file_win), "some file content"))
check(
	"opened in a new window",
	#vim.api.nvim_list_wins() == wins_before + 1,
	"wins=" .. #vim.api.nvim_list_wins() .. " (was " .. wins_before .. ")"
)
check("opened in a new tab", #vim.api.nvim_list_tabpages() == 1, "tabs=" .. #vim.api.nvim_list_tabpages())
check(
	"opened above the terminal window",
	vim.api.nvim_win_get_position(file_win)[1] < vim.api.nvim_win_get_position(term_win)[1]
)

-- tele sets bufhidden=wipe and quits the child once the last file goes away
vim.api.nvim_buf_delete(vim.fn.bufnr(file), { force = true })

local code = vim.fn.jobwait({ job }, 5000)[1]
check("child exits when parent closes the file", code == 0, "exit code " .. code)

vim.fn.delete(tmp, "rf")

if failures > 0 then
	log("%d check(s) failed", failures)
	vim.cmd("cquit!")
end
log("all checks passed")
vim.cmd("qa!")
