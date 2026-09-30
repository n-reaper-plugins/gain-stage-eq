-- Tests GainStageReaper.lua against the in-memory fake of the REAPER API (mock_reaper.lua).
-- Run from dev/:  lua tools/test_adapter.lua
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local Mock = require("mock_reaper")
local Core = require("GainStageCore")
local Jsfx = require("GainStageJsfx")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end
local function near(a, b, tol) return math.abs(a - b) <= tol end

local RES = "/tmp/gse-test-resource"
local DARK = { { 100, 0.02 }, { 500, 0.01 }, { 2200, 0.004 }, { 9000, 0.0015 } }   -- ~ -36 dBFS, dark spectrum

local function fresh(len)
  os.execute("rm -rf " .. RES)
  local S = Mock.install({ resource = RES })
  package.loaded["GainStageReaper"] = nil
  local Reaper = require("GainStageReaper")
  local set = Reaper.load_settings()
  local state = Reaper.new_state()
  local RA = Reaper.new(set, state)
  local src = { gen = Mock.tones(DARK), sr = 44100, nch = 2 }
  local tr = Mock.new_track("Vox")
  local item = Mock.add_audio_item(tr, src, 10, len or 6, "vox.wav")
  tr.sel = true
  return S, set, state, RA, tr, item, src
end

local function run_analysis(S, state, RA)
  RA.start_analysis()
  local guard = 0
  while state.job and guard < 20000 do
    RA.pump_job(); S.clock = S.clock + 0.02; guard = guard + 1
  end
  return guard
end

print("settings")
do
  local S = Mock.install({ resource = RES })
  package.loaded["GainStageReaper"] = nil
  local Reaper = require("GainStageReaper")
  local a = Reaper.load_settings()
  check("defaults", a.tgt_avg == -18 and a.gain_on == 1 and a.eq_on == 1 and a.dup == 1)
  S.ext["GainStageEQ/tgt_avg"] = "-14"
  check("saved value wins", Reaper.load_settings().tgt_avg == -14)
  local RA = Reaper.new(a, Reaper.new_state())
  a.tilt = -2.25; RA.save_settings()
  check("save_settings writes ExtState", S.ext["GainStageEQ/tilt"] == "-2.25")
end

