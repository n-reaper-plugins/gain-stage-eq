-- Loads the BUILT dist/GainStageEQ.lua under the fake REAPER and drives its own defer loop.
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local BUNDLE = assert(read("dist/GainStageEQ.lua"), "run tools/build.lua first")
local JSFX = read("dist/Effects/GainStageEQ/GainStageEQTrim.jsfx")
local RES = "/tmp/gse-test-bundle-resource"
local DARK = { { 100, 0.02 }, { 500, 0.01 }, { 2200, 0.004 }, { 9000, 0.0015 } }

local function scene()
  os.execute("rm -rf " .. RES)
  local S = Mock.install({ resource = RES })
  local tr = Mock.new_track("Vox")
  Mock.add_audio_item(tr, { gen = Mock.tones(DARK), sr = 44100, nch = 2 }, 10, 6, "vox.wav")
  tr.sel = true
  return S, tr
end
local function run()
  local fn, err = load(BUNDLE, "@/scripts/GainStageEQ.lua")
  assert(fn, err)
  return pcall(fn)
end

print("header")
do
  local ver = BUNDLE:match("^%-%- @description[^\n]*\n%-%- @version ([%d%.]+)")
  check("@version is on line 2 (ReaPack needs it in the header)", ver ~= nil, BUNDLE:sub(1, 120))
  check("no unreplaced placeholder", not BUNDLE:find("@@VERSION@@", 1, true))
  check("JSFX file was built", JSFX ~= nil and JSFX:find("desc:", 1, true) ~= nil)
end

print("without ReaImGui")
do
  local S = scene()
  local ok, err = run()
  check("script returns cleanly", ok, err)
  check("user is told about ReaImGui", S.mb[1] and S.mb[1]:find("ReaImGui", 1, true) ~= nil)
  check("no loop registered", #S.deferred == 0)
end

print("with ReaImGui")
do
  local S, tr = scene()
  local G = {}
  Stub.install(G)
  local ok, err = run()
  check("bundle loads and starts", ok, err)
  check("one deferred callback registered", #S.deferred == 1)
  Mock.pump(S, 3)
  check("window title carries the version", G.title and G.title:match("v%d+%.%d+%.%d+") ~= nil, G.title)
  G.click = "Analyse"
  Mock.pump(S, 3)
  Mock.pump(S, 400, 0.02)
  check("analysis ran inside the bundle's loop", table.concat(G.text, "\n"):find("Measured slope", 1, true) ~= nil)
  G.click = "Apply to new track"
  Mock.pump(S, 3)
  check("apply created the duplicate with a ReaEQ", #S.tracks == 2 and #S.tracks[2].fx == 1, #S.tracks)
  check("no console errors", #S.console == 0, S.console[1])
  check("still looping", #S.deferred == 1)
  reaper.ImGui_Begin = function() return true, false end
  Mock.pump(S, 2)
  check("closing the window stops the loop", #S.deferred == 0)
  check("settings saved", S.ext["GainStageEQ/tgt_avg"] ~= nil)
  S.atexit()
  check("atexit runs without error", true)
end

print(string.format("%d checks, %d failed", n, fails))
if fails > 0 then os.exit(1) end
