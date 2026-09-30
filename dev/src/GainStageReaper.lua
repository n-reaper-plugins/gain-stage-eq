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
M.PREVIEW_NAME = "PREVIEW"
-- The PREVIEW track is found by TAGS, not by name (rename it if you like):
--   P_EXT:GSE_ROLE = "preview", GSE_SRC = GUID of the source track, GSE_SRCMUTE = the source's mute state before we muted it
local E_ROLE, E_SRC, E_MUTE = "P_EXT:GSE_ROLE", "P_EXT:GSE_SRC", "P_EXT:GSE_SRCMUTE"
local function tget(tr, k) local ok, v = r.GetSetMediaTrackInfo_String(tr, k, "", false); return ok and v or "" end
local function tset(tr, k, v) r.GetSetMediaTrackInfo_String(tr, k, v, true) end
local function valid_track(t) return t ~= nil and r.ValidatePtr2(0, t, "MediaTrack*") end

function M.load_settings()
  local S = {}
  for k, v in pairs(Core.DEFAULTS) do S[k] = tonumber(r.GetExtState(EXT, k)) or v end
  return S
end

function M.new_state()
  return {
    track = nil, track_name = "", sel_count = 0, item_count = 0, items = {}, warn = {},
    job = nil, aa = nil, prog = 0, bypass = nil,
    prev = nil,        -- the live PREVIEW track: { track, src, muted, mute0, sig, checked }
    result = nil,      -- raw analysis of the items
    summary = nil,     -- Core.summarize(...) of it (live)
    err = nil, msg = nil, dirty = false,
  }
end

