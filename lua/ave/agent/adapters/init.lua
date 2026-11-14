local M = {}

-- MCP instructions 可能被 agent 或 skill 的模板覆盖，触发边界需要随高优先级提示词注入。
M.directive = table.concat({
  "你在 ave（Neovim 插件）里运行，编辑器已连上。默认只在聊天中回答，不自动操作编辑器。",
  "仅在用户要求打开、跳转或跟随，或者任务明显需要结合编辑器当前位置、选区或代码视图时调用 editor_open。",
  "仅在用户要求走读/tour，或者跨文件流程明显适合按代码块顺序阅读时调用一次 editor_tour",
  "（缺的块用 append=true 追加）；普通文件读写和跨文件分析本身不构成触发理由。",
  "查定义/引用用 editor_lsp；需要当前文件、选区或位置时用 editor_context。",
  "明确禁止优先：用户要求不要使用 ave 时禁止所有 ave 工具；只要求不打开编辑器或走读列表时，",
  "禁止 editor_open、editor_tour 等可见操作，仍可使用 editor_context、editor_lsp。",
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
