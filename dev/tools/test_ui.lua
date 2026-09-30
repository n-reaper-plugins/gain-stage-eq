-- Smoke test for GainStageUI.lua with a STUBBED ReaImGui. It catches nil errors, wrong call order
-- and broken wiring - it cannot tell what the window looks like or whether a real ReaImGui
-- function has the signature assumed here.
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
-- REAPER's Lua has no deprecated math functions; make sure we do not rely on them
for _, k in ipairs({ "sinh", "cosh", "tanh", "pow", "atan2", "log10", "ldexp", "frexp", "mod" }) do math[k] = nil end
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end

local RES = "/tmp/gse-test-ui-resource"
os.execute("rm -rf " .. RES)
local S = Mock.install({ resource = RES })
local G = { slide = {} }
Stub.install(G)

local Core = require("GainStageCore")
local Reaper = require("GainStageReaper")
local UI = require("GainStageUI")
local set = Reaper.load_settings()
local state = Reaper.new_state()
local RA = Reaper.new(set, state)
local ui = UI.new(set, state, RA, "Gain Stage EQ v" .. Core.VERSION .. "###t")

local function frame(steps)
  for _ = 1, steps or 1 do
    RA.refresh_selection(); RA.pump_job()
    if state.dirty and state.result then RA.recompute() end
    state.dirty = false
    RA.pump_preview()
    G.text = {}
    local open = ui.frame()
    S.clock = S.clock + 0.02
    if not open then return false end
  end
  return true
end
local function said(pat) return table.concat(G.text, "\n"):find(pat, 1, true) ~= nil end

print("empty project")
check("frame runs", frame())
check("ImGui begin/end balanced", G.depth == 0, G.depth)
check("asks for a track", said("Select ONE track"))
check("window title has the version", G.title:find("v" .. Core.VERSION, 1, true) ~= nil, G.title)

print("track selected")
local DARK = { { 100, 0.02 }, { 500, 0.01 }, { 2200, 0.004 }, { 9000, 0.0015 } }
local tr = Mock.new_track("Vox")
Mock.add_audio_item(tr, { gen = Mock.tones(DARK), sr = 44100, nch = 2 }, 10, 6, "vox.wav")
tr.sel = true
check("frame runs", frame())
check("shows the track and item count", said("Vox") and said("1 audio item"))
check("no error", state.err == nil, state.err)

print("analyse")
G.click = "Analyse"
frame(1)
check("job started or done", state.job ~= nil or state.result ~= nil)
S.clock = S.clock + 1
frame(400)
check("analysis finished", state.result ~= nil and state.job == nil, state.err)
check("level text", said("Average") and said("Peak"), table.concat(G.text, " | "):sub(1, 300))
check("spectrum text", said("Measured slope"), table.concat(G.text, " | "):sub(1, 300))
check("4-band chart drawn", G.drawn > 10, G.drawn)
check("balanced after a full frame", G.depth == 0)
check("no error text", state.err == nil, state.err)

print("controls")
local before = state.summary.slope_after
G.slide["Target tilt (0 = pink noise)"] = 0
frame(2); G.slide = {}
check("tilt slider writes the setting", set.tilt == 0, set.tilt)
check("... and the result is recomputed live", state.summary.slope_after ~= before, state.summary.slope_after)
G.slide["Gain target"] = 1
frame(2); G.slide = {}
check("gain target combo switches to peak", set.gain_mode == 1)
G.slide["Gain target"] = 0
frame(2); G.slide = {}
G.click = "EQ stage (optional)"
frame(2)
check("EQ checkbox turns the EQ stage off", set.eq_on == 0)
check("... and the UI says so", said("EQ stage off"))
G.click = "EQ stage (optional)"
frame(2)
check("EQ stage back on", set.eq_on == 1)
G.slide["EQ amount"] = 40
frame(2); G.slide = {}
check("EQ amount slider writes the setting", set.eq_amount == 40, set.eq_amount)
G.slide["EQ amount"] = 100
frame(2); G.slide = {}

print("apply")
G.click = "Apply to new track"
frame(2)
check("duplicate created", #S.tracks == 2, #S.tracks)
check("ReaEQ on the item of the duplicate", S.tracks[2] and #S.tracks[2].fx == 0 and #S.tracks[2].items[1].take.fx == 1)
check("success message shown", said("gain-eq") or (state.msg or ""):find("gain-eq", 1, true) ~= nil, state.msg)
check("no error", state.err == nil, state.err)

print("live PREVIEW")
local function named(n) for _, t in ipairs(S.tracks) do if t.name == n then return t end end end
check("analysis still there after apply (duplicate mode)", state.result ~= nil)
G.click = "Live PREVIEW track"
frame(2)
check("checkbox turns it on", set.preview == 1)
S.clock = S.clock + 0.5
frame(2)
S.clock = S.clock + 0.5
frame(2)
check("PREVIEW track exists", named("PREVIEW") ~= nil and #S.tracks == 3, #S.tracks)
check("UI says it is live", said("PREVIEW track is live"))
G.slide["Target tilt (0 = pink noise)"] = -3
frame(2); G.slide = {}
S.clock = S.clock + 0.5
frame(2)
check("still one PREVIEW after a slider move", #S.tracks == 3)
G.click = "Keep PREVIEW as new track"
frame(2)
check("keeping it renames it, no PREVIEW left", named("PREVIEW") == nil and #S.tracks == 3 and set.preview == 0, #S.tracks)
check("no error", state.err == nil, state.err)

print("closing")
local real = reaper.ImGui_Begin
reaper.ImGui_Begin = function() return true, false end
check("frame reports closed", frame() == false)
reaper.ImGui_Begin = real

print(string.format("%d checks, %d failed", n, fails))
if fails > 0 then os.exit(1) end