local function param_name(take, fx, p)
  local a, b = r.TakeFX_GetParamName(take, fx, p)
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

  -- our own ReaEQ (take FX) is switched off while its item is read, so the measurement is always of the
  -- audio WITHOUT our EQ (whether or not the accessor includes take FX); switched back on afterwards
  local function restore_bypass()
    local b = state.bypass
    state.bypass = nil
    if b and r.ValidatePtr2(0, b.take, "MediaItem_Take*") then pcall(r.TakeFX_SetEnabled, b.take, b.fx, true) end
  end

  local function cancel_job()
    if state.aa then r.DestroyAudioAccessor(state.aa); state.aa = nil end
    restore_bypass()
    state.job = nil
    state.prog = 0
  end

  -- index of OUR ReaEQ (renamed to EQ_LABEL) in a take's FX chain, or nil
  local function take_eq_index(take)
    for i = 0, r.TakeFX_GetCount(take) - 1 do
      local _, nm = r.TakeFX_GetFXName(take, i, "")
      if nm and nm:find("ReaEQ", 1, true) then
        local ok, rn = r.TakeFX_GetNamedConfigParm(take, i, "renamed_name")
        if ok and rn == M.EQ_LABEL then return i end
      end
    end
    return nil
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

    restore_bypass()
    local eqi = take_eq_index(take)
    if eqi and r.TakeFX_GetEnabled(take, eqi) then
      r.TakeFX_SetEnabled(take, eqi, false)
      state.bypass = { take = take, fx = eqi }
    end
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
      restore_bypass()
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
  local remove_preview   -- defined with the PREVIEW code below

  local function refresh_selection()
    local n = r.CountSelectedTracks(0)
    local tr = (n == 1) and r.GetSelectedTrack(0, 0) or nil
    local pv = state.prev
    if pv and valid_track(state.track) and (n == 0 or (tr and tr == pv.track)) then
      -- the source stays the source while its PREVIEW exists: clicking the PREVIEW track or the empty area changes nothing
      n, tr = 1, state.track
    end
    state.sel_count = n
    local cnt = tr and r.CountTrackMediaItems(tr) or 0
    if tr ~= state.track or cnt ~= state.item_count then
      cancel_job()
      if state.prev then
        r.Undo_BeginBlock(); r.PreventUIRefresh(1)
        remove_preview()
        r.PreventUIRefresh(-1); r.Undo_EndBlock(SCRIPT_NAME .. ": remove PREVIEW", -1)
      end
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
  -- Gain. ABSOLUTE with respect to `src` (the track the target was copied from; src == target when working in
  -- place): running it again with a new gain replaces the previous one, which is what the live PREVIEW needs.
  ------------------------------------------------------------------------------
  local function apply_gain(track, src, g_db)
    local lin = 10 ^ (g_db / 20)
    if S.gain_via == 1 then
      r.SetMediaTrackInfo_Value(track, "D_VOL", r.GetMediaTrackInfo_Value(src, "D_VOL") * lin)
      return string.format("track volume %+.2f dB", g_db)
    elseif S.gain_via == 2 then
      local base = 0
      local si = find_fx(src, Jsfx.DESC)
      if si then base = r.TrackFX_GetParam(src, si, 0) end
      local idx = find_fx(track, Jsfx.DESC)
      if idx then
        r.TrackFX_SetParam(track, idx, 0, Core.clamp(base + g_db, -60, 24))
      elseif math.abs(g_db) > 1e-9 then
        local changed, err = install_jsfx()
        if changed == nil then error("Could not write the JSFX: " .. tostring(err)) end
        idx = r.TrackFX_AddByName(track, Jsfx.FX_NAME, false, -1000)   -- -1000 = insert at position 0
        if idx < 0 then
          error("REAPER does not know the JSFX yet (" .. Jsfx.FX_NAME .. "). Restart REAPER once, or use another gain method.")
        end
        r.TrackFX_SetParam(track, idx, 0, Core.clamp(base + g_db, -60, 24))
      end
      return string.format("JSFX trim %+.2f dB", g_db)
    end
    local n = r.CountTrackMediaItems(track)
    for i = 0, n - 1 do
      local it = r.GetTrackMediaItem(track, i)
      local sit = (src == track) and it or r.GetTrackMediaItem(src, i)
      if sit then r.SetMediaItemInfo_Value(it, "D_VOL", r.GetMediaItemInfo_Value(sit, "D_VOL") * lin) end
    end
    return string.format("item volume %+.2f dB (%d items)", g_db, n)
  end

  ------------------------------------------------------------------------------
  -- ReaEQ as TAKE FX: one instance per audio item (renamed EQ_LABEL so a re-run updates it in place).
  -- Its parameters are found by NAME (Freq-..., Gain-..., Q/Bandwidth-...), in band order.
  ------------------------------------------------------------------------------
  local function eq_params(take, fx)
    local F, G, Q, E = {}, {}, {}, {}
    for p = 0, r.TakeFX_GetNumParams(take, fx) - 1 do
      local nm = param_name(take, fx, p):lower()
      if nm:match("^freq") then F[#F + 1] = p
      elseif nm:match("^gain") then G[#G + 1] = p
      elseif nm:match("^q[%-%s]") or nm == "q" then Q[#Q + 1] = { p = p, bw = false }
      elseif nm:match("^bw") or nm:match("^bandwidth") then Q[#Q + 1] = { p = p, bw = true }
      elseif nm:match("^enabled") then E[#E + 1] = p end
    end
    if #F < 4 or #G < 4 then return nil, "ReaEQ has fewer than 4 Freq/Gain parameters (found " .. #F .. "/" .. #G .. ")" end
    return { freq = F, gain = G, q = Q, enabled = E }
  end

  -- set a parameter so that its FORMATTED text reads `value`; returns norm, value reached (or nil, reason)
  local function set_by_text(take, fx, p, value)
    local function fmt(x)
      r.TakeFX_SetParamNormalized(take, fx, p, x)
      local _, s = r.TakeFX_GetFormattedParamValue(take, fx, p)
      return Core.parse_number(s)
    end
    local nrm, got = Core.solve_norm(fmt, value)
    if not nrm then return nil, got end
    r.TakeFX_SetParamNormalized(take, fx, p, nrm)
    return nrm, got
  end

  -- ReaEQ on one take (added when missing). returns fx index, created
  local function eq_ensure(take)
    local fx = take_eq_index(take)
    if fx then return fx, false end
    fx = r.TakeFX_AddByName(take, "ReaEQ (Cockos)", -1)
    if fx < 0 then fx = r.TakeFX_AddByName(take, "ReaEQ", -1) end
    if fx < 0 then error("Could not add ReaEQ to an item.") end
    pcall(r.TakeFX_SetNamedConfigParm, take, fx, "renamed_name", M.EQ_LABEL)
    return fx, true
  end

  local function audio_takes(track)
    local list = {}
    for i = 0, r.CountTrackMediaItems(track) - 1 do
      local tk = r.GetActiveTake(r.GetTrackMediaItem(track, i))
      if tk and not r.TakeIsMIDI(tk) then list[#list + 1] = tk end
    end
    return list
  end

  -- Solve the band values ONCE (on the first item, through the plug-in's own text) and copy the normalised
  -- values to the other items' instances: same plug-in, same mapping, a fraction of the API calls.
  -- returns number of items, number of instances created, notes
  local function apply_eq(track, bands)
    local takes = audio_takes(track)
    if #takes == 0 then error("There is no audio item to put the ReaEQ on.") end
    local notes, created_n, pr, norms = {}, 0, nil, nil
    for n, tk in ipairs(takes) do
      local fx, created = eq_ensure(tk)
      if created then created_n = created_n + 1 end
      if n == 1 then
        local why
        pr, why = eq_params(tk, fx)
        if not pr then error(why) end
        norms = { f = {}, g = {}, q = {} }
        for _, p in ipairs(pr.enabled) do r.TakeFX_SetParamNormalized(tk, fx, p, 1) end
        for i, b in ipairs(bands) do
          local nf, e1 = set_by_text(tk, fx, pr.freq[i], b.freq)
          if not nf then notes[#notes + 1] = "band " .. i .. " frequency: " .. tostring(e1) end
          norms.f[i] = nf
          local qd = pr.q[i]
          if qd then
            local val = b.q
            if qd.bw then val = 2 * math.log(1 / (2 * b.q) + math.sqrt(1 / (4 * b.q * b.q) + 1)) / math.log(2) end
            local nq, e2 = set_by_text(tk, fx, qd.p, val)
            if not nq and type(e2) == "string" then notes[#notes + 1] = "band " .. i .. " Q: " .. e2 end
            norms.q[i] = nq
          end
          local ng, got_g = set_by_text(tk, fx, pr.gain[i], b.gain)
          if not ng then notes[#notes + 1] = "band " .. i .. " gain: " .. tostring(got_g)
          elseif math.abs(got_g - b.gain) > 0.25 then
            notes[#notes + 1] = string.format("band %d gain is %.2f dB instead of %.2f", i, got_g, b.gain)
          end
          norms.g[i] = ng
        end
      else
        for _, p in ipairs(pr.enabled) do r.TakeFX_SetParamNormalized(tk, fx, p, 1) end
        for i = 1, #bands do
          if norms.f[i] then r.TakeFX_SetParamNormalized(tk, fx, pr.freq[i], norms.f[i]) end
          if norms.q[i] and pr.q[i] then r.TakeFX_SetParamNormalized(tk, fx, pr.q[i].p, norms.q[i]) end
          if norms.g[i] then r.TakeFX_SetParamNormalized(tk, fx, pr.gain[i], norms.g[i]) end
        end
      end
    end
    return #takes, created_n, notes
  end

  -- removes OUR ReaEQ instances from the items of a track (nothing else). returns how many
  local function remove_eq(track)
    local n = 0
    for _, tk in ipairs(audio_takes(track)) do
      local fx = take_eq_index(tk)
      while fx do r.TakeFX_Delete(tk, fx); n = n + 1; fx = take_eq_index(tk) end
    end
    return n
  end

  local function eq_needed(sum)
    if not (S.eq_on ~= 0 and sum.spectrum_ok) then return false end
    for _, b in ipairs(sum.eq) do if math.abs(b.gain) >= 0.05 then return true end end
    return false
  end

  -- gain + EQ on `target` (a copy of `src`, or src itself). is_copy: also undo what a previous sync put there.
  -- returns list of text parts, notes
  local function build(target, src, sum, is_copy)
    local parts, notes = {}, {}
    if S.gain_on ~= 0 and sum.gain_db and math.abs(sum.gain_db) >= 0.005 then
      parts[#parts + 1] = apply_gain(target, src, sum.gain_db)
    elseif is_copy then
      apply_gain(target, src, 0)
    end
    if eq_needed(sum) then
      local n, created, nt = apply_eq(target, sum.eq)
      notes = nt
      parts[#parts + 1] = (created > 0 and "ReaEQ added to " or "ReaEQ updated on ") .. n .. " item" .. (n == 1 and "" or "s")
    elseif is_copy then
      remove_eq(target)
    end
    return parts, notes
  end

  ------------------------------------------------------------------------------
  -- Track helpers
  ------------------------------------------------------------------------------
  local function select_state()
    local list = {}
    for i = 0, r.CountSelectedTracks(0) - 1 do list[#list + 1] = r.GetSelectedTrack(0, i) end
    return list
  end
  local function restore_selection(list)
    for i = 0, r.CountTracks(0) - 1 do r.SetTrackSelected(r.GetTrack(0, i), false) end
    for _, t in ipairs(list) do if valid_track(t) then r.SetTrackSelected(t, true) end end
  end

  -- Track: Duplicate tracks. The copy sits right below `src`; the user's selection is put back.
  local function duplicate_track(src)
    local sel = select_state()
    r.SetOnlyTrackSelected(src)
    r.Main_OnCommand(40062, 0)
    local idx = math.floor(r.GetMediaTrackInfo_Value(src, "IP_TRACKNUMBER"))    -- 1-based = 0-based index of the track below
    local t = r.GetTrack(0, idx)
    restore_selection(sel)
    if not t or r.CountTrackMediaItems(t) ~= r.CountTrackMediaItems(src) then
      error("Could not locate the duplicated track.")
    end
    return t
  end

  ------------------------------------------------------------------------------
  -- Live PREVIEW track: a copy of the source with the current gain + EQ, re-synced ~0.25 s after the last
  -- change. The source is muted meanwhile (optional) and un-muted when the PREVIEW goes away.
  ------------------------------------------------------------------------------
  local function find_preview(src)
    local guid = r.GetTrackGUID(src)
    for i = 0, r.CountTracks(0) - 1 do
      local t = r.GetTrack(0, i)
      if tget(t, E_ROLE) == "preview" and tget(t, E_SRC) == guid then return t end
    end
    return nil
  end

  local function unmute_source(pv)
    if pv.muted and valid_track(pv.src) then r.SetMediaTrackInfo_Value(pv.src, "B_MUTE", pv.mute0 or 0) end
    pv.muted = false
  end

  -- deletes the PREVIEW track and gives the source its mute state back. The caller wraps this in an undo block.
  remove_preview = function()
    local pv = state.prev
    state.prev, state.prev_seen, state.prev_fail = nil, nil, nil
    if not pv then return end
    unmute_source(pv)
    if valid_track(pv.track) then r.DeleteTrack(pv.track) end
  end

  -- are the PREVIEW's items where the source's items are?
  local function preview_matches(pv)
    if not (valid_track(pv.track) and valid_track(pv.src)) then return false end
    local n = r.CountTrackMediaItems(pv.src)
    if r.CountTrackMediaItems(pv.track) ~= n then return false end
    for i = 0, n - 1 do
      local a, b = r.GetTrackMediaItem(pv.src, i), r.GetTrackMediaItem(pv.track, i)
      if math.abs(r.GetMediaItemInfo_Value(a, "D_POSITION") - r.GetMediaItemInfo_Value(b, "D_POSITION")) > 1e-6
         or math.abs(r.GetMediaItemInfo_Value(a, "D_LENGTH") - r.GetMediaItemInfo_Value(b, "D_LENGTH")) > 1e-6 then
        return false
      end
    end
    return true
  end

  local function preview_sig(sum)
    local t = { string.format("%.3f", (S.gain_on ~= 0 and sum.gain_db) or 0), S.gain_on, S.gain_via, S.eq_on, S.prev_mute }
    if eq_needed(sum) then
      for _, b in ipairs(sum.eq) do t[#t + 1] = string.format("%.1f/%.3f/%.3f", b.freq, b.gain, b.q) end
    else
      t[#t + 1] = "noeq"
    end
    return table.concat(t, "|")
  end

  local function sync_preview(sum, sig)
    local src = state.track
    if not valid_track(src) then return end
    local pv = state.prev
    local creating = false
    if pv and not (valid_track(pv.track) and preview_matches(pv)) then
      -- deleted by hand, or the source items moved / changed: start again
      creating = true
    elseif not pv then
      creating = true
    end
    if creating then r.Undo_BeginBlock() end
    r.PreventUIRefresh(1)
    local ok, err = pcall(function()
      if creating then
        if pv then
          unmute_source(pv)
          if valid_track(pv.track) then r.DeleteTrack(pv.track) end
          state.prev = nil
        end
        local t = find_preview(src)                       -- one left over from an earlier session?
        local adopted = false
        if t and r.CountTrackMediaItems(t) == r.CountTrackMediaItems(src) then
          adopted = true
        elseif t then
          r.DeleteTrack(t); t = nil
        end
        if r.GetMediaTrackInfo_Value(src, "I_FOLDERDEPTH") == 1 then
          error("A folder parent track cannot be previewed. Select a normal track.")
        end
        if not t then
          t = duplicate_track(src)
          tset(t, E_ROLE, "preview"); tset(t, E_SRC, r.GetTrackGUID(src))
          r.GetSetMediaTrackInfo_String(t, "P_NAME", M.PREVIEW_NAME, true)
        end
        pv = { track = t, src = src, muted = false }
        if adopted then
          local m = tget(t, E_MUTE)
          if m ~= "" and r.GetMediaTrackInfo_Value(src, "B_MUTE") == 1 then pv.muted, pv.mute0 = true, tonumber(m) or 0 end
        end
        r.SetMediaTrackInfo_Value(t, "B_MUTE", 0)
        state.prev = pv
      end
      -- source mute
      if S.prev_mute ~= 0 then
        if not pv.muted then
          pv.mute0 = r.GetMediaTrackInfo_Value(src, "B_MUTE")
          tset(pv.track, E_MUTE, tostring(pv.mute0))
          r.SetMediaTrackInfo_Value(src, "B_MUTE", 1)
          pv.muted = true
        end
      elseif pv.muted then
        unmute_source(pv)
        tset(pv.track, E_MUTE, "")
      end
      local _, notes = build(pv.track, src, sum, true)
      state.warn_eq = (#notes > 0) and table.concat(notes, "; ") or nil
      pv.sig = sig
    end)
    r.PreventUIRefresh(-1)
    if creating then r.Undo_EndBlock(SCRIPT_NAME .. ": PREVIEW", -1) end
    r.UpdateArrange()
    r.TrackList_AdjustWindows(false)
    if not ok then
      state.err = "PREVIEW: " .. tostring(err)
      state.prev_fail = sig          -- do not retry the same thing every frame
    else
      state.err = nil
      state.prev_fail = nil
    end
  end

  local function pump_preview()
    local pv = state.prev
    local sum = state.summary
    if S.preview == 0 or not state.track then
      if pv then
        r.Undo_BeginBlock(); r.PreventUIRefresh(1); remove_preview(); r.PreventUIRefresh(-1)
        r.Undo_EndBlock(SCRIPT_NAME .. ": remove PREVIEW", -1)
        r.UpdateArrange()
      end
      state.prev_fail = nil
      return
    end
    if not (sum and sum.ok and sum.avg_db) then
      if pv and not state.job then                       -- nothing left to preview (a running analysis keeps it)
        r.Undo_BeginBlock(); r.PreventUIRefresh(1); remove_preview(); r.PreventUIRefresh(-1)
        r.Undo_EndBlock(SCRIPT_NAME .. ": remove PREVIEW", -1)
        r.UpdateArrange()
      end
      return
    end
    local now = r.time_precise()
    local sig = preview_sig(sum)
    if sig ~= state.prev_seen then state.prev_seen, state.prev_at = sig, now end
    if pv and pv.sig == sig then
      if now - (pv.checked or 0) > 0.5 then                -- cheap structure check, twice a second
        pv.checked = now
        if not (valid_track(pv.track) and preview_matches(pv)) then pv.sig = nil end
      end
      return
    end
    if state.prev_fail == sig then return end
    if now - (state.prev_at or 0) < 0.25 then return end   -- wait until the sliders stop moving
    sync_preview(sum, sig)
  end

  -- window closed / script ended
  local function shutdown()
    cancel_job()
    if state.prev then
      r.Undo_BeginBlock(); r.PreventUIRefresh(1); remove_preview(); r.PreventUIRefresh(-1)
      r.Undo_EndBlock(SCRIPT_NAME .. ": remove PREVIEW", -1)
      r.UpdateArrange()
    end
  end

  ------------------------------------------------------------------------------
  -- Apply
  ------------------------------------------------------------------------------
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
    local pv = state.prev
    if pv and not (valid_track(pv.track) and preview_matches(pv)) then pv = nil end
    if S.dup ~= 0 and not pv and r.GetMediaTrackInfo_Value(src, "I_FOLDERDEPTH") == 1 then
      state.err = "Folder parent tracks cannot be duplicated here. Select a normal track (or switch 'Work on a duplicate' off)."
      return
    end

    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    local ok, err = pcall(function()
      local _, name = r.GetSetMediaTrackInfo_String(src, "P_NAME", "", false)
      name = (name ~= "" and name or "Track")
      local target = src
      local kept = false
      if S.dup ~= 0 then
        if pv then
          -- keep the PREVIEW as the result: no second copy, no waiting for the sync
          target = pv.track
          kept = true
        else
          target = duplicate_track(src)
        end
        r.GetSetMediaTrackInfo_String(target, "P_NAME", name .. " [gain-eq]", true)
      end
      local parts, notes = build(target, src, sum, kept)
      state.warn_eq = (#notes > 0) and table.concat(notes, "; ") or nil
      if kept then
        tset(target, E_ROLE, ""); tset(target, E_SRC, ""); tset(target, E_MUTE, "")   -- an ordinary track from now on
        unmute_source(pv)
        state.prev, state.prev_seen, state.prev_fail = nil, nil, nil
        S.preview = 0                          -- keeping it ends the live preview (else a second one would appear)
      elseif state.prev then
        remove_preview()                       -- in place: the PREVIEW has done its job
        S.preview = 0
      end
      if S.dup ~= 0 and S.mute_orig ~= 0 then r.SetMediaTrackInfo_Value(src, "B_MUTE", 1) end
      state.msg = (S.dup ~= 0 and ("Created '" .. name .. " [gain-eq]': ") or ("Changed '" .. name .. "': "))
        .. table.concat(parts, ", ") .. (kept and " (the PREVIEW track was kept)." or ".")
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
  RA.pump_preview, RA.shutdown = pump_preview, shutdown
  RA.install_jsfx = install_jsfx
  RA.eq_needed = eq_needed
  RA.apply_eq, RA.apply_gain, RA.remove_eq = apply_eq, apply_gain, remove_eq      -- exposed for the offline tests
  return RA
end

return M
