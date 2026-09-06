local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = root .. "../../Configs/.local/lib/hyde/?.lua;" .. package.path
local gpuinfo = require("gpuinfo")

local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("    fail: " .. message)
    end
end

-- Cycling with no explicit request steps to the next available vendor, in a
-- stable order, and wraps around.
local state = {amd_enable = true, intel_enable = true, priority = "amd"}
local next1 = gpuinfo.toggle(state, nil)
check(next1 == "intel", "cycling from amd with only amd/intel available did not land on intel: got " .. tostring(next1))
check(state.priority == "intel", "priority was not updated to the new vendor")
check(state.amd_enable == false, "the previous vendor was not disabled")
check(state.intel_enable == true, "the new vendor was not enabled")

local next2 = gpuinfo.toggle(state, nil)
check(next2 == "amd", "cycling wrapped incorrectly, expected amd: got " .. tostring(next2))

-- An explicit request ("--use amd") jumps directly to that vendor regardless
-- of cycle order, as long as it's actually available.
local state2 = {amd_enable = true, intel_enable = true, priority = "intel"}
local requested = gpuinfo.toggle(state2, "amd")
check(requested == "amd", "an explicit --use request was not honored: got " .. tostring(requested))
check(state2.amd_enable == true, "the explicitly requested vendor was not enabled")
check(state2.intel_enable == false, "the previously active vendor was not disabled after an explicit request")

-- Out-of-spec: requesting a vendor that was never detected as available must
-- not silently "succeed" with a nonsense enabled vendor -- it has to report
-- the failure so the caller (Task 11's CLI dispatch) can print the same
-- "Error: ... not found" message the bash version does, instead of leaving
-- state in an inconsistent shape (some vendor enabled that isn't really there).
local state3 = {amd_enable = true, priority = "amd"}
local unavailable, err = gpuinfo.toggle(state3, "nvidia")
check(unavailable == nil, "requesting an unavailable vendor did not return nil")
check(type(err) == "string" and err:match("nvidia"), "requesting an unavailable vendor did not name it in the error: got " .. tostring(err))
check(state3.amd_enable == true, "state was mutated even though the requested vendor was unavailable")

os.exit(failures == 0 and 0 or 1)
