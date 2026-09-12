local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = root .. "../../Configs/.local/lib/hyde/?.lua;" .. package.path
local gpuinfo = require("gpuinfo")
local work = assert(os.getenv("GPUINFO_TEST_WORK_DIR"))
local function write(path, value)
    local f = assert(io.open(path, "w")); f:write(value); f:close()
end
local command = work .. "/nvidia-smi"
-- Validate the exact selected device, not merely whether a command ran.
write(command, [[#!/bin/sh
[ "$1" = "--id=0000:01:00.0" ] || exit 8
query='--query-gpu=temperature.gpu,utilization.gpu,clocks.current.graphics,'
query="${query}clocks.max.graphics,power.draw,power.limit"
[ "$2" = "$query" ] || exit 9
cat "$GPUINFO_TEST_WORK_DIR/csv"
exit "$(cat "$GPUINFO_TEST_WORK_DIR/status")"
]])
assert(os.execute("chmod +x " .. command))
write(work .. "/csv", "62, 45, 1800, 3600, 120.00, 200.00\n")
write(work .. "/status", "0")
local opts = {
    nvidia_gpu = "GeForce RTX 4070", nvidia_addr = "0000:01:00.0",
    nvidia_smi_cmd = command, pci_devices_dir = work .. "/pci",
}
local result = gpuinfo.nvidia_query(opts)
assert(result.temperature == 62 and result.utilization == 45)
assert(result.current_clock_speed == 1800 and result.power_limit == 200)
assert(result.primary_gpu == "NVIDIA GeForce RTX 4070")
assert(result.fan_speed == nil, "nvidia-smi target fan percentage must not become RPM")
write(work .. "/csv", ", 45, [N/A], 3600, 0, 200\n")
result = gpuinfo.nvidia_query(opts)
assert(result.temperature == nil and result.utilization == 45)
assert(result.current_clock_speed == nil and result.power_usage == 0)
for _, csv in ipairs({"", "error", "1,2,3", "1,2,3,4,5,6,7", "nan,101,inf,-1,[N/A],NaN"}) do
    write(work .. "/csv", csv)
    result = gpuinfo.nvidia_query(opts)
    assert(result.temperature == nil and result.utilization == nil and result.power_usage == nil)
end
write(work .. "/csv", "62,45,1800,3600,120,200")
write(work .. "/status", "1")
assert(gpuinfo.nvidia_query(opts).temperature == nil, "failed query output must be ignored")
write(work .. "/status", "0")
local power = work .. "/pci/0000:01:00.0/power"
assert(os.execute("mkdir -p " .. power))
write(power .. "/runtime_status", "suspended\n")
opts.tired = true
opts.nvidia_smi_cmd = work .. "/must-not-run"
local fields, suspended = gpuinfo.nvidia_query(opts)
assert(suspended and fields.temperature == nil)
opts.is_nouveau = true
assert(select(2, gpuinfo.nvidia_query(opts)), "nouveau --tired must also respect suspend")
opts.tired = false
assert(gpuinfo.nvidia_query(opts).temperature == nil, "nouveau must not read unrelated sensors")
opts.is_nouveau = false
for _, addr in ipairs({"", "../escape", "0000:01:00.0;touch injected", "0000:01:00.9"}) do
    opts.nvidia_addr = addr
    assert(gpuinfo.nvidia_query(opts).temperature == nil)
end
opts.nvidia_addr = nil
assert(gpuinfo.nvidia_query(opts).temperature == nil)
print("NVIDIA device selection, invalid input, and suspend checks passed")
