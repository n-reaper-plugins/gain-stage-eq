-- @description Gain Stage EQ: set the level of a track (average / peak) and level its 4-band spectrum tilt with ReaEQ
-- @version @@VERSION@@
-- @about
--   Scans ALL items on ONE selected track (take audio, time selection respected), measures the average (RMS of
--   the active audio) and peak level, applies a gain to reach your target, then measures the energy in four
--   bands and sets up ReaEQ (low shelf, two bells, high shelf) to bring the spectrum onto a target tilt.
--   The gain stage and the EQ stage can be used separately. Works on a duplicate of the track by default.
--   The ReaEQ is put on every audio ITEM of the result track (take FX). A live PREVIEW track follows your settings.
--   Optional: a small JSFX trim (installed on demand) as the way to apply the gain.
--   Requires ReaImGui (ReaPack > ReaTeam Extensions).

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

local SCRIPT_NAME = "Gain Stage EQ"

if not r.ImGui_CreateContext then
  r.MB("This script requires the ReaImGui extension.\nInstall it via ReaPack (ReaTeam Extensions).", SCRIPT_NAME, 0)
  return
end

local Core = require("GainStageCore")
local Reaper = require("GainStageReaper")
local UI = require("GainStageUI")

local S = Reaper.load_settings()
local state = Reaper.new_state()
local RA = Reaper.new(S, state)
local ui = UI.new(S, state, RA, SCRIPT_NAME .. " v" .. Core.VERSION .. "###gain_stage_eq_main")

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
local function loop()
  RA.refresh_selection()
  RA.pump_job()
  if state.dirty and state.result then RA.recompute() end
  state.dirty = false
  RA.pump_preview()

  local open = ui.frame()
  if open then
    r.defer(loop)
  else
    RA.shutdown()
    RA.save_settings()
  end
end

r.atexit(function()
  RA.shutdown()
  RA.save_settings()
end)

r.defer(loop)
