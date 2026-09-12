#!/usr/bin/env lua
-- Separate LACT Waybar entry point; gpuinfo.lua remains the shared formatter.
local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = package.path .. ";" .. root .. "?.lua;" .. root .. "?/init.lua;"

local gpuinfo = require("gpuinfo")

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local vendor = arg[1] or ""
local command = os.getenv("HYDE_LACT_GPUINFO") or (root .. "lact_gpuinfo.py")
local handle = io.popen(quote(command) .. " " .. quote(vendor) .. " 2>/dev/null")
local output = handle and handle:read("*a") or ""
if handle then
    handle:close()
end

print(gpuinfo.generate_json(gpuinfo.lact_query(output)))
