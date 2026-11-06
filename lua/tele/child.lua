local M = {}

---@class tele.AttachParentOpt
---@field wait boolean? if false, exit client nvim session immediately after
---successfully attaching to parent. Analogous to --remote-wait (default true)
---@field defer_vim_enter boolean? (default true) wait until VimEnter before
---actually attaching. Required for passing stdin properly

---@class tele.ParsedFlags {}
---@field commands string[]
---@field files string[]
---@field diff boolean

---@class tele.AttachParentCliArgs : tele.ParsedFlags
---@field stdin_tempfile string?

local defaultAttachParentOpt = {
	wait = true,
	defer_vim_enter = true,
}

---@type boolean?
M.did_attach = nil

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
		elseif arg == "-" then
			table.insert(filtered, arg)
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

M.parse_cli_flags = parse_cli_flags

---@param opt tele.AttachParentOpt?
---@return boolean attached_parent, string? error
function M.try_attach_parent(opt)
	opt = vim.tbl_deep_extend("force", defaultAttachParentOpt, opt or {})
	local addr = vim.env.NVIM or os.getenv("NVIM_LISTEN_ADDRESS")
	if not addr or addr == "" then
		return false
	end

	if #vim.v.argv == 1 then
		return false
	end

	-- TODO: support "tcp" mode?
	local chan = vim.fn.sockconnect("pipe", addr, { rpc = true })
	if chan == 0 then
		return false, "could not connect to parent socket " .. addr
	end

	if not opt.defer_vim_enter or vim.v.vim_did_enter == 1 then
		M._attach_parent(chan, opt)
	else
		local augroup = vim.api.nvim_create_augroup("tele_vim_enter", { clear = true })
		vim.api.nvim_create_autocmd({ "VimEnter" }, {
			once = true,
			group = augroup,
			callback = function()
				M._attach_parent(chan, opt)
			end
		})
	end
	return true
end

function M._attach_parent(chan, opt)
	if M.did_attach then
		vim.notify("tele-nvim: try_attach_parent() called twice", vim.log.levels.ERROR)
		return
	end
	M.did_attach = true
	local args = { unpack(vim.v.argv, 2) }
	local client_sock = vim.v.servername
	vim.cmd('0,$argdelete') -- clear args as it may prevent clean shutdown
	-- TODO: support tcp socket?
	local sanitized_args = sanitize_args_for_call(args)
	---@type tele.AttachParentCliArgs
	local cli_args = parse_cli_flags(sanitized_args)
	local stdin_tempfile = _G.tele_stdin_tempfile
	if stdin_tempfile ~= nil then
		cli_args.stdin_tempfile = stdin_tempfile
	end
	vim.rpcrequest(chan, "nvim_exec_lua", "require('tele.parent').parent_open_files(...)",
		{ "pipe", client_sock, cli_args })
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
end

return M
