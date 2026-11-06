vim.api.nvim_create_user_command("TeleRemoteWait", function()
	assert(require('tele').try_attach_parent())
end, {})

vim.api.nvim_create_autocmd("StdinReadPost", {
	callback = function()
		local tmp = vim.fn.tempname()
		vim.cmd("silent write " .. vim.fn.fnameescape(tmp))
		_G.tele_stdin_tempfile = tmp
	end,
})
