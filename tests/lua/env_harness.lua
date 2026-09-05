-- Simulates two consecutive config loads sharing one process environment --
-- what `hyprctl reload` actually does, since hl.env("PATH", ...) sets the
-- live compositor's own env var, and the next reload's os.getenv("PATH") sees
-- whatever the previous load left there.
--
-- #1521 reports PATH entries duplicated after a reload; env.lua used to
-- append hyde.path.lib to PATH unconditionally on every load, growing it by
-- one more copy each time.

local repo_root = assert(os.getenv("REPO_ROOT"), "REPO_ROOT is not set")
local hypr_lua = repo_root .. "/Configs/.local/share/hypr/lua"
local lib = "/home/user/.local/lib"

local real_path = "/usr/bin"
local real_getenv = os.getenv
os.getenv = function(name)
    if name == "PATH" then
        return real_path
    end
    return real_getenv(name)
end

_G.hl = {
    env = function(name, value)
        if name == "PATH" then
            real_path = value
        end
    end
}

local function load_once()
    -- A fresh hyde.env module state each time, like a fresh Lua VM per reload.
    _G.hyde = {path = {lib = lib}}
    dofile(hypr_lua .. "/hyde/env.lua")
    dofile(hypr_lua .. "/env.lua")
end

load_once()
load_once()

local function count_segment(path, segment)
    local count = 0
    for part in (path .. ":"):gmatch("([^:]*):") do
        if part == segment then
            count = count + 1
        end
    end
    return count
end

local failures = 0
local count = count_segment(real_path, lib)
if count ~= 1 then
    failures = failures + 1
    print(string.format("    fail: PATH contains %d copies of %s after two reloads, want 1 -- %s", count, lib, real_path))
end

print("    PATH after two reloads: " .. real_path)
os.exit(failures == 0 and 0 or 1)
