#!/usr/bin/env bash
# Run every offline test (needs a Lua 5.3+ interpreter: `lua` or `lua5.4`). From the dev/ folder.
set -eo pipefail
LUA="$(command -v lua5.4 || command -v lua5.3 || command -v lua)"
[ -n "$LUA" ] || { echo "no lua found"; exit 1; }
"$LUA" tools/build.lua
for t in test_core test_adapter test_ui test_bundle; do
  echo "=== $t"; "$LUA" tools/$t.lua | tail -n 1
done
echo "ALL TESTS PASSED"
