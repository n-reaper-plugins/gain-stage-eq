#!/usr/bin/env bash
# Gain Stage EQ installer - macOS first (bash 3.2 compatible). Also works with --portable on any OS.
#
#   ./install_mac.sh                      install into ~/Library/Application Support/REAPER
#   ./install_mac.sh --portable DIR       install into a portable REAPER folder
#   ./install_mac.sh --no-register        do not touch reaper-kb.ini (add the action by hand)
#   ./install_mac.sh --src DIR            folder containing GainStageEQ.lua (default: ./Scripts/GainStageEQ, next to this script, or ./dist)
#   ./install_mac.sh --package            build dist/GainStageEQ-<version>.zip (Scripts/ + Effects/ folders + this installer)
#   ./install_mac.sh --out DIR            with --package: write the zip into DIR instead of ./dist
#   ./install_mac.sh --uninstall          remove exactly what this script added
#
# Nothing here modifies your projects. reaper-kb.ini is only edited while REAPER is closed,
# and is backed up first.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
RES=""
SRC=""
DO_REGISTER=1
DO_UNINSTALL=0
DO_PACKAGE=0
OUT=""

FILE='GainStageEQ.lua'
DIRNAME='GainStageEQ'
EFFECT_SUB='GainStageEQ'
JSFX_FILES='GainStageEQTrim.jsfx'          # space separated; empty = this project has no JSFX

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --portable)    [ $# -ge 2 ] || die "--portable needs a folder"; RES="$2"; shift 2 ;;
    --src)         [ $# -ge 2 ] || die "--src needs a folder"; SRC="$2"; shift 2 ;;
    --no-register) DO_REGISTER=0; shift ;;
    --uninstall)   DO_UNINSTALL=1; shift ;;
    --package)     DO_PACKAGE=1; shift ;;
    --out)         [ $# -ge 2 ] || die "--out needs a folder"; OUT="$2"; shift 2 ;;
    -h|--help)     sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---- locate the files to install / package ----------------------------------------------------
# Layouts accepted (first match wins):
#   release zip   ./Scripts/GainStageEQ/GainStageEQ.lua   (+ ./Effects/GainStageEQ/*.jsfx next to Scripts/)
#   flat folder   ./GainStageEQ.lua
#   repository    ./dist/GainStageEQ.lua                  (+ ./dist/Effects/... from the build, or ./Effects/...)
locate_src() {
  if [ -n "$SRC" ]; then
    :
  elif [ -f "$HERE/Scripts/$DIRNAME/$FILE" ]; then SRC="$HERE/Scripts/$DIRNAME"
  elif [ -f "$HERE/$FILE" ];                  then SRC="$HERE"
  elif [ -f "$HERE/dist/$FILE" ];             then SRC="$HERE/dist"
  else die "$FILE not found (looked in ./Scripts/$DIRNAME, . and ./dist). Use --src <folder>."; fi
  [ -f "$SRC/$FILE" ] || die "$SRC/$FILE not found"
}

# print the folder that contains Effects/$EFFECT_SUB/<file>; fail if it is nowhere
jsfx_root() {
  for d in "$SRC" "$HERE/dist" "$HERE"; do
    if [ -f "$d/Effects/$EFFECT_SUB/$1" ]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}

# ---- --package: build dist/<name>-<version>.zip -------------------------------------------------
# The zip mirrors REAPER's resource folder (Scripts/..., Effects/...) and carries this installer,
# so it can be unpacked anywhere and installed with ./install_mac.sh.
if [ "$DO_PACKAGE" = 1 ]; then
  command -v zip >/dev/null 2>&1 || die "--package needs the 'zip' command"
  locate_src
  VERSION="$(sed -n 's/^-- @version[[:space:]]*//p' "$SRC/$FILE" | head -n 1)"
  PKG="$DIRNAME-${VERSION:-dev}"
  OUTDIR="${OUT:-$HERE/dist}"
  mkdir -p "$OUTDIR"
  OUTDIR="$(cd "$OUTDIR" && pwd)"
  ZIP="$OUTDIR/$PKG.zip"

  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pkg.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  mkdir -p "$STAGE/$PKG/Scripts/$DIRNAME"
  cp "$SRC/$FILE" "$STAGE/$PKG/Scripts/$DIRNAME/$FILE"

  for j in $JSFX_FILES; do
    if R="$(jsfx_root "$j")"; then
      mkdir -p "$STAGE/$PKG/Effects/$EFFECT_SUB"
      cp "$R/Effects/$EFFECT_SUB/$j" "$STAGE/$PKG/Effects/$EFFECT_SUB/$j"
    else
      warn "$j not found - not included (the script writes it itself when needed)"
    fi
  done

  cp "$HERE/$(basename "$0")" "$STAGE/$PKG/install_mac.sh"
  chmod 755 "$STAGE/$PKG/install_mac.sh"
  for f in README.md CHANGELOG.md LICENSE; do
    if [ -f "$HERE/$f" ]; then cp "$HERE/$f" "$STAGE/$PKG/$f"; fi
  done

  # same input -> same zip: fixed timestamps, sorted entries, no extra attributes
  find "$STAGE" -exec touch -t 202001010000 {} +
  rm -f "$ZIP"
  ( cd "$STAGE" && find "$PKG" | LC_ALL=C sort | zip -X -q "$ZIP" -@ )

  say "Built $ZIP"
  ( cd "$STAGE" && find "$PKG" -type f | LC_ALL=C sort | sed 's/^/  /' )
  exit 0
