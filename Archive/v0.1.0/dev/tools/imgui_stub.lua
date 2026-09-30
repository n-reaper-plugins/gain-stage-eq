-- A generic stub of ReaImGui for offline tests: every unknown ImGui_ function returns false,
-- the ones the scripts branch on are scripted. G.click = label of the button/checkbox to "press".
local M = {}

function M.install(G)
  G.click, G.slide, G.calls, G.drawn, G.text, G.depth, G.disabled = nil, G.slide or {}, 0, 0, {}, 0, 0
  setmetatable(reaper, { __index = function(_, k)
    if type(k) == "string" and k:match("^ImGui_") then return function() G.calls = G.calls + 1; return false end end
  end })
  local R = reaper
  R.ImGui_CreateContext = function() return {} end
  R.ImGui_Begin = function(_, title) G.title = title; G.depth = G.depth + 1; return true, true end
  R.ImGui_End = function() G.depth = G.depth - 1 end
  R.ImGui_BeginTable = function() G.depth = G.depth + 1; return true end
  R.ImGui_EndTable = function() G.depth = G.depth - 1 end
  R.ImGui_BeginDisabled = function() G.disabled = G.disabled + 1 end
  R.ImGui_EndDisabled = function() G.disabled = G.disabled - 1 end
  R.ImGui_TableFlags_Resizable = function() return 1 end
  R.ImGui_TableFlags_BordersInnerV = function() return 2 end
  R.ImGui_TableColumnFlags_WidthStretch = function() return 4 end
  R.ImGui_Cond_FirstUseEver = function() return 8 end
  R.ImGui_GetContentRegionAvail = function() return 500, 300 end
  R.ImGui_GetCursorScreenPos = function() return 0, 0 end
  R.ImGui_GetWindowDrawList = function() return {} end
  R.ImGui_DrawList_AddRectFilled = function() G.drawn = G.drawn + 1 end
  R.ImGui_DrawList_AddLine = function() G.drawn = G.drawn + 1 end
  R.ImGui_DrawList_AddText = function() G.drawn = G.drawn + 1 end
  R.ImGui_Text = function(_, t) G.text[#G.text + 1] = t end
  R.ImGui_TextColored = function(_, _, t) G.text[#G.text + 1] = t end
  R.ImGui_TextWrapped = function(_, t) G.text[#G.text + 1] = t end
  R.ImGui_Button = function(_, label) local c = (G.click == label); if c then G.click = nil end return c end
  R.ImGui_SmallButton = R.ImGui_Button
  R.ImGui_Checkbox = function(_, label, v)
    if G.click == label then G.click = nil; return true, not v end
    return false, v
  end
  R.ImGui_Combo = function(_, label, idx) if G.slide[label] then return true, G.slide[label] end return false, idx end
  R.ImGui_SliderInt = function(_, label, v) if G.slide[label] then return true, G.slide[label] end return false, v end
  R.ImGui_SliderDouble = function(_, label, v) if G.slide[label] then return true, G.slide[label] end return false, v end
  R.ImGui_ColorEdit3 = function(_, _, v) return false, v end
end

-- one line of everything that was printed since the last call
function M.text(G) local s = table.concat(G.text, "\n"); G.text = {}; return s end

return M
