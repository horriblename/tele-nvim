local M = {}

---@class tele.AttachParentOpt
---@field wait boolean if false, exit client nvim session immediately after successfully attaching to parent. Analogous to --remote-wait (default true)

local defaultAttachParentOpt = {
	wait = true,
}

-- CLI flags that take the next arg as value.
-- Some flags have optional args, which I have not handled
local kv_flags = {
	["-t"] = true,
	["-q"] = true,
	["--startuptime"] = true,
	["-c"] = true,
	["--cmd"] = true,
	["-S"] = true,
	["-u"] = true,
	["-i"] = true,
	["-s"] = true,
	["-w"] = true,
	["-W"] = true,
	["--listen"] = true,
}

---Sanitizes file arguments for an RPC call,
---* Only allow "+", "-d", and file arguments
---* Expand file arguments to full path
---@param args string[]
---@return string[]
local function sanitize_args_for_call(args)
	local filtered = {}
	local skipnext = false
	for i, arg in ipairs(args) do
		if skipnext then
			skipnext = false
		elseif arg == "--" then
			table.insert(filtered, "--")
			for j = i + 1, #args do
				table.insert(filtered, vim.fn.fnamemodify(args[j], ":p"))
			end
			break
		elseif arg:find("^%+") or arg == "-d" then
			table.insert(filtered, arg)
		elseif not arg:match("^%-") then
			table.insert(filtered, vim.fn.fnamemodify(arg, ":p"))
		elseif kv_flags[arg] then
			skipnext = true
		end
	end
	return filtered
end

---Currently only supports files, "+cmd", and "--" for passing rest of args as literal files
---@param args string[]
---@return {commands: string[], files: string[], diff: boolean}
local function parse_cli_flags(args)
	local res = { commands = {}, files = {}, diff = false }
	for i, arg in ipairs(args) do
		if arg == "--" then
			vim.list_extend(res.files, args, i + 1)
			break
		elseif arg == "-d" then
			res.diff = true
		elseif arg:find("^%+") then
			table.insert(res.commands, arg:sub(2))
		else
			table.insert(res.files, arg)
		end
	end
	return res
end

---@param opt tele.AttachParentOpt?
---@return boolean attached_parent, string? error
function M.try_attach_parent(opt)
	opt = vim.tbl_deep_extend("force", defaultAttachParentOpt, opt or {})
	local args = { unpack(vim.v.argv, 2) }
	local addr = vim.env.NVIM or os.getenv("NVIM_LISTEN_ADDRESS")
	if not addr or addr == "" then
		return false
	end

	if #args == 0 then
		return false
	end

	-- TODO: support "tcp" mode?
	local chan = vim.fn.sockconnect("pipe", addr, { rpc = true })
	if chan == 0 then
		return false, "could not connect to parent socket " .. addr
	end
	local client_sock = vim.v.servername

	vim.cmd('0,$argdelete') -- clear args as it may prevent clean shutdown
	-- TODO: support tcp socket?
	local sanitized_args = sanitize_args_for_call(args)
	vim.rpcrequest(chan, "nvim_exec_lua", "require('tele').parent_open_files(...)",
		{ "pipe", client_sock, unpack(sanitized_args) })
	if opt.wait then
		vim.cmd [[
			enew!
			setlocal buftype=nofile wrap
			normal iFile is being edited in the parent nvim session. Close that window to proceed.
			setlocal nomodifiable
		]]
		vim.notify("tele-nvim: waiting for parent session to close files")
	else
		os.exit(0)
	end
	return true
end

---@generic T
---@param list T[]
---@param item T
---@return integer?
local function list_index(list, item)
	for i, el in ipairs(list) do
		if el == item then
			return i
		end
	end
end

local function on_parent_done(child_chan)
	pcall(function()
		vim.rpcnotify(child_chan, "nvim_command", "quitall")
		vim.fn.chanclose(child_chan)
	end)
	-- TODO: errors are probably due to nested nvim being closed first,
	-- usually harmless, but I should check somehow
end

function M.parent_open_files(sock_mode, child_sock, ...)
	local child_chan = vim.fn.sockconnect(sock_mode, child_sock, { rpc = true })
	if child_chan == 0 then
		error("could not connect to child socket " .. child_sock)
	end
	local cli_args = parse_cli_flags({ ... })
	local nfiles = #cli_args.files
	if nfiles == 0 then
		on_parent_done(child_chan)
		return
	elseif nfiles == 1 then
		local win_conf = vim.api.nvim_win_get_config(0)
		-- we are in a floating win
		if win_conf.relative ~= "" then
			vim.api.nvim_open_win(0, true, {
				relative = "win",
				row = 0,
				col = 0,
				width = win_conf.width,
				height = win_conf.height,
			})
		else
			vim.cmd("split")
		end
		vim.cmd.edit(unpack(cli_args.files))
		if cli_args.diff then
			vim.cmd("diffthis")
		end
		for _, cmd in ipairs(cli_args.commands) do
			vim.cmd(cmd)
		end
	else
		vim.cmd.tabnew()
		vim.cmd.args(unpack(cli_args.files))
		vim.cmd('vertical all')
		if cli_args.diff then
			vim.cmd("windo diffthis")
		end
		for _, cmd in ipairs(cli_args.commands) do
			vim.cmd(cmd)
		end
	end

	local group = vim.api.nvim_create_augroup("tele_" .. child_chan, { clear = false })

	local bufs = vim.iter(cli_args.files):map(vim.fn.bufnr):totable()

	for _, buf in ipairs(bufs) do
		-- TODO: not reliable: if buffer is open in another window, this will close that one.
		-- Probably better to set winfixbuf and watch for window close (still need to handle buffer switching since
		-- :edit! file ignores winfixbuf)
		vim.bo[buf].bufhidden = "wipe"
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = group,
			buffer = buf,
			once = true,
			callback = function()
				local idx = list_index(bufs, buf)
				if idx then
					table.remove(bufs, idx)
					vim.rpcnotify(child_chan, "nvim_echo", {
						{ string.format('closed %s. %d files left', vim.fn.bufname(buf), #bufs) },
					})
				end
				if #bufs == 0 then
					on_parent_done(child_chan)
					vim.api.nvim_del_augroup_by_id(group)
				end
			end
		})
	end
end

return M
