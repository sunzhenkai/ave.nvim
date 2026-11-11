if vim.g.loaded_ave == 1 then
  return
end
vim.g.loaded_ave = 1

vim.api.nvim_create_user_command("Ave", function(a)
  require("ave").dispatch(a.fargs)
end, {
  nargs = "*",
  complete = function()
    return { "open", "close", "toggle", "stop", "status", "install" }
  end,
  desc = "ave: native agent panel",
})