fi

# ---- locate REAPER's resource folder -------------------------------------------------------
if [ -z "$RES" ]; then
  case "$(uname -s)" in
    Darwin) RES="$HOME/Library/Application Support/REAPER" ;;
    *)      RES="$HOME/.config/REAPER" ;;
  esac
fi
[ -d "$RES" ] || die "REAPER resource folder not found: $RES
Start REAPER once so it creates it, or pass --portable <folder>."

SCRIPT_DIR="$RES/Scripts/$DIRNAME"
SCRIPT_PATH="$SCRIPT_DIR/$FILE"
EFFECT_DIR="$RES/Effects/$EFFECT_SUB"
KB="$RES/reaper-kb.ini"

reaper_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x REAPER >/dev/null 2>&1 || pgrep -x reaper >/dev/null 2>&1
  else
    return 0     # cannot tell: be safe and treat as running
  fi
}

sha1() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  else printf '%s' "$1" | sha1sum | cut -d' ' -f1; fi
}

backup_kb() {
  [ -f "$KB" ] || return 0
  cp "$KB" "$KB.gain-stage-eq-backup-$(date +%Y%m%d-%H%M%S)"
}

# remove every reaper-kb.ini line that registers our script
kb_remove() {
  [ -f "$KB" ] || return 0
  grep -qF -e "$SCRIPT_PATH" "$KB" 2>/dev/null || return 0
  backup_kb
  grep -vF -e "$SCRIPT_PATH" "$KB" > "$KB.tmp.$$" || true
  mv "$KB.tmp.$$" "$KB"
}

# ---- uninstall ----------------------------------------------------------------------------
if [ "$DO_UNINSTALL" = 1 ]; then
  say "Uninstalling Gain Stage EQ from: $RES"
  if reaper_running; then
    warn "REAPER seems to be running. Close it first so reaper-kb.ini can be cleaned; skipping that part."
  else
    kb_remove
    say "  removed action registration (if it existed)"
  fi
  rm -f "$SCRIPT_PATH"
  rmdir "$SCRIPT_DIR" 2>/dev/null || true
  for j in $JSFX_FILES; do rm -f "$EFFECT_DIR/$j"; done
  [ -n "$JSFX_FILES" ] && rmdir "$EFFECT_DIR" 2>/dev/null || true
  say "Done. Your projects are untouched."
  exit 0
fi

# ---- install ------------------------------------------------------------------------------
locate_src

VERSION="$(sed -n 's/^-- @version[[:space:]]*//p' "$SRC/$FILE" | head -n 1)"
say "Installing Gain Stage EQ ${VERSION:-?} into: $RES"

mkdir -p "$SCRIPT_DIR"
cp "$SRC/$FILE" "$SCRIPT_PATH"
say "  script  -> $SCRIPT_PATH"

for j in $JSFX_FILES; do
  if JSFX_ROOT="$(jsfx_root "$j")"; then
    mkdir -p "$EFFECT_DIR"
    cp "$JSFX_ROOT/Effects/$EFFECT_SUB/$j" "$EFFECT_DIR/$j"
    say "  jsfx    -> $EFFECT_DIR/$j (optional; the script also installs it itself when needed)"
  fi
done

# macOS: files downloaded from the internet carry a quarantine flag
if [ "$(uname -s)" = "Darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$SCRIPT_DIR" 2>/dev/null || true
  [ -d "$EFFECT_DIR" ] && xattr -dr com.apple.quarantine "$EFFECT_DIR" 2>/dev/null || true
  say "  removed download quarantine flag"
fi

# ReaImGui present?
if ls "$RES/UserPlugins" 2>/dev/null | grep -i 'imgui' >/dev/null 2>&1; then
  say "  ReaImGui: found"
else
  warn "ReaImGui was not found in $RES/UserPlugins."
  say  "  The window needs it: in REAPER open Extensions > ReaPack > Browse packages, search 'ReaImGui', install, restart."
fi

# register the action
REGISTERED=0
if [ "$DO_REGISTER" = 1 ]; then
  if reaper_running; then
    warn "REAPER seems to be running - not editing reaper-kb.ini."
  elif [ ! -f "$KB" ]; then
    warn "$KB does not exist yet (start and close REAPER once)."
  else
    kb_remove
    backup_kb
    ID="RS$(sha1 "$SCRIPT_PATH")"
    printf 'SCR 4 0 %s "Script: %s" "%s"\n' "$ID" "$FILE" "$SCRIPT_PATH" >> "$KB"
    REGISTERED=1
    say "  action  -> registered as 'Script: $FILE' (backup of reaper-kb.ini kept next to it)"
  fi
fi

say ""
if [ "$REGISTERED" = 1 ]; then
  say "Next: start REAPER, open Actions > Show action list, search 'Gain Stage EQ', run 'Script: $FILE'."
else
  say "Next: in REAPER open Actions > Show action list > New action > Load ReaScript..., choose"
  say "      $SCRIPT_PATH"
  say "      then run it."
fi
say "Uninstall any time with: $0 --uninstall"
