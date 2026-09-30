-- Offline tests for GainStageCore.lua (pure maths). Run from dev/:  lua tools/test_core.lua
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
-- REAPER's Lua has no deprecated math functions; make sure we do not rely on them
for _, k in ipairs({ "sinh", "cosh", "tanh", "pow", "atan2", "log10", "ldexp", "frexp", "mod" }) do math[k] = nil end
local Core = require("GainStageCore")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end
local function near(a, b, tol) return math.abs(a - b) <= tol end
local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
local function db(x) return 20 * math.log(x, 10) end

-- run the reader exactly like the adapter does
local function analyse(gen, len, P, sr, nch, scale)
  sr, nch = sr or 44100, nch or 2
  local total = math.floor(len * sr)
  local rd = Core.new_reader(P, sr, nch, total)
  local pos = 0
  while pos < total do
    local m = math.min(Core.BLOCK, total - pos)
    local t = {}
    for i = 0, m - 1 do
      local v = gen((pos + i) / sr)
      for c = 1, nch do t[i * nch + c] = v end
    end
    Core.process_block(rd, t, m)
    while Core.fft_step(rd) do end
    pos = pos + m
  end
  return Core.finish_item(rd, { name = "t", pos = 0, len = len, index = 0, scale = scale })
end

-- sum of sines: tones = { {freq, amp}, ... }
local function tones(list)
  return function(t)
    local s = 0
    for _, x in ipairs(list) do s = s + x[2] * math.sin(2 * math.pi * x[1] * t) end
    return s
  end
end

local P = copy(Core.DEFAULTS)

print("fft")
do
  local N = 16
  local re, im, ref_re, ref_im = {}, {}, {}, {}
  local x = {}
  for i = 0, N - 1 do x[i] = math.sin(i * 0.7) + 0.3 * math.cos(i * 2.1) + (i % 3) * 0.1 end
  for k = 0, N - 1 do
    local sr_, si_ = 0, 0
    for i = 0, N - 1 do
      sr_ = sr_ + x[i] * math.cos(2 * math.pi * k * i / N)
      si_ = si_ - x[i] * math.sin(2 * math.pi * k * i / N)
    end
    ref_re[k], ref_im[k] = sr_, si_
  end
  for i = 0, N - 1 do re[i], im[i] = x[i], 0 end
  Core.fft(re, im, N)
  local worst = 0
  for k = 0, N - 1 do worst = math.max(worst, math.abs(re[k] - ref_re[k]), math.abs(im[k] - ref_im[k])) end
  check("matches a naive DFT (N=16)", worst < 1e-9, worst)
  local N2 = 1024
  local a, b = {}, {}
  for i = 0, N2 - 1 do a[i] = math.sin(2 * math.pi * 50 * i / N2); b[i] = 0 end
  Core.fft(a, b, N2)
  local pk, pkk = 0, 0
  for k = 0, N2 // 2 do local p = a[k] ^ 2 + b[k] ^ 2; if p > pk then pk, pkk = p, k end end
  check("a sine lands in its bin", pkk == 50, pkk)
end

print("parse_number / solve_norm")
do
  check("plain", Core.parse_number("440.5") == 440.5)
  check("unit suffix", Core.parse_number("-3.2 dB") == -3.2)
  check("kilo suffix", Core.parse_number("1.5k") == 1500 and Core.parse_number("2.5 kHz") == 2500)
  check("-inf", Core.parse_number("-inf") < -1e8)
  check("junk", Core.parse_number("abc") == nil and Core.parse_number(nil) == nil)
  local logf = function(x) return 20 * (24000 / 20) ^ x end
  local nrm, v = Core.solve_norm(logf, 1000)
  check("log frequency mapping", nrm and near(v, 1000, 0.5), tostring(v))
  local lin = function(x) return -60 + 84 * x end
  nrm, v = Core.solve_norm(lin, -3.3)
  check("linear gain mapping", nrm and near(v, -3.3, 0.01), tostring(v))
  local dec = function(x) return 10 - 9.5 * x end
  nrm, v = Core.solve_norm(dec, 2.0)
  check("decreasing mapping", nrm and near(v, 2.0, 0.01), tostring(v))
  nrm, v = Core.solve_norm(lin, 500)
  check("target above range -> upper end", nrm == 1 and v == 24)
  nrm, v = Core.solve_norm(function() return nil end, 1)
  check("non-numeric text -> nil + reason", nrm == nil and v ~= nil)
  nrm = Core.solve_norm(function() return 3 end, 1)
  check("constant parameter -> nil", nrm == nil)
  local text_fmt = function(x) return Core.parse_number(string.format("%.2fk", (20 * (24000 / 20) ^ x) / 1000)) end
  nrm, v = Core.solve_norm(text_fmt, 2500)
  check("works through formatted text with k suffix", nrm and near(v, 2500, 15), tostring(v))
