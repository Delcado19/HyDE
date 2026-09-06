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

local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local work_dir = os.getenv("GPUINFO_TEST_WORK_DIR")
assert(work_dir, "GPUINFO_TEST_WORK_DIR must be set by the test wrapper")

-- A fake nvidia-smi that answers the exact --query-gpu the bash version used.
local fake_bin = work_dir .. "/bin"
os.execute("mkdir -p " .. fake_bin)
write_file(fake_bin .. "/nvidia-smi", [[#!/bin/sh
echo "62, 45, 1800, 3600, 120.00, 200.00"
]])
os.execute("chmod +x " .. fake_bin .. "/nvidia-smi")

local fields = gpuinfo.nvidia_query({
    nvidia_gpu = "GeForce RTX 4070",
    nvidia_smi_cmd = fake_bin .. "/nvidia-smi",
})
check(fields.primary_gpu == "NVIDIA GeForce RTX 4070", "primary_gpu was not set correctly: got " .. tostring(fields.primary_gpu))
check(fields.temperature == "62", "temperature was not parsed from the CSV output: got " .. tostring(fields.temperature))
check(fields.current_clock_speed == "1800", "current_clock_speed was not parsed: got " .. tostring(fields.current_clock_speed))
check(fields.power_limit == "200.00", "power_limit was not parsed: got " .. tostring(fields.power_limit))

-- --tired + suspended: must report suspended rather than calling nvidia-smi
-- at all (a suspended discrete GPU should not be woken just to poll it).
local runtime_status_path = work_dir .. "/runtime_status"
write_file(runtime_status_path, "suspended\n")
local suspend_fields, suspended = gpuinfo.nvidia_query({
    nvidia_gpu = "GeForce RTX 4070",
    tired = true,
    runtime_status_path = runtime_status_path,
    nvidia_smi_cmd = fake_bin .. "/nonexistent-should-not-be-called",
})
check(suspended == true, "a suspended GPU with --tired was not reported as suspended")
check(suspend_fields.primary_gpu == "NVIDIA GeForce RTX 4070", "suspended fields did not still carry primary_gpu")

-- nouveau (is_nouveau=true) uses the generic sensors-based query instead of
-- nvidia-smi (nouveau has no nvidia-smi to call).
local nouveau_fields = gpuinfo.nvidia_query({
    nvidia_gpu = "Linux",
    is_nouveau = true,
    sensors_json = "{}",
    stat_file = "/proc/stat",
    cpu_sysfs_dir = work_dir .. "/no-such-cpufreq-dir",
    power_supply_dir = work_dir .. "/no-such-power-dir",
})
check(nouveau_fields.primary_gpu == "NVIDIA Linux", "nouveau path did not set primary_gpu")

os.exit(failures == 0 and 0 or 1)
