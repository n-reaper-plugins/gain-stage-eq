# Changelog

## 0.1.0
- First release.
- Scans every audio item on ONE selected track (take audio, item volume included, time selection respected), reading the
  audio time-sliced so the window stays responsive.
- Level: average (RMS of the active audio, silence-gated), sample peak and crest factor.
- Gain stage: three targets (average / peak / average under a peak ceiling), max-gain safety limit; applied as item volume
  (all items), track volume, or an optional JSFX trim (`GainStageEQTrim`, installed on demand).
- EQ stage (optional): 4-band spectrum (splits 200 / 1000 / 5000 Hz by default), least-squares tilt against a target
  slope (default -1.5 dB/oct), strength / max-correction / dead-band; sets up one ReaEQ (low shelf, two bells, high shelf).
- Works on a duplicate of the track by default; re-running updates the existing "GainStageEQ" ReaEQ instead of stacking.
- 169 offline checks (`dev/tools/run_tests.sh`).
