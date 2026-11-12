local M = {}

-- 三个 agent 共用的一段话。实测 code-explore 这类 user skill 的输出模板优先级高于
-- MCP instructions，只在工具描述里写「要推 tour」会被无视，必须走 system prompt。
M.directive = table.concat({
  "你在 ave（Neovim 插件）里运行，编辑器已连上。",
  "梳理跨文件流程或调用链时不要只输出文字报告：用 editor_tour 一次推送有序代码块",
  "（缺的块用 append=true 追加），再用文字补充说明；查单个实现用 editor_open，",
  "查定义/引用用 editor_lsp。",
  "只按当前工作区、当前分支磁盘上的代码梳理：不要切分支或 check out 别的版本，",
  "也不要复制文件到工作区外（/tmp 之类）去凑行号；某块和别的分支有差异就在 note 里说明。",
}, "")

local function valid_name(name)
  return type(name) == "string" and name:match("^[%w_]+$") ~= nil
end

function M.get(name)
  if not valid_name(name) then
    return nil
  end
  local ok, mod = pcall(require, "ave.agent.adapters." .. name)
  if not ok then
    return nil
  end
  return mod
end

return M
