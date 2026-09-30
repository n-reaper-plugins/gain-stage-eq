-- In-memory fake of the parts of the REAPER API that Gain Stage EQ uses (tracks, items, audio accessor,
-- track FX incl. a ReaEQ look-alike with 12 parameters and formatted text, JSFX files, ExtState, undo).
-- It checks OUR logic (selection, analysis pipeline, gain, EQ set-up, main loop), not REAPER's behaviour.
-- Audio comes from a synthetic generator (see M.tones()).
local M = {}

-- Sum of sines: list = { {freq, amp}, ... }; optional gate(t) -> multiplier (bursts, silence ...)
function M.tones(list, gate)
  return function(t)
    local v = 0
    for _, x in ipairs(list) do v = v + x[2] * math.sin(2 * math.pi * x[1] * t) end
    return gate and v * gate(t) or v
  end
end

function M.install(cfg)
  cfg = cfg or {}
  local S = {
    tracks = {}, deferred = {}, ext = {}, projext = {}, console = {}, mb = {}, guid_n = 0,
    commands = {}, play_state = 0, play_pos = 0, cursor = 0, time_sel = { 0, 0 }, clock = 0,
    undo = {}, resource = cfg.resource or "/tmp/gse-test-resource",
  }
  M.S = S
  local function new_guid() S.guid_n = S.guid_n + 1; return string.format("{00000000-0000-0000-0000-%012d}", S.guid_n) end
  local function index_of(t) for i, x in ipairs(S.tracks) do if x == t then return i end end end

  ---------------------------------------------------------------- scene helpers
  function M.new_track(name)
    local t = { p = { D_VOL = 1, B_MUTE = 0, I_FOLDERDEPTH = 0, I_CUSTOMCOLOR = 0 }, items = {}, name = name or "",
                guid = new_guid(), sel = false, envs = {}, fx = {} }
    S.tracks[#S.tracks + 1] = t
    return t
  end
  -- source = { gen = function(t), sr = 44100, nch = 2, len = seconds }
  function M.add_audio_item(track, source, pos, len, name)
    local it = { track = track, p = { D_POSITION = pos, D_LENGTH = len, D_VOL = 1, D_FADEINLEN = 0, D_FADEOUTLEN = 0 },
                 guid = new_guid() }
    it.take = { p = { D_PLAYRATE = 1, D_STARTOFFS = 0 }, src = source, name = name or "take", item = it }
    track.items[#track.items + 1] = it
    table.sort(track.items, function(a, b) return a.p.D_POSITION < b.p.D_POSITION end)
    return it
  end
  local function sort_items(t) table.sort(t.items, function(a, b) return a.p.D_POSITION < b.p.D_POSITION end) end

  ---------------------------------------------------------------- API
  local R = {}
  reaper = R
  R.ValidatePtr2 = function() return true end
  R.time_precise = function() return S.clock end
  R.defer = function(f) S.deferred[#S.deferred + 1] = f end
  R.atexit = function(f) S.atexit = f end
  R.ShowConsoleMsg = function(s) S.console[#S.console + 1] = s end
  R.MB = function(msg) S.mb[#S.mb + 1] = msg; return 1 end
  R.GetExtState = function(sec, k) return S.ext[sec .. "/" .. k] or "" end
  R.SetExtState = function(sec, k, v) S.ext[sec .. "/" .. k] = v end
  R.GetProjExtState = function(_, sec, k) local v = S.projext[sec .. "/" .. k]; return v and 1 or 0, v or "" end
  R.SetProjExtState = function(_, sec, k, v) S.projext[sec .. "/" .. k] = v end
  R.Undo_BeginBlock = function() end
  R.Undo_EndBlock = function(name) S.undo[#S.undo + 1] = name end
  R.PreventUIRefresh = function() end
  R.UpdateArrange = function() end
  R.TrackList_AdjustWindows = function() end
  R.genGuid = new_guid
  R.ColorToNative = function(rr, g, b) return rr | (g << 8) | (b << 16) end
  R.GetPlayState = function() return S.play_state end
  R.GetPlayPosition = function() return S.play_pos end
  R.GetPlayPosition2 = function() return S.play_pos end
  R.GetCursorPosition = function() return S.cursor end
  R.GetSet_LoopTimeRange = function() return S.time_sel[1], S.time_sel[2] end

  -- tracks
  R.CountTracks = function() return #S.tracks end
  R.GetTrack = function(_, i) return S.tracks[i + 1] end
  R.GetTrackGUID = function(t) return t.guid end
  R.CountSelectedTracks = function() local n = 0 for _, t in ipairs(S.tracks) do if t.sel then n = n + 1 end end return n end
  R.GetSelectedTrack = function(_, i) local n = 0 for _, t in ipairs(S.tracks) do if t.sel then if n == i then return t end n = n + 1 end end end
  R.SetOnlyTrackSelected = function(t) for _, x in ipairs(S.tracks) do x.sel = (x == t) end end
  R.GetMediaTrackInfo_Value = function(t, k)
    if k == "IP_TRACKNUMBER" then return index_of(t) end
    return t.p[k] or 0
  end
  R.SetMediaTrackInfo_Value = function(t, k, v) t.p[k] = v end
  R.GetSetMediaTrackInfo_String = function(t, k, v, set)
    if k == "P_NAME" then if set then t.name = v end return true, t.name end
    return false, ""
  end
  R.GetTrackStateChunk = function(t) return true, "<TRACK\n>\n" end
  R.SetTrackStateChunk = function(t, c)
    if c:find("<VOLENV", 1, true) then t.envs["Volume (Pre-FX)"] = { points = {}, mode = 0 } end
    return true
  end

  -- items / takes
  R.CountTrackMediaItems = function(t) return #t.items end
  R.GetTrackMediaItem = function(t, i) return t.items[i + 1] end
  R.GetActiveTake = function(it) return it.take end
  R.TakeIsMIDI = function() return false end
  R.GetMediaItemInfo_Value = function(it, k) return it.p[k] or 0 end
  R.SetMediaItemInfo_Value = function(it, k, v) it.p[k] = v end
  R.GetMediaItemTakeInfo_Value = function(tk, k) return tk.p[k] or 0 end
  R.SetMediaItemTakeInfo_Value = function(tk, k, v) tk.p[k] = v end
  R.GetSetMediaItemTakeInfo_String = function(tk, k, v, set)
    if k == "P_NAME" then if set then tk.name = v end return true, tk.name end
    return false, ""
  end
  R.SplitMediaItem = function(it, pos)
    local p0, len = it.p.D_POSITION, it.p.D_LENGTH
    if pos <= p0 + 1e-9 or pos >= p0 + len - 1e-9 then return nil end
    local right = { track = it.track, guid = new_guid(), p = {} }
    for k, v in pairs(it.p) do right.p[k] = v end
    right.p.D_POSITION, right.p.D_LENGTH = pos, p0 + len - pos
    right.p.D_FADEINLEN = 0
    it.p.D_LENGTH = pos - p0
    it.p.D_FADEOUTLEN = 0
    right.take = { p = {}, src = it.take.src, name = it.take.name, item = right }
    for k, v in pairs(it.take.p) do right.take.p[k] = v end
    right.take.p.D_STARTOFFS = it.take.p.D_STARTOFFS + (pos - p0)
    it.track.items[#it.track.items + 1] = right
    sort_items(it.track)
    return right
  end

  -- audio
  R.GetMediaItemTake_Source = function(tk) return tk.src end
  R.GetMediaSourceSampleRate = function(s) return s.sr or 44100 end
  R.GetMediaSourceNumChannels = function(s) return s.nch or 2 end
  R.new_array = function(n)
    local a = { buf = {} }
    for i = 1, n do a.buf[i] = 0 end
    a.clear = function() for i = 1, n do a.buf[i] = 0 end end
    a.table = function() return a.buf end
    return a
  end
  R.CreateTakeAudioAccessor = function(tk) return { take = tk } end
  R.DestroyAudioAccessor = function(aa) S.accessors_destroyed = (S.accessors_destroyed or 0) + 1 end
  R.GetAudioAccessorStartTime = function() return 0 end
  R.GetAudioAccessorEndTime = function(aa) return aa.take.item.p.D_LENGTH end
  -- accessor time 0 = start of the take's audio inside the item (source time = STARTOFFS + t)
  R.GetAudioAccessorSamples = function(aa, sr, nch, t0, n, buf)
    local tk = aa.take
    local off = tk.p.D_STARTOFFS
    local gen, b = tk.src.gen, buf.buf
    for i = 0, n - 1 do
      local v = gen(off + t0 + i / sr)
      for c = 1, nch do b[i * nch + c] = v end
    end
    return 1
  end

  -- actions
  R.Main_OnCommand = function(id)
    S.commands[#S.commands + 1] = id
    if id == 40062 then      -- duplicate selected track(s) right below
      for i, t in ipairs(S.tracks) do
        if t.sel then
          local d = { p = {}, items = {}, name = t.name, guid = new_guid(), sel = false, envs = {}, fx = {} }
          for _, f in ipairs(t.fx) do local c = { name = f.name, kind = f.kind, renamed = f.renamed, params = {} } for i, p in ipairs(f.params) do c.params[i] = { name = p.name, norm = p.norm, fmt = p.fmt, val = p.val } end d.fx[#d.fx + 1] = c end
          for k, v in pairs(t.p) do d.p[k] = v end
          for _, it in ipairs(t.items) do
            local c = { track = d, guid = new_guid(), p = {} }
            for k, v in pairs(it.p) do c.p[k] = v end
            c.take = { p = {}, src = it.take.src, name = it.take.name, item = c }
            for k, v in pairs(it.take.p) do c.take.p[k] = v end
            d.items[#d.items + 1] = c
          end
          table.insert(S.tracks, i + 1, d)
          t.sel = false; d.sel = true
          return
        end
      end
    elseif id == 41865 then  -- select pre-FX volume envelope
      for _, t in ipairs(S.tracks) do
        if t.sel and not t.envs["Volume (Pre-FX)"] then t.envs["Volume (Pre-FX)"] = { points = {}, mode = 0 } end
      end
    end
  end

  -- envelopes
  R.GetTrackEnvelopeByName = function(t, name) return t.envs[name] end
  R.DeleteEnvelopePointRange = function(e) e.points = {} end
  R.GetEnvelopeScalingMode = function(e) return e.mode end
  R.ScaleToEnvelopeMode = function(_, v) return v end
  R.InsertEnvelopePoint = function(e, t, v) e.points[#e.points + 1] = { t, v } end
  R.Envelope_SortPoints = function(e) table.sort(e.points, function(a, b) return a[1] < b[1] end) end

  ---------------------------------------------------------------- resource path / files
  R.GetResourcePath = function() return S.resource end
  R.RecursiveCreateDirectory = function(p) os.execute("mkdir -p '" .. p .. "'"); return 1 end

  ---------------------------------------------------------------- track FX
  local function reaeq_params()
    local names = { "Low Shelf", "Band 2", "Band 3", "High Shelf" }
    local ps = {}
    for _, nm in ipairs(names) do
      ps[#ps + 1] = { name = "Freq-" .. nm, norm = 0.5, fmt = function(x)
        local f = 20 * (24000 / 20) ^ x
        return f >= 1000 and string.format("%.2fk", f / 1000) or string.format("%.1f", f) end }
      ps[#ps + 1] = { name = "Gain-" .. nm, norm = 60 / 84, fmt = function(x)
        if x <= 0 then return "-inf" end
        return string.format("%.2f", -60 + 84 * x) end }
      ps[#ps + 1] = { name = "Q-" .. nm, norm = 0.1, fmt = function(x) return string.format("%.2f", 0.1 + 9.9 * x) end }
    end
    return ps
  end
  -- what a parameter really holds (for the tests): freq Hz, gain dB, Q
  function M.reaeq_values(fx)
    local out = {}
    for b = 1, 4 do
      local f, g, q = fx.params[(b - 1) * 3 + 1], fx.params[(b - 1) * 3 + 2], fx.params[(b - 1) * 3 + 3]
      out[b] = { freq = 20 * (24000 / 20) ^ f.norm, gain = -60 + 84 * g.norm, q = 0.1 + 9.9 * q.norm }
    end
    return out
  end

  R.TrackFX_GetCount = function(t) return #t.fx end
  R.TrackFX_GetFXName = function(t, i)
    local f = t.fx[i + 1]
    if not f then return false, "" end
    return true, f.kind == "reaeq" and "VST: ReaEQ (Cockos)" or "JS: GainStageEQ Trim"
  end
  R.TrackFX_AddByName = function(t, name, _, idx)
    local f
    if name:find("ReaEQ", 1, true) then
      f = { kind = "reaeq", name = "ReaEQ", params = reaeq_params() }
    elseif name:find("GainStageEQ", 1, true) then
      local fh = io.open(S.resource .. "/Effects/GainStageEQ/GainStageEQTrim.jsfx", "rb")
      if not fh then return -1 end
      fh:close()
      f = { kind = "jsfx", name = "GainStageEQ Trim", params = { { name = "Trim (dB)", val = 0, min = -60, max = 24 } } }
    else
      return -1
    end
    if idx and idx <= -1000 then
      table.insert(t.fx, -1000 - idx + 1, f)
      return -1000 - idx
    end
    t.fx[#t.fx + 1] = f
    return #t.fx - 1
  end
  R.TrackFX_GetNumParams = function(t, i) return #t.fx[i + 1].params end
  R.TrackFX_GetParamName = function(t, i, p) return true, t.fx[i + 1].params[p + 1].name end
  R.TrackFX_SetParamNormalized = function(t, i, p, x) t.fx[i + 1].params[p + 1].norm = x; return true end
  R.TrackFX_GetParamNormalized = function(t, i, p) return t.fx[i + 1].params[p + 1].norm end
  R.TrackFX_GetFormattedParamValue = function(t, i, p)
    local prm = t.fx[i + 1].params[p + 1]
    return true, prm.fmt(prm.norm)
  end
  R.TrackFX_SetParam = function(t, i, p, v) t.fx[i + 1].params[p + 1].val = v; return true end
  R.TrackFX_GetParam = function(t, i, p) local x = t.fx[i + 1].params[p + 1]; return x.val, x.min, x.max end
  R.TrackFX_SetNamedConfigParm = function(t, i, k, v)
    if k == "renamed_name" then t.fx[i + 1].renamed = v; return true end
    return false
  end
  R.TrackFX_GetNamedConfigParm = function(t, i, k)
    if k == "renamed_name" then local v = t.fx[i + 1].renamed; return v ~= nil, v or "" end
    return false, ""
  end

  return S
end

-- Run n rounds of the deferred callbacks (like REAPER's UI timer).
function M.pump(S, n, dt)
  for _ = 1, n do
    S.clock = S.clock + (dt or 0.02)
    local cbs = S.deferred; S.deferred = {}
    for _, cb in ipairs(cbs) do cb() end
  end
end

return M
