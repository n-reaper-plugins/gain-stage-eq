# Changelog

## 0.1.1
* **ReaEQ is now take FX on every audio item** of the result track (was: one instance on the track). Solved once through the
  plug-in's own parameter text and copied to the other items. Our ReaEQ is switched off while its item is being analysed, so
  re-running on a result never measures the EQ twice.
* **EQ amount** (0-100 %): scales all four band gains of the finished EQ. (Strength scales the measured error *before* the
  per-band limit and dead band; EQ amount scales the result.)
* **Live PREVIEW track**: copy of the source with the current gain + EQ, tagged (renaming is fine), re-synced ~0.25 s after the
  last slider move. Source muted while it exists (optional, restored afterwards). "Keep PREVIEW as new track" turns it into the
  result. Removed when unticked, when the source track/items change, or when the window closes.
* Fix: `math.sinh` (not in REAPER's Lua) crashed the EQ design.
* Tests run without the deprecated `math` functions, like REAPER.
