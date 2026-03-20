vim.api.nvim_create_user_command("TeleRemoteWait", function()
	assert(require('tele').try_attach_parent())
end, {})
