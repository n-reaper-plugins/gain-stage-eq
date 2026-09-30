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
