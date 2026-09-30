-- @description Gain Stage EQ: set the level of a track (average / peak) and level its 4-band spectrum tilt with ReaEQ
-- @version 0.1.0
-- @about
--   Scans ALL items on ONE selected track (take audio, time selection respected), measures the average (RMS of
--   the active audio) and peak level, applies a gain to reach your target, then measures the energy in four
--   bands and sets up ReaEQ (low shelf, two bells, high shelf) to bring the spectrum onto a target tilt.
--   The gain stage and the EQ stage can be used separately. Works on a duplicate of the track by default.
--   Optional: a small JSFX trim (installed on demand) as the way to apply the gain.
--   Requires ReaImGui (ReaPack > ReaTeam Extensions).
-- BUNDLED BUILD of Gain Stage EQ v0.1.0 - edit the files in dev/src/, not this one.
local __preload = package.preload
__preload["GainStageCore"] = function(...)
-- GainStageCore.lua
-- Pure Lua (5.3/5.4). NO reaper.* calls in here, so it can be tested offline.
--
--   1. level analysis      : sample peak + gated average (RMS) power from 50 ms frames
--   2. spectrum analysis   : sparse FFT windows folded into 64 log-spaced bins; any 4-band split is a cheap sum
--   3. decisions           : gain in dB (average / peak / average-with-peak-ceiling) and 4 EQ corrections
--   4. EQ design           : RBJ filter model, so the 4 bands together hit the wanted correction at the band centres
--   5. parameter solver    : finds a plug-in parameter's normalised value from its *formatted* text (bisection)

local Core = {}
Core.VERSION = "0.1.0"

function Core.version_code(v)
  local a, b, c = (v or Core.VERSION):match("^(%d+)%.(%d+)%.(%d+)")
  return tonumber(a) * 10000 + tonumber(b) * 100 + tonumber(c)
end

local floor, ceil, max, min, abs, log, sqrt, pi = math.floor, math.ceil, math.max, math.min, math.abs, math.log, math.sqrt, math.pi
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function db10(x) return 10 * log(x + 1e-30, 10) end
local function log2(x) return log(x, 2) end
Core.clamp = clamp

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------
Core.DEFAULTS = {
  -- stages
  gain_on = 1,        -- 1 = gain stage active
  eq_on = 1,          -- 1 = EQ stage active (the EQ "phase" is optional)
  -- gain stage
  gain_mode = 2,      -- 0 = target average, 1 = target peak, 2 = target average but never above the peak ceiling
  tgt_avg = -18,      -- dBFS RMS of the active (non-silent) audio
  tgt_peak = -6,      -- dBFS sample peak (mode 1)
  ceil_db = -1,       -- dBFS peak ceiling (mode 2)
  max_gain = 30,      -- safety limit, +/- dB
  gain_via = 0,       -- 0 = item volume (all items on the track), 1 = track volume, 2 = JSFX trim (optional)
  -- spectrum / EQ stage
  f1 = 200,           -- Hz, split low | low-mid
  f2 = 1000,          -- Hz, split low-mid | high-mid
  f3 = 5000,          -- Hz, split high-mid | high
  tilt = -1.5,        -- target slope in dB per octave, relative to pink noise (0 = equal energy per octave)
  strength = 100,     -- % of the measured error that is corrected
  max_eq = 6,         -- dB, limit of every band's correction
  deadband = 0.5,     -- dB, corrections smaller than this are left at 0
  -- analysis
  gate_abs = -60,     -- dBFS, frames quieter than this are not "active"
  gate_rel = 45,      -- dB below the loudest frame, quieter frames are not "active"
  fft_max = 400,      -- max FFT windows per item (more = slower, steadier)
  -- output
  dup = 1,            -- 1 = work on a duplicate of the track
  mute_orig = 1,      -- mute the original after duplicating
  use_ts = 1,         -- 1 = follow the time selection when one exists
}
Core.ANALYSIS_KEYS = { "fft_max" }   -- gating / bands / targets are all live; only the audio read is not

Core.BAND_NAMES = { "Low", "Low-mid", "High-mid", "High" }

--------------------------------------------------------------------------------
-- FFT (radix-2, in place, tables cached per size)
--------------------------------------------------------------------------------
Core.FFT_N = 4096
Core.NB = 64          -- log-spaced bins between F_LO and F_HI
Core.F_LO = 30
Core.BLOCK = 32768    -- samples per read

local fft_cache = {}
local function fft_tables(N)
  local c = fft_cache[N]
  if c then return c end
  local rev, cs, sn, win = {}, {}, {}, {}
  local bits = floor(log2(N) + 0.5)
  for i = 0, N - 1 do
    local x, r = i, 0
    for _ = 1, bits do r = (r << 1) | (x & 1); x = x >> 1 end
    rev[i] = r
  end
  for k = 0, N // 2 - 1 do cs[k] = math.cos(2 * pi * k / N); sn[k] = -math.sin(2 * pi * k / N) end
  for i = 0, N - 1 do win[i] = 0.5 - 0.5 * math.cos(2 * pi * i / N) end     -- Hann
  c = { rev = rev, cs = cs, sn = sn, win = win }
  fft_cache[N] = c
  return c
end

-- re / im: 0-based arrays of length N (N a power of two). Forward transform, in place.
function Core.fft(re, im, N)
  local T = fft_tables(N)
  local rev = T.rev
  for i = 0, N - 1 do
    local j = rev[i]
    if j > i then re[i], re[j] = re[j], re[i]; im[i], im[j] = im[j], im[i] end
  end
  local cs, sn = T.cs, T.sn
  local size = 2
  while size <= N do
    local half, step = size // 2, N // size
    for start = 0, N - 1, size do
      local k = 0
      for j = start, start + half - 1 do
        local wr, wi = cs[k], sn[k]
        local l = j + half
        local tr = re[l] * wr - im[l] * wi
        local ti = re[l] * wi + im[l] * wr
        re[l], im[l] = re[j] - tr, im[j] - ti
        re[j], im[j] = re[j] + tr, im[j] + ti
        k = k + step
      end
    end
    size = size * 2
  end
end

-- FFT bin -> log bin, per sample rate
local binmap_cache = {}
function Core.spectrum_layout(sr)
  local c = binmap_cache[sr]
  if c then return c end
  local N, NB = Core.FFT_N, Core.NB
  local f_lo, f_hi = Core.F_LO, min(18000, 0.45 * sr)
  local span = log(f_hi / f_lo)
  local map, centers, edges = {}, {}, {}
  for k = 0, NB do edges[k] = f_lo * math.exp(span * k / NB) end
  for k = 1, NB do centers[k] = sqrt(edges[k - 1] * edges[k]) end
  for j = 1, N // 2 - 1 do
    local f = j * sr / N
    if f >= f_lo and f < f_hi then map[j] = floor(NB * log(f / f_lo) / span) + 1 end
  end
  c = { map = map, centers = centers, f_lo = f_lo, f_hi = f_hi }
  binmap_cache[sr] = c
  return c
