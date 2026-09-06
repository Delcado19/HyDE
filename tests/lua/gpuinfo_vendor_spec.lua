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

-- A fake PCI bus with one Intel display controller (class 0x030000) and one
-- unrelated device (class 0x060000, a host bridge -- must be ignored).
local pci_dir = work_dir .. "/pci"
os.execute("mkdir -p " .. pci_dir .. "/0000:00:02.0 " .. pci_dir .. "/0000:00:00.0")
write_file(pci_dir .. "/0000:00:02.0/class", "0x030000\n")
write_file(pci_dir .. "/0000:00:02.0/vendor", "0x8086\n")
write_file(pci_dir .. "/0000:00:00.0/class", "0x060000\n")
write_file(pci_dir .. "/0000:00:00.0/vendor", "0x8086\n")

-- A fake lspci that only responds to the exact address gpuinfo asks for, so
-- the test also proves detect_vendor asks for that one address and not a
-- broad bus scan.
local fake_bin = work_dir .. "/bin"
os.execute("mkdir -p " .. fake_bin)
write_file(fake_bin .. "/lspci", [[#!/bin/sh
if [ "$3" = "0000:00:02.0" ]; then
    echo "00:02.0 VGA compatible controller [0300]: Intel Corporation Iris Xe Graphics [8086:9a49] (rev 01)"
else
    echo "unexpected address: $3" >&2
    exit 1
fi
]])
os.execute("chmod +x " .. fake_bin .. "/lspci")

local result = gpuinfo.detect_vendor({
    pci_dir = pci_dir,
    modules_file = work_dir .. "/nonexistent-modules",
    path_dirs = {fake_bin},
    lspci_cmd = "lspci",
})

check(result.intel == true, "an Intel display controller (class 0x030000, vendor 0x8086) was not detected")
check(result.nvidia == false, "nvidia was incorrectly detected with no matching PCI device")
check(result.amd == false, "amd was incorrectly detected with no matching PCI device")
check(result.intel_addr == "0000:00:02.0", "intel_addr was not the display controller's own address: got " .. tostring(result.intel_addr))
check(
    result.intel_gpu == "Iris Xe Graphics",
    "intel_gpu was not resolved from the single targeted lspci call: got " .. tostring(result.intel_gpu)
)

-- Out-of-spec: a device whose class file holds garbage (a race with a device
-- being hot-unplugged, or a kernel quirk) must be skipped, not crash the scan.
local garbage_dir = work_dir .. "/pci_garbage"
os.execute("mkdir -p " .. garbage_dir .. "/0000:01:00.0")
write_file(garbage_dir .. "/0000:01:00.0/class", "not-a-hex-value\n")
write_file(garbage_dir .. "/0000:01:00.0/vendor", "0x10de\n")
local garbage_result = gpuinfo.detect_vendor({
    pci_dir = garbage_dir,
    modules_file = work_dir .. "/nonexistent-modules",
    path_dirs = {fake_bin},
})
check(garbage_result.nvidia == false, "a device with a garbage class file was still detected as a GPU")

os.exit(failures == 0 and 0 or 1)
