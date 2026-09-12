local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = root .. "../../Configs/.local/lib/hyde/?.lua;" .. package.path
local gpuinfo = require("gpuinfo")
local json = require("luautils.json")
local work = assert(os.getenv("GPUINFO_TEST_WORK_DIR"))
local pci = work .. "/pci"
local addr = "0000:03:00.0"
local device = pci .. "/" .. addr
local hwmon = device .. "/hwmon/hwmon7"
local function write(path, value)
    local f = assert(io.open(path, "w"))
    f:write(value)
    f:close()
end
assert(os.execute("mkdir -p " .. hwmon .. " " .. device .. "/drm/card1"))
write(hwmon .. "/name", "amdgpu\n")
write(hwmon .. "/temp1_input", "62000\n")
write(hwmon .. "/fan1_input", "1400\n")
write(hwmon .. "/freq1_input", "1500000000\n")
write(hwmon .. "/power1_average", "65000000\n")
write(device .. "/gpu_busy_percent", "45\n")
local function query(address)
    return gpuinfo.read_gpu_sysfs({addr = address or addr, pci_dir = pci})
end
local values = query()
assert(values.temperature == 62 and values.fan_speed == 1400)
assert(values.current_clock_speed == 1500 and values.utilization == 45)
assert(values.power_usage == nil, "APU/SoC power must not appear as GPU power")

-- Zero is an actual reading. Missing, invalid and impossible percentages
-- must stay absent, independently of the other measurements.
write(hwmon .. "/fan1_input", "0")
write(device .. "/gpu_busy_percent", "0")
assert(query().fan_speed == 0 and query().utilization == 0)
for _, invalid in ipairs({"", "[N/A]", "nan", "inf", "-1", "101", "1e999", "42 W", "{}"}) do
    write(device .. "/gpu_busy_percent", invalid)
    assert(query().utilization == nil, "accepted invalid utilization: " .. invalid)
end
for _, invalid in ipairs({"", "[N/A]", "nan", "inf", "-1", "1e999", "62 C"}) do
    write(hwmon .. "/temp1_input", invalid)
    assert(query().temperature == nil, "accepted invalid temperature: " .. invalid)
end
os.remove(hwmon .. "/temp1_input")
assert(query().temperature == nil and query().fan_speed == 0)

-- A different card and CPU-like sensors cannot contaminate this GPU.
local other = pci .. "/0000:04:00.0/hwmon/hwmon8"
assert(os.execute("mkdir -p " .. other))
write(other .. "/name", "amdgpu")
write(other .. "/temp1_input", "99000")
assert(query().temperature == nil)
write(hwmon .. "/name", "coretemp")
write(hwmon .. "/temp1_input", "88000")
assert(query().temperature == nil and query().fan_speed == nil)
for _, invalid in ipairs({"", "../0000:04:00.0", "0000:04:00.0/..", "bad", "0000:04:00.8"}) do
    assert(next(query(invalid)) == nil, "invalid PCI address was accepted")
end
assert(next(gpuinfo.read_gpu_sysfs({pci_dir = pci})) == nil)
assert(next(query("0000:09:00.0")) == nil)

-- Intel exposes actual GPU clock, not CPU frequency or requested GT clock.
write(device .. "/drm/card1/gt_act_freq_mhz", "350")
write(device .. "/drm/card1/gt_cur_freq_mhz", "999")
write(device .. "/drm/card1/gt_RP0_freq_mhz", "1000")
values = query()
assert(values.current_clock_speed == 350 and values.max_clock_speed == 1000)
os.remove(device .. "/drm/card1/gt_act_freq_mhz")
assert(query().current_clock_speed == nil, "requested clock used as actual clock")

-- All non-NVIDIA CLI paths use the same device-bound source, and old state
-- or injected CPU/battery readings cannot re-enable the retired fallbacks.
for _, vendor in ipairs({"intel", "amd", "none"}) do
    local suffix = "_gpu_only_" .. vendor
    assert(gpuinfo.write_state(suffix, {
        detected = true, [vendor .. "_enable"] = true,
        [vendor .. "_gpu"] = "Test GPU", [vendor .. "_addr"] = addr,
        available = {vendor}, priority = vendor, prev_stat = 100, prev_idle = 50,
    }))
    local output
    assert(gpuinfo.cli_main({}, {
        state_suffix_override = suffix, pci_dir = pci,
        sensors_json = '{"coretemp":{"Package id 0":{"temp1_input":88}}}',
        stat_file = "/proc/stat", cpu_sysfs_dir = "/sys/devices/system/cpu",
        print_fn = function(line) output = line end,
    }) == 0)
    local decoded = json.decode(output)
    assert(not decoded.tooltip:find("Temperature:") and not decoded.tooltip:find("Utilization:"))
    assert(not decoded.tooltip:find("Power") and not decoded.tooltip:find("Clock Speed:"))
    assert(decoded.text:find("N/A"))
    os.remove(gpuinfo.state_path(suffix))
end
print("GPU sysfs and CPU-isolation checks passed")