end

print("level: average, peak, gate")
local sine = analyse(tones({ { 1000, 0.1 } }), 3, P)
do
  local s = Core.summarize({ sine }, P)
  check("summary ok", s.ok and s.avg_db ~= nil, s.reason)
  check("average of a 0.1 sine = -23.0 dBFS", near(s.avg_db, -23.01, 0.1), s.avg_db)
  check("peak = -20 dBFS", near(s.peak_db, -20, 0.05), s.peak_db)
  check("crest factor ~ 3 dB", near(s.crest_db, 3.01, 0.15), s.crest_db)
  check("mode 2 default: gain = target - average (+5 dB)", near(s.gain_db, 5, 0.1), s.gain_db)
  local Q = copy(P); Q.gain_mode = 0; Q.tgt_avg = -12
  check("mode 0 uses the average", near(Core.summarize({ sine }, Q).gain_db, 11, 0.1))
  Q = copy(P); Q.gain_mode = 1; Q.tgt_peak = -6
  check("mode 1 uses the peak (+14 dB)", near(Core.summarize({ sine }, Q).gain_db, 14, 0.1))
  Q = copy(P); Q.gain_mode = 2; Q.tgt_avg = -6; Q.ceil_db = -3
  local s2 = Core.summarize({ sine }, Q)
  check("mode 2: ceiling wins (+17 dB, not +17.01)", near(s2.gain_db, 17, 0.05) and s2.gain_note ~= nil, s2.gain_db)
  check("after-peak sits on the ceiling", near(s2.after_peak_db, -3, 0.05), s2.after_peak_db)
  Q = copy(P); Q.gain_mode = 0; Q.tgt_avg = 20; Q.max_gain = 12
  s2 = Core.summarize({ sine }, Q)
  check("max gain limits", s2.gain_db == 12 and s2.gain_note ~= nil)
  Q = copy(P); Q.tgt_avg = -40
  check("negative gain works (-17 dB)", near(Core.summarize({ sine }, Q).gain_db, -17, 0.1))
end
do
  -- 2 s of tone, 2 s of silence
  local gated = analyse(function(t) if t < 2 then return 0.1 * math.sin(2 * math.pi * 1000 * t) end return 0 end, 4, P)
  local s = Core.summarize({ gated }, P)
  check("silence is ignored in the average", near(s.avg_db, -23.01, 0.15), s.avg_db)
  check("ungated RMS is ~3 dB lower", near(s.rms_all_db, s.avg_db - 3.01, 0.3), s.rms_all_db)
  check("active share ~ 50 %", near(s.active_pct, 50, 3), s.active_pct)
  local Q = copy(P); Q.gate_abs = -20
  check("a high gate finds nothing", not Core.summarize({ gated }, Q).avg_db and Core.summarize({ gated }, Q).reason ~= nil)
  -- quiet noise floor under the tone is ignored by the relative gate
  local floor_ = analyse(function(t) return (t < 2 and 0.1 or 0.0002) * math.sin(2 * math.pi * 1000 * t) end, 4, P)
  check("quiet section (-80 dBFS) ignored", near(Core.summarize({ floor_ }, P).avg_db, -23.01, 0.2))
  local sc = analyse(tones({ { 1000, 0.1 } }), 3, P, 44100, 2, 0.5)
  check("item volume on the timeline is part of the level (-6 dB)", near(Core.summarize({ sc }, P).avg_db, -29.03, 0.15), Core.summarize({ sc }, P).avg_db)
  check("silence -> reason, no crash", Core.summarize({ analyse(function() return 0 end, 2, P) }, P).reason ~= nil)
  check("no items -> reason", Core.summarize({}, P).reason ~= nil)
  local mono = analyse(tones({ { 1000, 0.1 } }), 2, P, 44100, 1)
  check("mono source: same level", near(Core.summarize({ mono }, P).avg_db, -23.01, 0.15))
  local two = Core.summarize({ sine, mono }, P)
  check("several items are combined", near(two.avg_db, -23.01, 0.15) and two.n_items == 2)
