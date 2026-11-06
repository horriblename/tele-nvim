local M = {}

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

---@param stdin_tempfile  string
---@return integer? bufnr
local function configure_stdin_buf(stdin_tempfile)
	local buf = vim.fn.bufnr(stdin_tempfile)
	if buf ~= -1 then
		vim.api.nvim_buf_set_name(buf, "")
		vim.bo[buf].modified = true
		return buf
	end
	return nil
end

local function on_parent_done(child_chan)
	pcall(function()
		vim.rpcnotify(child_chan, "nvim_command", "quitall!")
		-- XXX: I think rpcnotify() is not flushed on chanclose(),
		-- so we'd lose messages sometimes (most of the time)

		-- vim.fn.chanclose(child_chan)
	end)
	-- TODO: errors are probably due to nested nvim being closed first,
	-- usually harmless, but I should check somehow

	vim.api.nvim_exec_autocmds("User", {
		pattern = "TeleClosedAll",
		data = {
			child_channel = child_chan,
		},
	})
end

---@param sock_mode string
---@param child_sock string
---@param cli_args tele.AttachParentCliArgs
function M.parent_open_files(sock_mode, child_sock, cli_args)
	local child_chan = vim.fn.sockconnect(sock_mode, child_sock, { rpc = true })
	if child_chan == 0 then
		error("could not connect to child socket " .. child_sock)
	end
	local stdin_tempfile = cli_args.stdin_tempfile
	local args_has_stdin = vim.list_contains(cli_args.files, "-")
	if stdin_tempfile ~= nil and not args_has_stdin then
		table.insert(cli_args.files, "-")
	end

	---@type string[]
	local files = cli_args.files
	for i, f in ipairs(files) do
		if f == "-" then
			files[i] = stdin_tempfile
		end
	end

	---@type integer?
	local stdin_bufnr
	local nfiles = #files
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
				border = 'rounded',
			})
		else
			local h = vim.fn.winheight(0)
			vim.cmd(h - 1 .. "split")
		end
		vim.cmd.edit(unpack(files))
		if stdin_tempfile then
			stdin_bufnr = configure_stdin_buf(stdin_tempfile)
		end
		if cli_args.diff then
			vim.cmd("diffthis")
		end
		for _, cmd in ipairs(cli_args.commands) do
			vim.cmd(cmd)
		end
	else
		vim.cmd.tabnew()
		vim.cmd.args(unpack(files))
		if stdin_tempfile then
			stdin_bufnr = configure_stdin_buf(stdin_tempfile)
		end
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

	local bufs = vim.tbl_map(function(file)
		-- XXX: if there was any problem getting stdin_bufnr, we still try with
		-- the temp name
		return file == stdin_tempfile and stdin_bufnr or vim.fn.bufnr(file)
	end, files)

	for _, buf in ipairs(bufs) do
		-- TODO: not reliable: if buffer is open in another window, this will close that one.
		-- Probably better to set winfixbuf and watch for window close (still need to handle buffer switching since
		-- :edit! file ignores winfixbuf)
		if vim.api.nvim_buf_is_valid(buf) then
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

	vim.api.nvim_exec_autocmds("User", {
		pattern = "TeleOpened",
		data = {
			child_channel = child_chan,
			bufs = bufs,
		},
	})
end

return M