end

--------------------------------------------------------------------------------
-- Reader: block DSP for ONE item. The adapter reads audio and calls process_block / fft_step.
--------------------------------------------------------------------------------
function Core.new_reader(P, sr, nch, n_total)
  local FL = max(1, floor(sr * 0.05))                       -- 50 ms level frames
  local nblocks = max(1, ceil(n_total / Core.BLOCK))
  return {
    P = P, sr = sr, nch = nch, n_total = n_total, pos = 0,
    FL = FL, acc = 0, cnt = 0, frames = {}, nfr = 0, peak = 0,
    K = clamp(ceil(P.fft_max / nblocks), 1, Core.BLOCK // Core.FFT_N),   -- FFT windows per block
    pending = {}, spec = {},
  }
end

-- t: interleaved samples (1-based), n frames. Level statistics + queueing of FFT windows.
function Core.process_block(rd, t, n)
  local nch, FL = rd.nch, rd.FL
  local acc, cnt, nfr, frames, peak = rd.acc, rd.cnt, rd.nfr, rd.frames, rd.peak
  local inv = 1 / nch
  for i = 0, n - 1 do
    local s = 0
    local base = i * nch
    for c = 1, nch do
      local x = t[base + c]
      s = s + x * x
      if x < 0 then x = -x end
      if x > peak then peak = x end
    end
    acc = acc + s * inv
    cnt = cnt + 1
    if cnt == FL then nfr = nfr + 1; frames[nfr] = acc / FL; acc, cnt = 0, 0 end
  end
  rd.acc, rd.cnt, rd.nfr, rd.peak = acc, cnt, nfr, peak

  -- windows for the spectrum: K evenly spread over this block, copied out as mono
  local N, K = Core.FFT_N, rd.K
  if n >= N then
    for w = 0, K - 1 do
      local start = (K == 1) and 0 or floor(w * (n - N) / (K - 1))
      local m = {}
      for j = 0, N - 1 do
        local b = (start + j) * nch
        local s = 0
        for c = 1, nch do s = s + t[b + c] end
        m[j] = s * inv
      end
      rd.pending[#rd.pending + 1] = m
    end
  end
end

-- one queued window -> power in the log bins. Returns true when it did something.
function Core.fft_step(rd)
  local m = table.remove(rd.pending)
  if not m then return false end
  local N, NB = Core.FFT_N, Core.NB
  local T = fft_tables(N)
  local win = T.win
  local L = Core.spectrum_layout(rd.sr)
  local re, im, e = {}, {}, 0
  for j = 0, N - 1 do
    local x = m[j]
    e = e + x * x
    re[j] = x * win[j]; im[j] = 0
  end
  Core.fft(re, im, N)
  local b = {}
  for k = 1, NB do b[k] = 0 end
  local map = L.map
  for j = 1, N // 2 - 1 do
    local k = map[j]
    if k then b[k] = b[k] + re[j] * re[j] + im[j] * im[j] end
  end
  rd.spec[#rd.spec + 1] = { wms = e / N, b = b }
  return true
end

function Core.finish_item(rd, info)
  info = info or {}
  local frames, nfr = rd.frames, rd.nfr
  if rd.cnt > rd.FL // 2 then nfr = nfr + 1; frames[nfr] = rd.acc / rd.cnt end   -- partial last frame
  local mx = 0
  for i = 1, nfr do if frames[i] > mx then mx = frames[i] end end
  local L = Core.spectrum_layout(rd.sr)
  return {
    name = info.name, pos = info.pos, len = info.len, index = info.index, item = info.item,
    sr = rd.sr, nch = rd.nch, frames = frames, nfr = nfr, max_ms = mx,
    peak_lin = rd.peak, spec = rd.spec, centers = L.centers, f_lo = L.f_lo, f_hi = L.f_hi,
    scale = info.scale or 1,          -- item volume already applied on the timeline (D_VOL)
  }
end

--------------------------------------------------------------------------------
-- RBJ filter model (used to design the EQ and to predict its response)
--------------------------------------------------------------------------------
local function biquad(kind, f0, gain_db, Q, fs)
  local A = 10 ^ (gain_db / 40)
  local w0 = 2 * pi * clamp(f0, 10, fs * 0.45) / fs
  local cw, sw = math.cos(w0), math.sin(w0)
  local alpha = sw / (2 * Q)
  local b0, b1, b2, a0, a1, a2
  if kind == "bell" then
    b0, b1, b2 = 1 + alpha * A, -2 * cw, 1 - alpha * A
    a0, a1, a2 = 1 + alpha / A, -2 * cw, 1 - alpha / A
  elseif kind == "lowshelf" then
    local s = 2 * sqrt(A) * alpha
    b0 = A * ((A + 1) - (A - 1) * cw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - s)
    a0 = (A + 1) + (A - 1) * cw + s;       a1 = -2 * ((A - 1) + (A + 1) * cw);    a2 = (A + 1) + (A - 1) * cw - s
  else -- highshelf
    local s = 2 * sqrt(A) * alpha
    b0 = A * ((A + 1) + (A - 1) * cw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - s)
    a0 = (A + 1) - (A - 1) * cw + s;       a1 = 2 * ((A - 1) - (A + 1) * cw);      a2 = (A + 1) - (A - 1) * cw - s
  end
  return b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
end

local function mag_db(kind, f0, gain_db, Q, f, fs)
  local b0, b1, b2, a1, a2 = biquad(kind, f0, gain_db, Q, fs)
  local w = 2 * pi * f / fs
  local c1, s1, c2, s2 = math.cos(w), -math.sin(w), math.cos(2 * w), -math.sin(2 * w)
  local nr, ni = b0 + b1 * c1 + b2 * c2, b1 * s1 + b2 * s2
  local dr, di = 1 + a1 * c1 + a2 * c2, a1 * s1 + a2 * s2
  return db10((nr * nr + ni * ni) / (dr * dr + di * di))
end

-- Combined response (dB) of a list of bands {kind, freq, gain, q} at frequency f.
function Core.eq_response_db(bands, f, fs)
  fs = fs or 48000
  local tot = 0
  for _, b in ipairs(bands) do tot = tot + mag_db(b.kind, b.freq, b.gain, b.q, f, fs) end
  return tot
end

--------------------------------------------------------------------------------
-- Decisions
--------------------------------------------------------------------------------
local function sinh(x) return (math.exp(x) - math.exp(-x)) / 2 end   -- math.sinh does not exist in Lua 5.3+ / REAPER

local function bell_q(f_a, f_b)
  local bw = log2(f_b / f_a)                         -- octaves between the split points
  return clamp(1 / (2 * sinh(log(2) / 2 * bw)), 0.3, 4)
end

-- Build 4 EQ bands whose COMBINED response hits the wanted corrections (dB) at the band centres.
function Core.design_eq(P, corr, centers)
  local f1, f2, f3 = P.f1, P.f2, P.f3
  local bands = {
    { kind = "lowshelf",  freq = f1,             q = 0.71,           gain = corr[1] },
    { kind = "bell",      freq = sqrt(f1 * f2),  q = bell_q(f1, f2), gain = corr[2] },
    { kind = "bell",      freq = sqrt(f2 * f3),  q = bell_q(f2, f3), gain = corr[3] },
    { kind = "highshelf", freq = f3,             q = 0.71,           gain = corr[4] },
  }
  local lim = min(18, P.max_eq * 2 + 2)
  for _ = 1, 30 do
    local worst = 0
    for i = 1, 4 do
      local resp = Core.eq_response_db(bands, centers[i])
      local e = corr[i] - resp
      if abs(e) > worst then worst = abs(e) end
      bands[i].gain = clamp(bands[i].gain + 0.6 * e, -lim, lim)
    end
    if worst < 0.02 then break end
  end
  return bands
end

-- items: results of finish_item. Returns a table with everything the UI / adapter needs.
-- Cheap: runs again on every slider change.
function Core.summarize(items, P)
  local out = { ok = false, n_items = #items }
  if #items == 0 then out.reason = "nothing analysed"; return out end

  ----------------------------------------------------------------- level
  local maxdb, peak = -200, 0
  for _, it in ipairs(items) do
    if it.max_ms > 0 then maxdb = max(maxdb, db10(it.max_ms * it.scale ^ 2)) end
    peak = max(peak, it.peak_lin * it.scale)
  end
  local gate = max(P.gate_abs, maxdb - P.gate_rel)
  local sum, n_act, n_all, sum_all = 0, 0, 0, 0
  for _, it in ipairs(items) do
    local s2 = it.scale ^ 2
    for i = 1, it.nfr do
      local v = it.frames[i] * s2
      n_all = n_all + 1; sum_all = sum_all + v
      if db10(v) > gate then sum = sum + v; n_act = n_act + 1 end
    end
  end
  out.gate_db, out.peak_db = gate, 20 * log(peak + 1e-12, 10)
  out.frames, out.active_frames = n_all, n_act
  out.active_pct = n_all > 0 and n_act / n_all * 100 or 0
  out.rms_all_db = n_all > 0 and db10(sum_all / n_all) or -200
  if n_act == 0 or peak <= 1e-9 then
    out.reason = "no signal above the silence gate"
    return out
  end
  out.avg_db = db10(sum / n_act)
  out.crest_db = out.peak_db - out.avg_db

  local g
  if P.gain_mode == 0 then g = P.tgt_avg - out.avg_db
  elseif P.gain_mode == 1 then g = P.tgt_peak - out.peak_db
  else
    g = P.tgt_avg - out.avg_db
    local lim = P.ceil_db - out.peak_db
    if lim < g then g = lim; out.gain_note = "limited by the peak ceiling" end
  end
  if abs(g) > P.max_gain then g = clamp(g, -P.max_gain, P.max_gain); out.gain_note = "limited by the max gain" end
  out.gain_db = g
  out.after_avg_db, out.after_peak_db = out.avg_db + g, out.peak_db + g

  ----------------------------------------------------------------- spectrum
  local edges = { Core.F_LO, P.f1, P.f2, P.f3, nil }
  local frac, nwin = { 0, 0, 0, 0 }, 0
  local f_hi
  for _, it in ipairs(items) do
    f_hi = f_hi and min(f_hi, it.f_hi) or it.f_hi
    -- which band does each log bin belong to (by its centre)?
    local bandof = {}
    for k, c in ipairs(it.centers) do
      bandof[k] = (c < P.f1 and 1) or (c < P.f2 and 2) or (c < P.f3 and 3) or 4
    end
    local s2 = it.scale ^ 2
    for _, w in ipairs(it.spec) do
      if db10(w.wms * s2) > gate then
        local b, tot = { 0, 0, 0, 0 }, 0
        for k = 1, #w.b do local v = w.b[k]; b[bandof[k]] = b[bandof[k]] + v; tot = tot + v end
        if tot > 0 then
          for i = 1, 4 do frac[i] = frac[i] + b[i] / tot end
          nwin = nwin + 1
        end
      end
    end
  end
  out.n_windows = nwin
  if nwin == 0 then out.spectrum_ok = false; out.spectrum_reason = "no active audio in the FFT windows"; out.ok = true; return out end
  edges[5] = f_hi
  local bands, xs = {}, {}
  for i = 1, 4 do
    local lo, hi = edges[i], edges[i + 1]
    local oct = log2(hi / lo)
    local fc = sqrt(lo * hi)
    bands[i] = { name = Core.BAND_NAMES[i], lo = lo, hi = hi, fc = fc, oct = oct,
                 lvl = db10(max(frac[i] / nwin, 1e-12) / oct) }
    xs[i] = log2(fc / 1000)
  end
  -- measured slope (least squares), and the target line with the same mean level
  local mx, my = 0, 0
  for i = 1, 4 do mx = mx + xs[i] / 4; my = my + bands[i].lvl / 4 end
  local sxx, sxy = 0, 0
  for i = 1, 4 do sxx = sxx + (xs[i] - mx) ^ 2; sxy = sxy + (xs[i] - mx) * (bands[i].lvl - my) end
  out.slope = sxy / sxx
  local A = 0
  for i = 1, 4 do A = A + (bands[i].lvl - P.tilt * xs[i]) / 4 end
  local corr, centers = {}, {}
  for i = 1, 4 do
    local b = bands[i]
    b.target = A + P.tilt * xs[i]
    b.err = b.target - b.lvl
    local c = clamp(b.err * P.strength / 100, -P.max_eq, P.max_eq)
    if abs(c) < P.deadband then c = 0 end
    b.corr = c
    corr[i], centers[i] = c, b.fc
  end
  out.bands = bands
  out.spectrum_ok = true
  out.eq = Core.design_eq(P, corr, centers)
  for i = 1, 4 do
    bands[i].achieved = Core.eq_response_db(out.eq, bands[i].fc)
    bands[i].after = bands[i].lvl + bands[i].achieved
  end
  -- slope of the corrected spectrum
  local my2 = 0
  for i = 1, 4 do my2 = my2 + bands[i].after / 4 end
  local sxy2 = 0
  for i = 1, 4 do sxy2 = sxy2 + (xs[i] - mx) * (bands[i].after - my2) end
  out.slope_after = sxy2 / sxx
  out.ok = true
  return out
end

function Core.analysis_stale(res, S, rg)
  if not res then return false end
  for _, k in ipairs(Core.ANALYSIS_KEYS) do
    if res.params[k] ~= S[k] then return true end
  end
  local old = res.range
  if (rg == nil) ~= (old == nil) then return true end
  if rg and (abs(rg[1] - old[1]) > 1e-6 or abs(rg[2] - old[2]) > 1e-6) then return true end
  return false
end

--------------------------------------------------------------------------------
-- Plug-in parameter solver: value <- normalised position, using only the plug-in's own text
--------------------------------------------------------------------------------
-- "1.5k" -> 1500, "-3.2 dB" -> -3.2, "-inf" -> -1e9, "440 Hz" -> 440, "2.00 oct" -> 2
function Core.parse_number(s)
  if type(s) ~= "string" then return nil end
  local low = s:lower()
  if low:match("^%s*%-inf") then return -1e9 end
  if low:match("^%s*%+?inf") then return 1e9 end
  local num, rest = s:match("^%s*([%+%-]?%d*%.?%d+)(.*)$")
  if not num then return nil end
  local v = tonumber(num)
  if not v then return nil end
  if rest:match("^%s*[kK]") then v = v * 1000 end
  return v
end

-- fmt(norm) -> number or nil. Finds norm in [0,1] whose value is closest to target.
-- Works for increasing and decreasing, linear and logarithmic mappings (anything monotonic).
-- Returns norm, achieved_value  (or nil, reason).
function Core.solve_norm(fmt, target, iters)
  local v0, v1 = fmt(0), fmt(1)
  if v0 == nil or v1 == nil then return nil, "the parameter text is not a number" end
  if abs(v1 - v0) < 1e-9 then return nil, "the parameter does not change" end
  local inc = v1 > v0
  if inc then
    if target <= v0 then return 0, v0 end
    if target >= v1 then return 1, v1 end
  else
    if target >= v0 then return 0, v0 end
    if target <= v1 then return 1, v1 end
  end
  local lo, hi = 0, 1
  local best, bv = 0.5, nil
  for _ = 1, iters or 40 do
    local mid = (lo + hi) / 2
    local v = fmt(mid)
    if v == nil then return nil, "the parameter text is not a number" end
    best, bv = mid, v
    if (v < target) == inc then lo = mid else hi = mid end
    if abs(v - target) < 1e-4 * max(1, abs(target)) then break end
  end
  return best, bv
end

return Core

end
__preload["GainStageJsfx"] = function(...)
-- GainStageJsfx.lua
-- Produces the text of Effects/GainStageEQ/GainStageEQTrim.jsfx (the OPTIONAL trim used when
-- "Apply gain via" is set to "JSFX trim"). Pure Lua: used by the build script and by the app
-- itself, which installs the file the first time it is needed.

local Core = require("GainStageCore")
local J = {}

J.FILE = "GainStageEQTrim.jsfx"
J.DIR = "GainStageEQ"
J.FX_NAME = "JS:GainStageEQ/GainStageEQTrim"   -- what TrackFX_AddByName is given
J.DESC = "GainStageEQ Trim"                     -- the desc: line; used to find the FX in a chain again

function J.text()
  local v = Core.VERSION
  return string.format([[
desc:%s
tags:utility gain
// Gain Stage EQ v%s - GENERATED by GainStageEQ.lua / tools/build.lua. Do not edit by hand.
// A plain gain in dB with a short glide (no zipper noise). The Gain Stage EQ action sets it
// when "Apply gain via" is "JSFX trim"; you can also use it on its own.

slider1:0<-60,24,0.01>Trim (dB)

@init
jsfx_version = %d;
g = 1;
tgt = 1;

@slider
tgt = 10^(slider1/20);
coef = 1 - exp(-1/(0.010*srate));

@sample
g += (tgt - g) * coef;
spl0 *= g;
spl1 *= g;

@gfx 260 26
gfx_set(0.85, 0.85, 0.85, 1);
gfx_x = 8; gfx_y = 6;
gfx_drawstr(sprintf(#, "Gain Stage EQ trim v%s: %%+.2f dB", slider1));
]], J.DESC, v, Core.version_code(v), v)
end

return J

end
__preload["GainStageReaper"] = function(...)
-- GainStageReaper.lua
-- Everything that talks to REAPER except the window: settings, selection, audio reading
-- (time-sliced), gain (item volume / track volume / optional JSFX trim) and the ReaEQ set-up.
-- The maths lives in GainStageCore.lua.

local Core = require("GainStageCore")
local Jsfx = require("GainStageJsfx")

local M = {}
local r = reaper
local EXT = "GainStageEQ"
local SCRIPT_NAME = "Gain Stage EQ"
M.EXT, M.SCRIPT_NAME = EXT, SCRIPT_NAME
M.EQ_LABEL = "GainStageEQ"      -- what the ReaEQ instance is renamed to, so a re-run updates it in place

function M.load_settings()
  local S = {}
  for k, v in pairs(Core.DEFAULTS) do S[k] = tonumber(r.GetExtState(EXT, k)) or v end
  return S
end

function M.new_state()
  return {
    track = nil, track_name = "", sel_count = 0, item_count = 0, items = {}, warn = {},
    job = nil, aa = nil, prog = 0,
    result = nil,      -- raw analysis of the items
    summary = nil,     -- Core.summarize(...) of it (live)
    err = nil, msg = nil, dirty = false,
  }
end

local function param_name(track, fx, p)
  local a, b = r.TrackFX_GetParamName(track, fx, p)
  if type(b) == "string" then return b end
  if type(a) == "string" then return a end
  return ""
end

function M.new(S, state)
  local RA = {}

  local function save_settings()
    for k, _ in pairs(Core.DEFAULTS) do r.SetExtState(EXT, k, tostring(S[k]), true) end
  end

  -- analysis range (project time) or nil = whole items
  local function get_range()
    if S.use_ts == 0 then return nil end
    local ts, te = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if te - ts > 0.01 then return { ts, te } end
    return nil
  end

  local function cancel_job()
    if state.aa then r.DestroyAudioAccessor(state.aa); state.aa = nil end
    state.job = nil
    state.prog = 0
  end

  ------------------------------------------------------------------------------
  -- Analysis. Same three phases as Spike Leveler: every REAPER audio call happens on the
  -- main thread, one block (or one FFT window) per step, inside the ~12 ms budget of pump_job.
  ------------------------------------------------------------------------------
  local function begin_item(entry, idx, count, range)
    local item, take = entry.item, entry.take
    local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local ipos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local det_lo, det_hi = 0, len
    if range then
      det_lo = math.max(0, range[1] - ipos)
      det_hi = math.min(len, range[2] - ipos)
    end
    if det_hi - det_lo < 0.2 then return nil end   -- does not overlap the time selection (or is tiny)

    local src = r.GetMediaItemTake_Source(take)
    local sr = math.floor(r.GetMediaSourceSampleRate(src) or 0)
    if sr <= 0 then sr = 44100 end
    local nch = math.floor(r.GetMediaSourceNumChannels(src) or 0)
    if nch < 1 then nch = 2 end

    local aa = r.CreateTakeAudioAccessor(take)
    state.aa = aa
    local t_start = r.GetAudioAccessorStartTime(aa)
    local t_end = r.GetAudioAccessorEndTime(aa)

    -- Probe: find which time base the accessor uses by looking for non-silent audio
    local last_ret = 99
    local function probe(delta)
      local pk, N = 0, 16384
      local pb = r.new_array(N * nch)
      for _, frac in ipairs({ 0.05, 0.2, 0.35, 0.5, 0.65, 0.8, 0.95 }) do
        local tt = t_start + delta + det_lo + math.max(0, (det_hi - det_lo) - N / sr) * frac
        pb.clear()
        last_ret = r.GetAudioAccessorSamples(aa, sr, nch, tt, N, pb)
        local tb = pb.table()
        for i = 1, N * nch do
          local v = tb[i]
          if v then
            if v < 0 then v = -v end
            if v > pk then pk = v end
          end
        end
      end
      return pk
    end
    local delta, probe_pk = 0, 0
    local soff = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    for _, cand in ipairs({ 0, ipos, soff }) do
      local pk = probe(cand)
      if pk > probe_pk then delta, probe_pk = cand, pk end
      if pk > 1e-4 then break end
    end
    local diag = string.format(
      "accessor start=%.3f end=%.3f | time offset=%.3f | take start offs=%.3f | probe peak=%.5f | %d Hz, %d ch | last ret=%s",
      t_start, t_end, delta, soff, probe_pk, sr, nch, tostring(last_ret))

    local n_total = math.floor((det_hi - det_lo) * sr)
    local rd = Core.new_reader(S, sr, nch, n_total)
    rd.idx, rd.count, rd.entry = idx, count, entry
    rd.aa, rd.t_start, rd.delta, rd.det_lo, rd.det_hi = aa, t_start, delta, det_lo, det_hi
    rd.ipos, rd.len, rd.probe_pk, rd.diag = ipos, len, probe_pk, diag
    rd.buf = r.new_array(Core.BLOCK * nch)
    local _, tname = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    rd.name = tname
    rd.scale = r.GetMediaItemInfo_Value(item, "D_VOL")
    if rd.scale <= 0 then rd.scale = 1 end
    return rd
  end

  -- one step; returns true when the item is completely read and processed
  local function read_step(rd)
    if #rd.pending > 0 then
      Core.fft_step(rd)
      return false
    end
    if rd.pos >= rd.n_total then
      r.DestroyAudioAccessor(rd.aa)
      state.aa = nil
      return true
    end
    local n = math.min(Core.BLOCK, rd.n_total - rd.pos)
    rd.buf.clear()
    rd.ret = r.GetAudioAccessorSamples(rd.aa, rd.sr, rd.nch,
      rd.t_start + rd.delta + rd.det_lo + rd.pos / rd.sr, n, rd.buf)
    Core.process_block(rd, rd.buf.table(), n)
    rd.pos = rd.pos + n
    state.prog = ((rd.idx - 1) + rd.pos / rd.n_total) / rd.count
    return false
  end

  local function recompute()
    if state.result then state.summary = Core.summarize(state.result.items, S) end
  end

  local function pump_job()
    local job = state.job
    if not job then return end
    local ok, err = pcall(function()
      local t0 = r.time_precise()
      repeat
        if job.phase == "begin" then
          job.idx = job.idx + 1
          if job.idx > #state.items then
            if #job.res.items == 0 then error("No audio item overlaps the time selection.") end
            state.job, state.prog = nil, 0
            state.result = job.res
            recompute()
            return
          end
          job.rd = begin_item(state.items[job.idx], job.idx, #state.items, job.range)
          if job.rd then job.phase = "read" end
        else
          if read_step(job.rd) then
            local rd = job.rd
            job.res.items[#job.res.items + 1] = Core.finish_item(rd, {
              name = rd.name, pos = rd.ipos, len = rd.len, index = rd.entry.index, item = rd.entry.item, scale = rd.scale })
            job.res.diag = job.res.diag or rd.diag
            job.rd = nil
            job.phase = "begin"
          end
        end
      until state.job ~= job or r.time_precise() - t0 >= 0.012
    end)
    if not ok then
      state.err = "Analysis error: " .. tostring(err)
      cancel_job()
    end
  end

  local function start_analysis()
    state.err, state.msg = nil, nil
    local P = {}
    for k, v in pairs(S) do P[k] = v end
    state.result, state.summary = nil, nil
    state.prog = 0
    local res = { items = {}, params = {}, range = get_range() }
    for _, k in ipairs(Core.ANALYSIS_KEYS) do res.params[k] = P[k] end
    state.job = { range = res.range, res = res, idx = 0, phase = "begin" }
  end

  local function analysis_stale()
    return Core.analysis_stale(state.result, S, get_range())
  end

  ------------------------------------------------------------------------------
  -- Selection
  ------------------------------------------------------------------------------
  local function refresh_selection()
    local n = r.CountSelectedTracks(0)
    state.sel_count = n
    local tr = (n == 1) and r.GetSelectedTrack(0, 0) or nil
    local cnt = tr and r.CountTrackMediaItems(tr) or 0
    if tr ~= state.track or cnt ~= state.item_count then
      cancel_job()
      state.track, state.item_count = tr, cnt
      state.result, state.summary, state.err, state.msg = nil, nil, nil, nil
      state.items, state.warn = {}, {}
      state.track_name = ""
      if tr then
        local _, nm = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
        local num = math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
        state.track_name = string.format("%d: %s", num, nm ~= "" and nm or "(unnamed)")
        for i = 0, cnt - 1 do
          local it = r.GetTrackMediaItem(tr, i)
          local tk = r.GetActiveTake(it)
          if tk and not r.TakeIsMIDI(tk) then
            local rate = r.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE")
            if math.abs(rate - 1) > 1e-9 then
              state.warn[#state.warn + 1] = string.format("Item %d skipped: playrate is not 1.0", i + 1)
            else
              state.items[#state.items + 1] = { item = it, take = tk, index = i }
            end
          end
        end
      end
    end
  end

  ------------------------------------------------------------------------------
  -- Optional JSFX (gain trim)
  ------------------------------------------------------------------------------
  local function read_file(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
  end

  -- writes Effects/GainStageEQ/GainStageEQTrim.jsfx when it is missing or from another version.
  -- returns true (written), false (up to date) or nil, error
  local function install_jsfx()
    local dir = r.GetResourcePath() .. "/Effects/" .. Jsfx.DIR
    local path = dir .. "/" .. Jsfx.FILE
    local text = Jsfx.text()
    if read_file(path) == text then return false, path end
    r.RecursiveCreateDirectory(dir, 0)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(text); f:close()
    return true, path
  end

  local function find_fx(track, needle, label)
    for i = 0, r.TrackFX_GetCount(track) - 1 do
      local _, nm = r.TrackFX_GetFXName(track, i, "")
      if nm and nm:find(needle, 1, true) then
        if not label then return i end
        local ok, rn = r.TrackFX_GetNamedConfigParm(track, i, "renamed_name")
        if ok and rn == label then return i end
      end
    end
    return nil
  end

  ------------------------------------------------------------------------------
  -- Gain
  ------------------------------------------------------------------------------
  local function apply_gain(track, g_db)
    local lin = 10 ^ (g_db / 20)
    if S.gain_via == 1 then
      r.SetMediaTrackInfo_Value(track, "D_VOL", r.GetMediaTrackInfo_Value(track, "D_VOL") * lin)
      return string.format("track volume %+.2f dB", g_db)
    elseif S.gain_via == 2 then
      local changed, err = install_jsfx()
      if changed == nil then error("Could not write the JSFX: " .. tostring(err)) end
      local idx = find_fx(track, Jsfx.DESC)
      if idx then
        local cur = r.TrackFX_GetParam(track, idx, 0)
        r.TrackFX_SetParam(track, idx, 0, Core.clamp(cur + g_db, -60, 24))
      else
        idx = r.TrackFX_AddByName(track, Jsfx.FX_NAME, false, -1000)   -- -1000 = insert at position 0
        if idx < 0 then
          error("REAPER does not know the JSFX yet (" .. Jsfx.FX_NAME .. "). Restart REAPER once, or use another gain method.")
        end
        r.TrackFX_SetParam(track, idx, 0, Core.clamp(g_db, -60, 24))
      end
      return string.format("JSFX trim %+.2f dB", g_db)
    end
    for i = 0, r.CountTrackMediaItems(track) - 1 do
      local it = r.GetTrackMediaItem(track, i)
      r.SetMediaItemInfo_Value(it, "D_VOL", r.GetMediaItemInfo_Value(it, "D_VOL") * lin)
    end
    return string.format("item volume %+.2f dB (%d items)", g_db, r.CountTrackMediaItems(track))
  end

  ------------------------------------------------------------------------------
  -- ReaEQ
  ------------------------------------------------------------------------------
  -- ReaEQ's parameters are found by NAME (Freq-..., Gain-..., Q/Bandwidth-...), in band order.
  local function eq_params(track, fx)
    local F, G, Q, E = {}, {}, {}, {}
    for p = 0, r.TrackFX_GetNumParams(track, fx) - 1 do
      local nm = param_name(track, fx, p):lower()
      if nm:match("^freq") then F[#F + 1] = p
      elseif nm:match("^gain") then G[#G + 1] = p
      elseif nm:match("^q[%-%s]") or nm == "q" then Q[#Q + 1] = { p = p, bw = false }
      elseif nm:match("^bw") or nm:match("^bandwidth") then Q[#Q + 1] = { p = p, bw = true }
      elseif nm:match("^enabled") then E[#E + 1] = p end
    end
    if #F < 4 or #G < 4 then return nil, "ReaEQ has fewer than 4 Freq/Gain parameters (found " .. #F .. "/" .. #G .. ")" end
    return { freq = F, gain = G, q = Q, enabled = E }
  end

  -- set a parameter so that its FORMATTED text reads `value`; returns the value that was reached
  local function set_by_text(track, fx, p, value)
    local function fmt(x)
      r.TrackFX_SetParamNormalized(track, fx, p, x)
      local _, s = r.TrackFX_GetFormattedParamValue(track, fx, p)
      return Core.parse_number(s)
    end
    local nrm, got = Core.solve_norm(fmt, value)
    if not nrm then return nil, got end
    r.TrackFX_SetParamNormalized(track, fx, p, nrm)
    return got
  end

  local function apply_eq(track, bands)
    local fx = find_fx(track, "ReaEQ", M.EQ_LABEL)
    local created = false
    if not fx then
      fx = r.TrackFX_AddByName(track, "ReaEQ (Cockos)", false, -1)
      if fx < 0 then fx = r.TrackFX_AddByName(track, "ReaEQ", false, -1) end
      if fx < 0 then error("Could not add ReaEQ to the track.") end
      pcall(r.TrackFX_SetNamedConfigParm, track, fx, "renamed_name", M.EQ_LABEL)
      created = true
    end
    local pr, why = eq_params(track, fx)
    if not pr then error(why) end
    for _, p in ipairs(pr.enabled) do r.TrackFX_SetParamNormalized(track, fx, p, 1) end
    local notes = {}
    for i, b in ipairs(bands) do
      local got_f, e1 = set_by_text(track, fx, pr.freq[i], b.freq)
      if not got_f then notes[#notes + 1] = "band " .. i .. " frequency: " .. tostring(e1) end
      local qd = pr.q[i]
      if qd then
        local val = b.q
        if qd.bw then val = 2 * math.log(1 / (2 * b.q) + math.sqrt(1 / (4 * b.q * b.q) + 1)) / math.log(2) end
        local _, e2 = set_by_text(track, fx, qd.p, val)
        if e2 and type(e2) == "string" then notes[#notes + 1] = "band " .. i .. " Q: " .. e2 end
      end
      local got_g, e3 = set_by_text(track, fx, pr.gain[i], b.gain)
      if not got_g then notes[#notes + 1] = "band " .. i .. " gain: " .. tostring(e3)
      elseif math.abs(got_g - b.gain) > 0.25 then
        notes[#notes + 1] = string.format("band %d gain is %.2f dB instead of %.2f", i, got_g, b.gain)
      end
    end
    return fx, created, notes
  end

  ------------------------------------------------------------------------------
  -- Apply
  ------------------------------------------------------------------------------
  local function eq_needed(sum)
    if not (S.eq_on ~= 0 and sum.spectrum_ok) then return false end
    for _, b in ipairs(sum.eq) do if math.abs(b.gain) >= 0.05 then return true end end
    return false
  end

  local function apply()
    state.err, state.msg = nil, nil
    local res, sum, src = state.result, state.summary, state.track
    if not (res and sum and sum.ok and src) then return end
    local do_gain = S.gain_on ~= 0 and sum.gain_db and math.abs(sum.gain_db) >= 0.005
    local do_eq = eq_needed(sum)
    if not do_gain and not do_eq then
      state.msg = "Nothing to do: the level and the spectrum are already on target (or both stages are off)."
      return
    end
    if S.dup ~= 0 and r.GetMediaTrackInfo_Value(src, "I_FOLDERDEPTH") == 1 then
      state.err = "Folder parent tracks cannot be duplicated here. Select a normal track (or switch 'Work on a duplicate' off)."
      return
    end

    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    local ok, err = pcall(function()
      local _, name = r.GetSetMediaTrackInfo_String(src, "P_NAME", "", false)
      name = (name ~= "" and name or "Track")
      local target = src
      if S.dup ~= 0 then
        r.SetOnlyTrackSelected(src)
        r.Main_OnCommand(40062, 0)                                    -- Track: Duplicate tracks
        local src_idx = r.GetMediaTrackInfo_Value(src, "IP_TRACKNUMBER") -- 1-based
        target = r.GetTrack(0, math.floor(src_idx))                    -- the track right below
        if not target or r.CountTrackMediaItems(target) ~= state.item_count then
          error("Could not locate the duplicated track.")
        end
        r.GetSetMediaTrackInfo_String(target, "P_NAME", name .. " [gain-eq]", true)
      end
      local parts = {}
      if do_gain then parts[#parts + 1] = apply_gain(target, sum.gain_db) end
      if do_eq then
        local fx, created, notes = apply_eq(target, sum.eq)
        parts[#parts + 1] = (created and "ReaEQ added" or "ReaEQ updated")
        if #notes > 0 then state.warn_eq = table.concat(notes, "; ") else state.warn_eq = nil end
      end
      if S.dup ~= 0 and S.mute_orig ~= 0 then r.SetMediaTrackInfo_Value(src, "B_MUTE", 1) end
      state.msg = (S.dup ~= 0 and ("Created '" .. name .. " [gain-eq]': ") or ("Changed '" .. name .. "': ")) .. table.concat(parts, ", ") .. "."
    end)
    r.SetOnlyTrackSelected(src)
    r.PreventUIRefresh(-1)
    r.Undo_EndBlock(SCRIPT_NAME, -1)
    r.UpdateArrange()
    r.TrackList_AdjustWindows(false)
    if not ok then state.err = tostring(err) end
    if ok and S.dup == 0 and do_gain and S.gain_via == 0 then
      -- item volumes changed under the analysis: it would double-count on the next Apply
      state.result, state.summary = nil, nil
    end
    save_settings()
  end

  RA.save_settings, RA.get_range, RA.cancel_job = save_settings, get_range, cancel_job
  RA.start_analysis, RA.pump_job, RA.analysis_stale = start_analysis, pump_job, analysis_stale
  RA.refresh_selection, RA.recompute, RA.apply = refresh_selection, recompute, apply
  RA.install_jsfx = install_jsfx
  RA.eq_needed = eq_needed
  RA.apply_eq, RA.apply_gain = apply_eq, apply_gain      -- exposed for the offline tests
  return RA
end

return M

end
__preload["GainStageUI"] = function(...)
-- GainStageUI.lua
-- ReaImGui window: left = track, actions, results (levels, 4-band spectrum, EQ), right = parameters.
-- Needs the ReaImGui extension; nothing here touches the project except through RA.

local Core = require("GainStageCore")

local M = {}
local r = reaper

local COL_WARN, COL_ERR, COL_OK = 0xFFCC44FF, 0xFF6666FF, 0x66FF88FF

function M.new(S, state, RA, title)
  local ui = {}
  local ctx = r.ImGui_CreateContext("Gain Stage EQ")

  local function slider(label, key, mn, mx, fmt)
    local ch, v = r.ImGui_SliderDouble(ctx, label, S[key], mn, mx, fmt)
    if ch then S[key] = v; state.dirty = true end
  end
  local function check(label, key)
    local ch, v = r.ImGui_Checkbox(ctx, label, S[key] ~= 0)
    if ch then S[key] = v and 1 or 0; state.dirty = true end
  end
  local function combo(label, key, items)
    local ch, v = r.ImGui_Combo(ctx, label, math.floor(S[key]), items)
    if ch then S[key] = v; state.dirty = true end
  end
  local function db(v) return string.format("%+.1f", v) end

  ------------------------------------------------------------------------------
  -- 4-band chart: bars = measured level per octave (relative to the mean), orange tick = target line,
  -- green dot = predicted result after the EQ.
  ------------------------------------------------------------------------------
  local function draw_bands(sum)
    local w = math.max(240, (r.ImGui_GetContentRegionAvail(ctx)))
    local h = 150
    local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
    local dl = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_Dummy(ctx, w, h)
    r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, 0x141414FF)
    local mean = 0
    for _, b in ipairs(sum.bands) do mean = mean + b.lvl / 4 end
    local rng = 6
    for _, b in ipairs(sum.bands) do
      rng = math.max(rng, math.abs(b.lvl - mean) + 2, math.abs(b.target - mean) + 2, math.abs(b.after - mean) + 2)
    end
    local cy = y0 + h / 2
    local function Y(v) return cy - Core.clamp(v - mean, -rng, rng) / rng * (h / 2 - 8) end
    r.ImGui_DrawList_AddLine(dl, x0, cy, x0 + w, cy, 0x55555588, 1.0)
    local bw = w / 4
    for i, b in ipairs(sum.bands) do
      local xa, xb = x0 + (i - 1) * bw + 10, x0 + i * bw - 10
      r.ImGui_DrawList_AddRectFilled(dl, xa, math.min(cy, Y(b.lvl)), xb, math.max(cy, Y(b.lvl)) + 1, 0x5A7FA8FF)
      r.ImGui_DrawList_AddLine(dl, xa - 4, Y(b.target), xb + 4, Y(b.target), 0xFFAA33FF, 2.0)
      local xm = (xa + xb) / 2
      r.ImGui_DrawList_AddRectFilled(dl, xm - 4, Y(b.after) - 4, xm + 4, Y(b.after) + 4, 0x66FF88FF)
      r.ImGui_DrawList_AddText(dl, xa, y0 + h - 16, 0xBBBBBBFF, b.name)
    end
    r.ImGui_Text(ctx, string.format("dB per octave, relative to the mean.  blue = measured, orange = target (%+.1f dB/oct), green = after EQ  (+/- %.0f dB)", S.tilt, rng))
  end

  ------------------------------------------------------------------------------
  local function draw_results(sum)
    r.ImGui_Separator(ctx)
    if not sum.ok or not sum.avg_db then
      r.ImGui_TextColored(ctx, COL_ERR, "No signal above the silence gate was found (" .. tostring(sum.reason) .. ").")
      if state.result and state.result.diag then r.ImGui_TextWrapped(ctx, state.result.diag) end
      return
    end
    r.ImGui_Text(ctx, "Level")
    r.ImGui_Text(ctx, string.format("Average %.1f dBFS (active audio: %.0f%% of the range, gate %.1f dBFS)   Peak %.1f dBFS   Crest %.1f dB",
      sum.avg_db, sum.active_pct, sum.gate_db, sum.peak_db, sum.crest_db))
    local gtxt = string.format("Gain stage: %s dB  ->  average %.1f, peak %.1f dBFS", db(sum.gain_db), sum.after_avg_db, sum.after_peak_db)
    if sum.gain_note then gtxt = gtxt .. "   (" .. sum.gain_note .. ")" end
    r.ImGui_TextColored(ctx, S.gain_on ~= 0 and COL_OK or 0x888888FF, gtxt .. (S.gain_on ~= 0 and "" or "   [stage off]"))

    r.ImGui_Separator(ctx)
    r.ImGui_Text(ctx, "Spectrum tilt (4 bands)")
    if not sum.spectrum_ok then
      r.ImGui_TextColored(ctx, COL_WARN, tostring(sum.spectrum_reason))
      return
    end
    r.ImGui_Text(ctx, string.format("Measured slope %+.2f dB/oct  ->  after EQ %+.2f dB/oct   (target %+.2f, %d FFT windows)",
      sum.slope, sum.slope_after, S.tilt, sum.n_windows))
    draw_bands(sum)
    for i, b in ipairs(sum.bands) do
      local e = sum.eq[i]
      r.ImGui_Text(ctx, string.format("%-9s %5.0f-%-5.0f Hz  level %+.1f  target %+.1f  correction %s dB   ReaEQ: %s %.0f Hz %s dB Q %.2f",
        b.name, b.lo, b.hi, b.lvl - sum.bands[1].lvl, b.target - sum.bands[1].lvl, db(b.corr),
        e.kind == "bell" and "bell" or (e.kind == "lowshelf" and "low shelf" or "high shelf"), e.freq, db(e.gain), e.q))
    end
    r.ImGui_TextColored(ctx, S.eq_on ~= 0 and COL_OK or 0x888888FF, S.eq_on ~= 0 and "EQ stage on" or "EQ stage off: no ReaEQ will be added")
  end

  local function draw_main()
    if state.sel_count == 0 then
      r.ImGui_TextColored(ctx, COL_WARN, "Select ONE track that contains audio items.")
    elseif state.sel_count > 1 then
      r.ImGui_TextColored(ctx, COL_WARN, "Multiple tracks selected. Select exactly ONE track.")
    else
      r.ImGui_Text(ctx, "Track " .. state.track_name)
      r.ImGui_Text(ctx, string.format("%d audio item(s) will be analysed (take audio, item volume included).", #state.items))
      for _, w in ipairs(state.warn) do r.ImGui_TextColored(ctx, COL_WARN, w) end
      if #state.items == 0 then r.ImGui_TextColored(ctx, COL_ERR, "No usable audio items on this track.") end
    end
    do
      local rg = RA.get_range()
      if rg then r.ImGui_Text(ctx, string.format("Range: time selection %.2f - %.2f s", rg[1], rg[2]))
      else r.ImGui_Text(ctx, "Range: whole items (no time selection)") end
    end
    r.ImGui_Separator(ctx)

    local busy = state.job ~= nil
    local can_analyse = state.track ~= nil and #state.items > 0 and not busy
    if not can_analyse then r.ImGui_BeginDisabled(ctx) end
    if r.ImGui_Button(ctx, "Analyse") then RA.start_analysis() end
    if not can_analyse then r.ImGui_EndDisabled(ctx) end
    if busy then
      r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx, "Cancel") then RA.cancel_job() end
      r.ImGui_ProgressBar(ctx, state.prog, -1, 0, string.format("%.0f%%", state.prog * 100))
    end

    local sum = state.summary
    local stale = RA.analysis_stale()
    if stale then r.ImGui_TextColored(ctx, COL_WARN, "Analysis settings / time selection changed: press Analyse again.") end
    local ready = sum and sum.ok and sum.avg_db and not busy and not stale and state.track ~= nil
    local can_apply = ready and ((S.gain_on ~= 0) or RA.eq_needed(sum))
    r.ImGui_SameLine(ctx)
    if not can_apply then r.ImGui_BeginDisabled(ctx) end
    if r.ImGui_Button(ctx, S.dup ~= 0 and "Apply to new track" or "Apply to this track") then RA.apply() end
    if not can_apply then r.ImGui_EndDisabled(ctx) end

    if state.err then r.ImGui_TextColored(ctx, COL_ERR, state.err) end
    if state.msg then r.ImGui_TextColored(ctx, COL_OK, state.msg) end
    if state.warn_eq then r.ImGui_TextColored(ctx, COL_WARN, "ReaEQ: " .. state.warn_eq) end

    if sum then draw_results(sum) end
  end

  local function draw_params()
    r.ImGui_Text(ctx, "Stages")
    check("Gain stage", "gain_on")
    r.ImGui_SameLine(ctx)
    check("EQ stage (optional)", "eq_on")
    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, "Gain stage (live)")
    combo("Gain target", "gain_mode", "Average level\0Peak level\0Average, but under a peak ceiling\0")
    if S.gain_mode ~= 1 then slider("Target average (RMS)", "tgt_avg", -40, -6, "%.1f dBFS") end
    if S.gain_mode == 1 then slider("Target peak", "tgt_peak", -24, 0, "%.1f dBFS") end
    if S.gain_mode == 2 then slider("Peak ceiling", "ceil_db", -12, 0, "%.1f dBFS") end
    slider("Max gain (safety)", "max_gain", 3, 48, "%.0f dB")
    combo("Apply gain via", "gain_via", "Item volume (all items)\0Track volume\0JSFX trim (optional)\0")
    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, "Spectrum / ReaEQ (live)")
    slider("Split 1  low | low-mid", "f1", 60, 500, "%.0f Hz")
    slider("Split 2  low-mid | high-mid", "f2", 400, 3000, "%.0f Hz")
    slider("Split 3  high-mid | high", "f3", 2000, 12000, "%.0f Hz")
    if S.f2 < S.f1 * 1.5 then S.f2 = S.f1 * 1.5 end
    if S.f3 < S.f2 * 1.5 then S.f3 = S.f2 * 1.5 end
    slider("Target tilt (0 = pink noise)", "tilt", -6, 3, "%+.1f dB/oct")
    slider("Strength", "strength", 0, 100, "%.0f %%")
    slider("Max correction per band", "max_eq", 0, 12, "%.1f dB")
    slider("Dead band", "deadband", 0, 3, "%.1f dB")
    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, "Analysis")
    slider("Silence gate (absolute)", "gate_abs", -90, -30, "%.0f dBFS")
    slider("Silence gate (below loudest)", "gate_rel", 20, 80, "%.0f dB")
    slider("FFT windows per item (re-analyse)", "fft_max", 100, 1500, "%.0f")
    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, "Output")
    check("Work on a duplicate of the track", "dup")
    if S.dup == 0 then r.ImGui_BeginDisabled(ctx) end
    check("Mute the original after duplicating", "mute_orig")
    if S.dup == 0 then r.ImGui_EndDisabled(ctx) end
    check("Follow time selection (when one exists)", "use_ts")
  end

  local function draw_ui()
    local flags = r.ImGui_TableFlags_Resizable() | r.ImGui_TableFlags_BordersInnerV()
    if r.ImGui_BeginTable(ctx, "layout", 2, flags) then
      r.ImGui_TableSetupColumn(ctx, "main", r.ImGui_TableColumnFlags_WidthStretch(), 0.64)
      r.ImGui_TableSetupColumn(ctx, "params", r.ImGui_TableColumnFlags_WidthStretch(), 0.36)
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableSetColumnIndex(ctx, 0)
      draw_main()
      r.ImGui_TableSetColumnIndex(ctx, 1)
      draw_params()
      r.ImGui_EndTable(ctx)
    end
  end

  -- one frame of the window; returns false once it was closed
  function ui.frame()
    r.ImGui_SetNextWindowSize(ctx, 1100, 640, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, title, true)
    if visible then
      local ok, e = pcall(draw_ui)
      if not ok then state.err = tostring(e) end
      r.ImGui_End(ctx)
    end
    return open
  end

  return ui
end

return M

end

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

  local open = ui.frame()
  if open then
    r.defer(loop)
  else
    RA.cancel_job()
    RA.save_settings()
  end
end

r.atexit(function()
  if state.aa then r.DestroyAudioAccessor(state.aa) end
  RA.save_settings()
end)

r.defer(loop)