print("selection")
do
  local S, set, state, RA, tr = fresh()
  RA.refresh_selection()
  check("track and item found", state.track == tr and #state.items == 1 and state.track_name:find("Vox", 1, true))
  local it2 = Mock.add_audio_item(tr, { gen = function() return 0 end }, 30, 3)
  it2.take.p.D_PLAYRATE = 2
  RA.refresh_selection()
  check("changed item count re-reads; playrate item skipped with a warning", #state.items == 1 and #state.warn == 1)
  tr.sel = false
  RA.refresh_selection()
  check("nothing selected", state.track == nil and #state.items == 0)
end

print("analysis")
do
  local S, set, state, RA = fresh()
  RA.refresh_selection()
  run_analysis(S, state, RA)
  check("job finishes with a result", state.job == nil and state.result and state.summary, state.err)
  local sum = state.summary
  check("summary ok", sum and sum.ok and sum.avg_db ~= nil)
  check("average ~ -35.8 dBFS", sum and near(sum.avg_db, -35.8, 0.5), sum and sum.avg_db)
  check("gain ~ +17.8 dB to reach -18", sum and near(sum.gain_db, 17.8, 0.6), sum and sum.gain_db)
  check("FFT windows collected", sum and sum.n_windows > 40, sum and sum.n_windows)
  check("dark input: highs boosted, lows cut", sum and sum.bands and sum.bands[4].corr > 0 and sum.bands[1].corr < 0)
  check("audio accessor destroyed", (S.accessors_destroyed or 0) >= 1 and state.aa == nil)
  check("not stale", not RA.analysis_stale())
  set.fft_max = 800
  check("fft_max makes it stale", RA.analysis_stale())
  set.fft_max = 400
  S.time_sel = { 11, 14 }
  check("time selection makes it stale", RA.analysis_stale())
  -- live: targets change the summary without re-reading
  set.tgt_avg = -12
  RA.recompute()
  check("target change is live", near(state.summary.gain_db, 23.8, 0.6), state.summary.gain_db)
  set.tgt_avg = -18
end

print("time selection / misses / cancel")
do
  local S, set, state, RA = fresh(10)
  S.time_sel = { 12, 15 }
  RA.refresh_selection()
  run_analysis(S, state, RA)
  check("range analysed", state.result and state.result.range and state.summary and state.summary.frames < 70, state.summary and state.summary.frames)
  S, set, state, RA = fresh()
  S.time_sel = { 100, 110 }
  RA.refresh_selection()
  run_analysis(S, state, RA)
  check("no overlap -> message", state.result == nil and state.err and state.err:find("overlaps", 1, true), state.err)
  S, set, state, RA = fresh()
  RA.refresh_selection()
  RA.start_analysis()
  for _ = 1, 3 do RA.pump_job(); S.clock = S.clock + 0.02 end
  RA.cancel_job()
  check("cancel clears job and accessor", state.job == nil and state.aa == nil)
end

print("two items are combined")
do
  local S, set, state, RA, tr = fresh()
  Mock.add_audio_item(tr, { gen = Mock.tones(DARK), sr = 48000, nch = 1 }, 30, 4, "b.wav")
  RA.refresh_selection()
  run_analysis(S, state, RA)
  check("both analysed (44.1k stereo + 48k mono)", state.result and #state.result.items == 2, state.err)
  check("average unchanged by combining", state.summary and near(state.summary.avg_db, -35.8, 0.6), state.summary and state.summary.avg_db)
end

print("apply: gain via item volume + ReaEQ, on a duplicate")
local applied_gain
do
  local S, set, state, RA, tr, item = fresh()
  RA.refresh_selection()
  run_analysis(S, state, RA)
  local sum = state.summary
  applied_gain = sum.gain_db
  RA.apply()
  check("no error", state.err == nil, state.err)
  local dup = S.tracks[2]
  check("duplicate created and named", dup and dup.name == "Vox [gain-eq]", dup and dup.name)
  check("item volume scaled by the gain", dup and near(dup.items[1].p.D_VOL, 10 ^ (sum.gain_db / 20), 1e-6), dup and dup.items[1].p.D_VOL)
  check("original untouched apart from mute", tr.items[1].p.D_VOL == 1 and tr.p.B_MUTE == 1 and #tr.fx == 0)
  check("one ReaEQ on the duplicate, renamed", dup and #dup.fx == 1 and dup.fx[1].kind == "reaeq" and dup.fx[1].renamed == "GainStageEQ")
  local vals = Mock.reaeq_values(dup.fx[1])
  for i, e in ipairs(sum.eq) do
    check("band " .. i .. " frequency", near(vals[i].freq / e.freq, 1, 0.01), vals[i].freq .. " vs " .. e.freq)
    check("band " .. i .. " gain", near(vals[i].gain, e.gain, 0.05), vals[i].gain .. " vs " .. e.gain)
    check("band " .. i .. " Q", near(vals[i].q, e.q, 0.1), vals[i].q .. " vs " .. e.q)
  end
  check("message names the work", state.msg and state.msg:find("item volume", 1, true) and state.msg:find("ReaEQ added", 1, true), state.msg)
  check("undo block", S.undo[#S.undo] == "Gain Stage EQ")
  check("analysis kept (duplicate mode)", state.result ~= nil)

  -- second run: the ReaEQ is updated, not stacked
  set.tilt = -3
  RA.recompute()
  local before = #dup.fx
  RA.refresh_selection()
  state.track = tr
  S.tracks[1].sel = true
  RA.apply()
  local dup2 = S.tracks[2]
  check("re-run makes another duplicate (of the ORIGINAL)", #S.tracks == 3)
  set.dup = 0
  -- in-place on the duplicate: select it, analyse again -> the item volume is part of the level now
  tr.sel = false; dup.sel = true
  RA.refresh_selection()
  run_analysis(S, state, RA)
  check("re-measured duplicate sits on target (idempotent gain)", state.summary and near(state.summary.avg_db, -18, 0.3), state.summary and state.summary.avg_db)
  check("... so no further gain is proposed", state.summary and math.abs(state.summary.gain_db) < 0.3, state.summary and state.summary.gain_db)
  RA.apply()
  check("in place: ReaEQ updated, not added twice", #dup.fx == 1, #dup.fx)
  check("in place: message says 'updated'", state.msg and state.msg:find("ReaEQ updated", 1, true), state.msg)
end

print("apply: other gain methods")
do
  local S, set, state, RA, tr = fresh()
  set.gain_via = 1; set.eq_on = 0
  RA.refresh_selection(); run_analysis(S, state, RA)
  RA.apply()
  local dup = S.tracks[2]
  check("track volume method", dup and near(dup.p.D_VOL, 10 ^ (state.summary.gain_db / 20), 1e-6) and dup.items[1].p.D_VOL == 1, dup and dup.p.D_VOL)
  check("EQ stage off -> no ReaEQ", dup and #dup.fx == 0)

  S, set, state, RA, tr = fresh()
  set.gain_via = 2; set.eq_on = 0
  RA.refresh_selection(); run_analysis(S, state, RA)
  RA.apply()
  dup = S.tracks[2]
  check("JSFX trim: file written", io.open(RES .. "/Effects/GainStageEQ/GainStageEQTrim.jsfx", "rb") ~= nil)
  check("JSFX trim: first in chain, gain set", dup and dup.fx[1] and dup.fx[1].kind == "jsfx" and near(dup.fx[1].params[1].val, state.summary.gain_db, 1e-6), state.err)
  check("JSFX trim: item volume untouched", dup and dup.items[1].p.D_VOL == 1)
  -- a second run on the same track adds to the trim instead of stacking a second instance
  set.dup = 0
  local g1 = dup.fx[1].params[1].val
  tr.sel = false; dup.sel = true
  RA.refresh_selection(); run_analysis(S, state, RA)
  RA.apply()
  check("JSFX trim updated in place", #dup.fx == 1, #dup.fx)
  check("jsfx text is current", io.open(RES .. "/Effects/GainStageEQ/GainStageEQTrim.jsfx", "rb"):read("*a") == Jsfx.text())
end

print("apply: stages, guards")
do
  local S, set, state, RA, tr = fresh()
  set.gain_on = 0
  RA.refresh_selection(); run_analysis(S, state, RA)
  RA.apply()
  local dup = S.tracks[2]
  check("gain stage off -> item volume unchanged, EQ still added", dup and dup.items[1].p.D_VOL == 1 and #dup.fx == 1)

  S, set, state, RA, tr = fresh()
  set.gain_on = 0; set.eq_on = 0
  RA.refresh_selection(); run_analysis(S, state, RA)
  RA.apply()
  check("both stages off -> nothing happens, says so", #S.tracks == 1 and state.msg and state.msg:find("Nothing to do", 1, true))

  S, set, state, RA, tr = fresh()
  RA.refresh_selection(); run_analysis(S, state, RA)
  tr.p.I_FOLDERDEPTH = 1
  RA.apply()
  check("folder parent refused in duplicate mode", state.err and state.err:find("Folder", 1, true) and #S.tracks == 1, state.err)
  tr.p.I_FOLDERDEPTH = 0
  set.dup = 0
  RA.apply()
  check("in place works, original changed", state.err == nil and #S.tracks == 1 and tr.items[1].p.D_VOL > 1 and #tr.fx == 1, state.err)
  check("in place with item volume: analysis dropped (it would double-count)", state.result == nil and state.summary == nil)

  S, set, state, RA, tr = fresh()
  set.dup = 0; set.mute_orig = 0
  set.tgt_avg = -35.8; set.gain_mode = 0; set.eq_on = 0
  RA.refresh_selection(); run_analysis(S, state, RA)
  set.tgt_avg = state.summary.avg_db
  RA.recompute()
  RA.apply()
  check("already on target -> nothing to do", state.msg and state.msg:find("Nothing to do", 1, true) and tr.items[1].p.D_VOL == 1, state.msg)
end

print("EQ parameter discovery")
do
  local S, set, state, RA, tr = fresh()
  local sumEq = { { kind = "lowshelf", freq = 200, q = 0.7, gain = -2 }, { kind = "bell", freq = 450, q = 0.6, gain = 1 },
                  { kind = "bell", freq = 2200, q = 0.6, gain = 2 }, { kind = "highshelf", freq = 5000, q = 0.7, gain = 4 } }
  local fx, created, notes = RA.apply_eq(tr, sumEq)
  check("ReaEQ created", created and #tr.fx == 1)
  check("no warnings", #notes == 0, notes[1])
  local v = Mock.reaeq_values(tr.fx[1])
  check("values reached (1.0 kHz+ goes through 'k' text)", near(v[4].freq / 5000, 1, 0.01) and near(v[3].gain, 2, 0.05), v[4].freq)
  -- a ReaEQ whose gain text is unusable is reported, not crashed
  tr.fx[1].params[2].fmt = function() return "n/a" end
  local _, _, notes2 = RA.apply_eq(tr, sumEq)
  check("unparseable parameter text is reported", #notes2 >= 1 and notes2[1]:find("band 1 gain", 1, true), notes2[1])
  -- too few parameters
  tr.fx[1].params = { tr.fx[1].params[1] }
  local ok, err = pcall(RA.apply_eq, tr, sumEq)
  check("unknown ReaEQ layout -> clear error", not ok and tostring(err):find("fewer than 4", 1, true), err)
end

print(string.format("%d checks, %d failed", n, fails))
if fails > 0 then os.exit(1) end
