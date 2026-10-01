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
		elseif arg:find("^%+Tele") then
			-- ignore :Tele* commands
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
	vim.rpcrequest(chan, "nvim_exec_lua", "require('tele.parent').parent_open_files(...)",
		{ "pipe", client_sock, unpack(sanitized_args) })
	if opt.wait then
		vim.cmd [[
			enew!
			setlocal buftype=nofile wrap
			normal iFile is being edited in the parent nvim session. Close that window to proceed.
			setlocal nomodifiable
			silent wincmd o
		]]
		vim.notify("tele-nvim: waiting for parent session to close files")
	else
		os.exit(0)
	end
	return true
end

return M