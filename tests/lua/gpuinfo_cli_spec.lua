local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = root .. "../../Configs/.local/lib/hyde/?.lua;" .. package.path
local gpuinfo = require("gpuinfo")
local json = require("luautils.json")

local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("    fail: " .. message)
    end
end

local work_dir = os.getenv("GPUINFO_TEST_WORK_DIR")
assert(work_dir, "GPUINFO_TEST_WORK_DIR must be set by the test wrapper")

local function run(argv, extra_opts)
    local lines = {}
    local opts = {print_fn = function(s) lines[#lines + 1] = s end}
    for k, v in pairs(extra_opts or {}) do
        opts[k] = v
    end
    local code = gpuinfo.cli_main(argv, opts)
    return code, table.concat(lines, "\n")
end

-- Cold start (no state file yet, no vendor detected on this fake sysfs) must
-- still produce exactly-one-JSON-object-per-line output on stdout (captured
-- here via print_fn), never a diagnostic banner mixed in -- the #2021/#2022
-- contract this rewrite must not regress just because the implementation
-- language changed. The "Initialized: ..." diagnostic goes through the
-- separate warn_fn (stderr in real usage), captured to its own buffer here
-- specifically so a regression that routed it back through print_fn would
-- show up as a line the loop below rejects.
os.remove(gpuinfo.state_path("_cli_test"))
local warn_lines = {}
local code1, out1 = run({"--use", "nonexistent-vendor-suffix-for-isolation"}, {
    state_suffix_override = "_cli_test",
    detect_vendor_opts = {pci_dir = work_dir .. "/no-such-pci-dir", modules_file = work_dir .. "/no-such-modules"},
    warn_fn = function(s) warn_lines[#warn_lines + 1] = s end,
})
check(#warn_lines > 0, "the cold-start 'Initialized: ...' diagnostic did not go through warn_fn at all")
for line in out1:gmatch("[^\n]+") do
    local ok = pcall(json.decode, line)
    check(ok or line:match("^Error"), "a cold-start stdout line was neither valid JSON nor the documented error message: " .. line)
end

-- --stat <vendor> reports "GPU not enabled." and a nonzero exit for a vendor
-- that was never detected -- matches the bash version's contract exactly
-- (waybar's exec-if uses this to decide whether to show that module at all).
local code2, out2 = run({"--stat", "nvidia"}, {state_suffix_override = "_cli_test"})
check(code2 ~= 0, "--stat for an undetected vendor did not exit non-zero")
check(out2:find("GPU not enabled%."), "--stat for an undetected vendor did not print the documented message")

-- --stat with an invalid vendor name reports the documented usage error.
local code3, out3 = run({"--stat", "bogus"}, {state_suffix_override = "_cli_test"})
check(code3 ~= 0, "--stat with an invalid vendor name did not exit non-zero")
check(out3:find("Invalid argument for %-%-stat"), "--stat with an invalid vendor name did not print the documented error")

os.remove(gpuinfo.state_path("_cli_test"))

os.exit(failures == 0 and 0 or 1)
