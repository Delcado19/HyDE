#!/usr/bin/env lua
local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = package.path .. ";" .. root .. "?.lua;" .. root .. "?/init.lua;"
require("luautils.init")

local json = require("luautils.json")

local M = {}

--- Path to this gpuinfo instance's state file. `suffix` matches the bash
--- version's "$gpuinfo_file$2" (a per-waybar-module-instance state, set via
--- --use/--startup so e.g. the #amd and #intel waybar modules don't clobber
--- each other's toggle/priority state).
function M.state_path(suffix)
    local runtime_dir = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
    return runtime_dir .. "/hyde-" .. (os.getenv("UID") or tostring(0)) .. "-gpuinfo" .. (suffix or "") .. ".json"
end

--- Reads the state for `suffix`. Always returns a table -- a missing or
--- corrupt file (a hand-edited or half-written state file, since this runs
--- on every single poll) degrades to {} rather than erroring, so a caller
--- never has to special-case "no state yet" separately from "read failed".
function M.read_state(suffix)
    local f = io.open(M.state_path(suffix), "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()
    local ok, decoded = pcall(json.decode, content)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return {}
end

--- Writes the whole state for `suffix` as one JSON object, replacing
--- whatever was there -- no in-place text editing (this is what replaces
--- the bash version's incremental echo>>/sed -i dance).
function M.write_state(suffix, state)
    local f, open_err = io.open(M.state_path(suffix), "w")
    if not f then
        return nil, "failed to open state file for writing: " .. tostring(open_err)
    end
    local ok, write_err = pcall(function()
        f:write(json.encode(state))
    end)
    f:close()
    if not ok then
        return nil, "failed to encode/write state: " .. tostring(write_err)
    end
    return true
end

return M
