vim.api.nvim_create_user_command("TeleRemoteWait", function()
	assert(require('tele').try_attach_parent())
end, {})

local augroup = vim.api.nvim_create_augroup("tele_stdin_watch", { clear = true })
vim.api.nvim_create_autocmd("StdinReadPost", {
	group = augroup,
	callback = function()
		local tmp = vim.fn.tempname()
		vim.cmd("silent write " .. vim.fn.fnameescape(tmp))
		_G.tele_stdin_tempfile = tmp
	end,
})
