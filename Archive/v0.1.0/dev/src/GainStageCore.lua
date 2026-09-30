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
