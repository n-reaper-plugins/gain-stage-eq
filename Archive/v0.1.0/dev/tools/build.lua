-- Build:  lua tools/build.lua        (run from the dev/ folder)
-- Output: dist/GainStageEQ.lua                             the ONE file users need
--         dist/Effects/GainStageEQ/GainStageEQTrim.jsfx    OPTIONAL (the app also writes it itself when needed)
package.path = "./src/?.lua;" .. package.path
local Core = require("GainStageCore")
local Jsfx = require("GainStageJsfx")

local MODULES = { "GainStageCore", "GainStageJsfx", "GainStageReaper", "GainStageUI" }

local function read(p)
  local f = assert(io.open(p, "rb"), "cannot read " .. p)
  local s = f:read("*a"); f:close(); return s
end
local function write(p, s)
  local f = assert(io.open(p, "wb"), "cannot write " .. p)
  f:write(s); f:close()
end

-- split the leading comment header (kept at the very top for ReaPack/@version) from the body
local main = read("src/GainStageEQ.lua"):gsub("@@VERSION@@", Core.VERSION)
local header, body = {}, main
while true do
  local line, rest = body:match("^([^\n]*)\n(.*)$")
  if line and line:match("^%-%-") then header[#header + 1] = line; body = rest else break end
end

local out = {}
out[#out + 1] = table.concat(header, "\n")
out[#out + 1] = "-- BUNDLED BUILD of Gain Stage EQ v" .. Core.VERSION .. " - edit the files in dev/src/, not this one."
out[#out + 1] = "local __preload = package.preload"
for _, m in ipairs(MODULES) do
  out[#out + 1] = string.format('__preload["%s"] = function(...)\n%s\nend', m, read("src/" .. m .. ".lua"))
end
out[#out + 1] = body

os.execute("mkdir -p dist/Effects/GainStageEQ")
write("dist/GainStageEQ.lua", table.concat(out, "\n") .. "\n")
write("dist/Effects/GainStageEQ/" .. Jsfx.FILE, Jsfx.text())
print(string.format("built dist/GainStageEQ.lua v%s", Core.VERSION))