end

print("spectrum: four bands")
-- one tone per band; amplitude per band chosen from the wanted level per octave
local FC = { 100, 500, 2200, 9000 }
local function spectrum_signal(slope_db_per_oct)
  local edges = { 30, 200, 1000, 5000, 18000 }
  local list = {}
  for i = 1, 4 do
    local oct = math.log(edges[i + 1] / edges[i], 2)
    local fc = math.sqrt(edges[i] * edges[i + 1])
    local lvl = slope_db_per_oct * math.log(fc / 1000, 2)               -- wanted dB per octave
    local energy = 10 ^ (lvl / 10) * oct                                -- band energy
    list[i] = { FC[i], math.sqrt(2 * energy) * 0.004 }
  end
  return tones(list)
end
do
  local pink = analyse(spectrum_signal(0), 4, P)
  check("FFT windows were collected", #pink.spec > 20, #pink.spec)
  local Q = copy(P); Q.tilt = 0
  local s = Core.summarize({ pink }, Q)
  check("4 bands", s.spectrum_ok and #s.bands == 4, s.spectrum_reason)
  check("band edges follow the splits", s.bands[1].hi == 200 and s.bands[2].hi == 1000 and s.bands[3].hi == 5000)
  check("pink-like input measures ~0 dB/oct", near(s.slope, 0, 0.5), s.slope)
  local worst = 0
  for _, b in ipairs(s.bands) do worst = math.max(worst, math.abs(b.corr)) end
  check("pink input with tilt 0 -> no correction", worst <= 0.6, worst)

  local dark = analyse(spectrum_signal(-6), 4, P)
  s = Core.summarize({ dark }, Q)
  check("-6 dB/oct input measures about -6", near(s.slope, -6, 1), s.slope)
  check("dark input -> boost highs, cut lows", s.bands[4].corr > 0 and s.bands[1].corr < 0, s.bands[4].corr .. " / " .. s.bands[1].corr)
  check("corrections limited to +/- max_eq", math.abs(s.bands[4].corr) <= P.max_eq + 1e-9)
  check("slope after correction is closer to the target", math.abs(s.slope_after - Q.tilt) < math.abs(s.slope - Q.tilt), s.slope_after)
  for i = 1, 4 do
    local b = s.bands[i]
    if math.abs(b.corr) > 0 and math.abs(b.corr) < P.max_eq - 0.01 then
      check("combined EQ hits the wanted correction in band " .. i, near(b.achieved, b.corr, 0.6), b.achieved .. " vs " .. b.corr)
    end
  end
  check("EQ has 4 bands: shelf, bell, bell, shelf",
    #s.eq == 4 and s.eq[1].kind == "lowshelf" and s.eq[2].kind == "bell" and s.eq[3].kind == "bell" and s.eq[4].kind == "highshelf")
  check("EQ frequencies from the splits", near(s.eq[1].freq, 200, 1e-6) and near(s.eq[2].freq, math.sqrt(200 * 1000), 1e-6) and near(s.eq[4].freq, 5000, 1e-6))
  check("bell Q in a sensible range", s.eq[2].q > 0.3 and s.eq[2].q < 2, s.eq[2].q)

  local R = copy(Q); R.strength = 50
  local half = Core.summarize({ dark }, R)
  check("strength 50% halves the correction (unless limited)",
    near(half.bands[3].corr, s.bands[3].corr / 2, 0.3) or math.abs(s.bands[3].corr) >= P.max_eq - 1e-9,
    half.bands[3].corr .. " vs " .. s.bands[3].corr)
  R = copy(Q); R.deadband = 20
  local dead = Core.summarize({ dark }, R)
  check("dead band zeroes small moves", dead.bands[2].corr == 0 and dead.bands[3].corr == 0)
  R = copy(Q); R.max_eq = 2
  local lim = Core.summarize({ dark }, R)
  local okl = true
  for _, b in ipairs(lim.bands) do if math.abs(b.corr) > 2 + 1e-9 then okl = false end end
  check("max EQ limit", okl)
  R = copy(Q); R.tilt = -6
  local match = Core.summarize({ dark }, R)
  local w2 = 0
  for _, b in ipairs(match.bands) do w2 = math.max(w2, math.abs(b.corr)) end
  check("target tilt equal to the measured one -> nothing to do", w2 <= 1.0, w2)
  R = copy(Q); R.f1, R.f2, R.f3 = 150, 800, 4000
  local moved = Core.summarize({ dark }, R)
  check("changing the splits is live (no re-read)", moved.bands[1].hi == 150 and moved.bands[3].hi == 4000)
  R = copy(Q); R.deadband = 0; R.eq_amount = 100
  local full = Core.summarize({ dark }, R)
  R.eq_amount = 50
  local amt = Core.summarize({ dark }, R)
  local half_ok = true
  for i = 1, 4 do if not near(amt.bands[i].corr, full.bands[i].corr / 2, 1e-9) then half_ok = false end end
  check("EQ amount 50% halves every correction (also the limited ones)", half_ok)
  check("... and the predicted slope moves accordingly", amt.slope_after ~= full.slope_after and math.abs(amt.slope_after - Q.tilt) > math.abs(full.slope_after - Q.tilt))
  R.eq_amount = 0
  local zero = Core.summarize({ dark }, R)
  local zok = true
  for _, e in ipairs(zero.eq) do if math.abs(e.gain) > 1e-6 then zok = false end end
  check("EQ amount 0% -> flat EQ", zok)
  R = copy(Q); R.gate_abs = 0
  local none = Core.summarize({ dark }, R)
  check("everything gated -> no spectrum, no crash", none.avg_db == nil)
end
do
  -- silence between tone bursts must not dilute the spectrum
  local bursts = analyse(function(t)
    if t % 1 < 0.5 then return spectrum_signal(-6)(t) end
    return 0
  end, 6, P)
  local Q = copy(P); Q.tilt = 0
  local s = Core.summarize({ bursts }, Q)
  check("spectrum measured only on active windows", s.spectrum_ok and near(s.slope, -6, 1.2), s.slope)
end

print("eq design")
do
  local bands = Core.design_eq(P, { -4, 2, 3, 5 }, { 80, 450, 2200, 9000 })
  for i, want in ipairs({ -4, 2, 3, 5 }) do
    local got = Core.eq_response_db(bands, ({ 80, 450, 2200, 9000 })[i])
    check("response at centre " .. i .. " = wanted", near(got, want, 0.2), got)
  end
  local flat = Core.design_eq(P, { 0, 0, 0, 0 }, { 80, 450, 2200, 9000 })
  check("zero corrections -> flat EQ", near(Core.eq_response_db(flat, 1000), 0, 1e-6))
end

print("analysis staleness")
do
  local res = { params = { fft_max = 400 }, range = nil }
  check("fresh", not Core.analysis_stale(res, P, nil))
  local Q = copy(P); Q.fft_max = 800
  check("fft_max changed -> stale", Core.analysis_stale(res, Q, nil))
  Q = copy(P); Q.tgt_avg = -10
  check("targets are live -> not stale", not Core.analysis_stale(res, Q, nil))
  check("new time selection -> stale", Core.analysis_stale(res, P, { 1, 2 }))
end

print(string.format("%d checks, %d failed", n, fails))
if fails > 0 then os.exit(1) end
