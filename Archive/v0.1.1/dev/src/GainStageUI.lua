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
    r.ImGui_TextColored(ctx, S.eq_on ~= 0 and COL_OK or 0x888888FF,
      S.eq_on ~= 0 and string.format("EQ stage on (amount %.0f %%): ReaEQ goes on every audio item", S.eq_amount) or "EQ stage off: no ReaEQ will be added")
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
    local label = "Apply to this track"
    if S.dup ~= 0 then label = state.prev and "Keep PREVIEW as new track" or "Apply to new track" end
    if r.ImGui_Button(ctx, label) then RA.apply() end
    if not can_apply then r.ImGui_EndDisabled(ctx) end

    if state.err then r.ImGui_TextColored(ctx, COL_ERR, state.err) end
    if state.msg then r.ImGui_TextColored(ctx, COL_OK, state.msg) end
    if state.warn_eq then r.ImGui_TextColored(ctx, COL_WARN, "ReaEQ: " .. state.warn_eq) end
    if state.prev then
      r.ImGui_TextColored(ctx, COL_OK, "PREVIEW track is live" .. (state.prev.muted and " (source muted)" or "") .. ": it follows every setting below.")
    elseif S.preview ~= 0 then
      r.ImGui_TextColored(ctx, 0x888888FF, "PREVIEW is on: it appears after the analysis.")
    end

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
    slider("EQ amount", "eq_amount", 0, 100, "%.0f %%")
    slider("Max correction per band", "max_eq", 0, 12, "%.1f dB")
    slider("Dead band", "deadband", 0, 3, "%.1f dB")
    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, "Analysis")
    slider("Silence gate (absolute)", "gate_abs", -90, -30, "%.0f dBFS")
    slider("Silence gate (below loudest)", "gate_rel", 20, 80, "%.0f dB")
    slider("FFT windows per item (re-analyse)", "fft_max", 100, 1500, "%.0f")
    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, "Output")
    check("Live PREVIEW track", "preview")
    if S.preview == 0 then r.ImGui_BeginDisabled(ctx) end
    check("Mute the source while previewing", "prev_mute")
    if S.preview == 0 then r.ImGui_EndDisabled(ctx) end
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
