-- E2E test for tele-nvim: opens `:terminal nvim somefile.txt` and checks that
-- the file ends up in this (parent) session.
--
-- The test needs this session to be listening on a socket, because the child
-- nvim spawned inside the :terminal finds its parent through $NVIM:
--
--   nvim --headless -u NORC --cmd "set rtp^=$PWD" -c "so test.lua"
--
-- Running without --headless is kinda supported, and doesn't exit after tests.
-- Otherwise, exits with status 1 if any check fails.

-- abs path of this checkout, e.g. when sourced as `:so test.lua`
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local failures = 0

-- Make sure the NVIM from env does not affect us
vim.fn.setenv("NVIM", vim.v.null)

local function log(fmt, ...)
	io.stdout:write(string.format(fmt, ...) .. "\n")
end
local headless = #vim.api.nvim_list_uis() == 0
if not headless then
	log = function(fmt, ...)
		vim.notify(string.format(fmt, ...))
	end
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

---@return boolean ok, vim.api.keyset.create_autocmd.callback_args
local function await_event(event, pattern, timeout_ms)
	timeout_ms = timeout_ms or 2000
	local co = assert(coroutine.running())
	local timer ---@type uv.uv_timer_t
	local au = vim.api.nvim_create_autocmd(event, {
		pattern  = pattern,
		once     = true,
		-- vim.schedule works around possible nested autocmd issues
		callback = vim.schedule_wrap(function(args)
			timer:stop()
			local ok, err = coroutine.resume(co, true, args)
			if not ok then
				vim.notify("Coroutine error: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	})

	timer = vim.defer_fn(function()
		vim.api.nvim_del_autocmd(au)
		local ok, err = coroutine.resume(co, false, "timed out")
		if not ok then
			log("Coroutine error: " .. err)
		end
	end, timeout_ms)

	log("waiting for autocmd %s %s", event, pattern)
	return coroutine.yield()
end

---@param buf integer
---@return boolean
local function buf_shows(buf, needle)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return table.concat(lines, "\n"):find(needle, 1, true) ~= nil
end

local function list_join(a, b)
	local copy = { unpack(a) }
	return vim.list_extend(copy, b)
end

-- prefer this checkout over any installed copy of tele-nvim
vim.opt.runtimepath:prepend(repo)

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local file = tmpdir .. "/somefile.txt"
vim.fn.writefile({ "some file content" }, file)

-- the child is a separate nvim, so it needs its own runtimepath setup
local init = tmpdir .. "/init.lua"
vim.fn.writefile({
	("vim.opt.runtimepath:prepend(%q)"):format(repo),
	-- Running manually just to be sure
	'vim.cmd("runtime plugin/tele.lua")',
}, init)
local base_child_cmd = { "nvim", "-u", init, "-i", "NONE", "-n" }

log("parent: %s", vim.v.servername)
log("file:   %s", file)

local tests = {}

tests[#tests + 1] = function()
	-- this is what `:terminal nvim somefile.txt` does, with an explicit rtp for the child
	vim.cmd("botright new")
	local wins_before = #vim.api.nvim_list_wins()
	local job = vim.fn.jobstart(
		list_join(base_child_cmd, { "+TeleRemoteWait", file }),
		{ term = true }
	)

	assert(job > 0, "basic: failed to start job")

	local ok, ev = await_event("User", "TeleOpened")
	assert(ok, "error waiting for TeleOpened: " .. vim.inspect(ev))
	assert(ev.data.bufs, "TeleOpened: invalid data " .. vim.inspect(ev))

	check("basic: opened buffers", #ev.data.bufs == 1)
	-- log("  child session said:")
	-- for _, line in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
	-- 	log("    | %s", line:gsub("%s+$", ""))
	-- end

	local buf = ev.data.bufs[1]
	check("basic: file opened in parent window", vim.fn.bufname(buf) == file)
	check("basic: file content visible in parent", buf_shows(buf, "some file content"))
	check(
		"basic: opened in a new window",
		#vim.api.nvim_list_wins() == wins_before + 1,
		"wins=" .. #vim.api.nvim_list_wins() .. " (was " .. wins_before .. ")"
	)
	check("basic: not opened in a new tab", #vim.api.nvim_list_tabpages() == 1, "tabs=" .. #vim.api.nvim_list_tabpages())

	-- tele sets bufhidden=wipe and quits the child once the last file goes away
	vim.api.nvim_buf_delete(vim.fn.bufnr(file), { force = true })

	log("blocking until child exits")
	local code = vim.fn.jobwait({ job }, 2000)[1]
	check("child exits when parent closes the file", code == 0, "exit code " .. code)
end

tests[#tests + 1] = function()
	vim.cmd("only!")
	vim.cmd("bdelete!")
	local wins_before2 = #vim.api.nvim_list_wins()
	local nvim_cmd = table.concat(base_child_cmd, " ") .. " +TeleRemoteWait -"
	local job2 = vim.fn.jobstart(
		{ "sh", "-c", "printf 'some stdin content\\n' | " .. nvim_cmd },
		{ term = true })

	check("stdin: child nvim started", job2 > 0, "job id " .. job2)

	local ok, ev = await_event("User", "TeleOpened")
	assert(ok, ev)
	assert(ev.data.bufs, "stdin: bad event.data from TeleOpened")

	check("stdin: opened 1 buffer", #ev.data.bufs == 1)

	local stdin_buf = ev.data.bufs[1]
	check("stdin: buffer opened", true, "buf " .. stdin_buf)
	check("stdin: buffer unnamed", vim.api.nvim_buf_get_name(stdin_buf) == "",
		"name=" .. vim.api.nvim_buf_get_name(stdin_buf))
	check("stdin: buffer modified", vim.bo[stdin_buf].modified == true)
	check("stdin: buffer content", vim.api.nvim_buf_get_lines(stdin_buf, 0, 1, false)[1] == "some stdin content")
	check(
		"stdin: opened in a new window",
		#vim.api.nvim_list_wins() == wins_before2 + 1,
		"wins=" .. #vim.api.nvim_list_wins() .. " (was " .. wins_before2 .. ")"
	)

	vim.api.nvim_buf_delete(stdin_buf, { force = true })

	log("blocking until child exits")
	local code2 = vim.fn.jobwait({ job2 }, 2000)[1]
	check("stdin: child exits when parent closes the file", code2 == 0, "exit code " .. code2)
end

-- manpager: ensure `man` works when nvim is used as MANPAGER
tests[#tests + 1] = function()
	vim.cmd("only!")
	vim.cmd("bdelete!")
	local nvim_cmd = table.concat(base_child_cmd, " ") .. " +TeleRemoteWait +Man! -"
	local man_job = vim.fn.jobstart(
		{ "man", "echo" },
		{
			env = { MANPAGER = nvim_cmd },
			term = true,
		})
	check("manpager: job started", man_job > 0, "job id " .. man_job)

	local ok, ev = await_event("User", "TeleOpened", 2000)
	assert(ok, "error waiting for TeleOpened: " .. vim.inspect(ev))
	assert(ev.data, "autocmd TeleOpened missing event.data")
	assert(ev.data.bufs, "autocmd TeleOpened missing event.data.bufs")

	check("manpager: TeleOpened event.data.bufs", #ev.data.bufs == 1,
		"expected 1 buffer, got: " .. vim.inspect(ev.data.bufs))

	local man_buf = ev.data.bufs[1]
	local function man_term_shows(needle)
		local lines = vim.api.nvim_buf_get_lines(man_buf, 0, -1, false)
		return table.concat(lines, "\n"):find(needle, 1, true) ~= nil
	end

	check("manpager: shows ECHO", man_term_shows("ECHO"), "")
	vim.api.nvim_buf_delete(man_buf, { force = true })

	log("blocking until child exits")
	local man_code = vim.fn.jobwait({ man_job }, 5000)[1]
	check("manpager: exits cleanly", man_code == 0, "exit code " .. man_code)
end

local main = coroutine.create(function()
	local start = vim.fn.reltime()
	for _, test in ipairs(tests) do
		test()
	end

	log("\nElapsed: %.3fms", vim.fn.reltimefloat(vim.fn.reltime(start)) * 1000)
	if failures > 0 then
		log("%d check(s) failed", failures)
		if headless then
			vim.cmd("cquit!")
		end
	else
		log("all checks passed")
		if headless then
			vim.cmd("qa!")
		end
	end
end)

assert(coroutine.resume(main))
