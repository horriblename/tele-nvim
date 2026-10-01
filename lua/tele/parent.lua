local M = {}

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
		for _, cmd in ipairs(cli_args.commands) do
			vim.cmd(cmd)
		end
		on_parent_done(child_chan)
		return
	elseif nfiles == 1 then
		local win_conf = vim.api.nvim_win_get_config(0)
		-- we are in a floating win
		if win_conf.relative ~= "" then
			vim.api.nvim_open_win(0, true, {
				relative = "win",
				row = 0,
				col = 1,
				width = win_conf.width,
				height = win_conf.height,
				title = vim.fn.fnamemodify(cli_args.files[1], ":."),
				border = 'rounded',
			})
		else
			local h = vim.fn.winheight(0)
			vim.cmd(h - 1 .. "split")
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
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				vim.fn.win_execute(win, "diffthis", true)
			end
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