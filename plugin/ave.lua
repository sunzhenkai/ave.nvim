if vim.g.loaded_ave == 1 then
  return
end
vim.g.loaded_ave = 1

require("ave").register_commands()
