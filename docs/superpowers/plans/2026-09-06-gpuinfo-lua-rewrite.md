# gpuinfo.sh → gpuinfo.lua Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Configs/.local/lib/hyde/gpuinfo.sh` (bash) with `Configs/.local/lib/hyde/gpuinfo.lua`, keeping the exact waybar JSON contract, while cutting subprocess calls to the ones that genuinely need an external tool (`sensors -j`, `nvidia-smi`, `amdgpu.py`, one targeted `lspci` for a human-readable GPU name).

**Architecture:** One Lua file exposing a module table `M` of small, independently testable functions (mirrors `Configs/.local/lib/hyde/open.lua`'s "requireable module + runnable script" pattern: a guarded auto-run block at the bottom calls `M.cli_main(arg)` only when the file is executed directly, so every task's tests can `require` the file and call its functions without triggering the CLI). State persists as one JSON object via the existing `luautils.json` module instead of the current hand-edited `KEY="value"` shell file.

**Tech Stack:** Lua 5.x, `luautils.json` (already in this repo), `luautils.argparse` (already used by `altab.lua`/`config.lua`/`shaders.lua`), `lfs` (LuaFileSystem, already a dependency — used by `luautils/global/state.lua`).

**Spec:** `docs/superpowers/specs/2026-09-06-gpuinfo-lua-rewrite.md`

## Global Constraints

- No new external dependencies. Every building block used here (`luautils.json`, `luautils.argparse`, `lfs`) already ships with HyDE.
- Every `io.popen`/subprocess call this rewrite keeps must be justified in a comment referencing the spec's "what changes" table — no unexplained new subprocess calls.
- State persists as JSON (`luautils.json.encode`/`.decode`), never hand-edited text.
- State file lives at `${XDG_RUNTIME_DIR:-/tmp}/hyde-$UID-gpuinfo<suffix>.json` (matches `cpuinfo.sh`'s own `${XDG_RUNTIME_DIR:-/tmp}` convention; `<suffix>` empty by default, set by `--use <gpu>`/`--startup` exactly like the bash version's `$gpuinfo_file$2`).
- Every new file follows the existing Lua script bootstrap: `#!/usr/bin/env lua`, `package.path` bootstrap, `require("luautils.init")` (copy verbatim from `altab.lua` lines 1-4).
- The waybar JSON contract (`text`, `tooltip`, `class`, `percentage`, `alt` fields; icon/bucket thresholds; tooltip line wording) is preserved byte-for-byte except the one documented behavior change (sensor-match precedence, see spec).

---

### Task 1: State persistence + module scaffold

**Files:**
- Create: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_state_spec.lua`
- Test: `tests/test_gpuinfo_lua_state.sh`

**Interfaces:**
- Produces: `M.state_path(suffix)` → `string`; `M.read_state(suffix)` → `table` (never nil — `{}` on missing/corrupt file); `M.write_state(suffix, state)` → `true, nil` or `nil, err_string`.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_state_spec.lua`:

```lua
-- Exercises gpuinfo.lua's state persistence in isolation, before any CLI
-- wiring exists. Requiring the file must not run the CLI (see the
-- open.lua-style auto-run guard gpuinfo.lua ends with) -- Task 1 has no
-- guard yet, so this also proves requiring it has no side effects.

local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = root .. "../../Configs/.local/lib/hyde/?.lua;" .. package.path

local runtime_dir = os.getenv("XDG_RUNTIME_DIR")
assert(runtime_dir, "XDG_RUNTIME_DIR must be set by the test wrapper")

local gpuinfo = require("gpuinfo")

local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("    fail: " .. message)
    end
end

-- A missing state file reads back as an empty table, not nil or an error.
os.remove(gpuinfo.state_path(""))
local empty = gpuinfo.read_state("")
check(type(empty) == "table", "read_state on a missing file did not return a table")
check(next(empty) == nil, "read_state on a missing file returned a non-empty table")

-- Writing then reading round-trips arbitrary fields.
local ok, err = gpuinfo.write_state("", {nvidia_enable = true, priority = "GPUINFO_AMD_ENABLE"})
check(ok == true, "write_state failed: " .. tostring(err))
local round_tripped = gpuinfo.read_state("")
check(round_tripped.nvidia_enable == true, "nvidia_enable did not round-trip")
check(round_tripped.priority == "GPUINFO_AMD_ENABLE", "priority did not round-trip")

-- A suffix (per-waybar-instance state, matching --use/--startup's "$2") is a
-- separate file from the unsuffixed default.
gpuinfo.write_state("_amd", {amd_enable = true})
check(gpuinfo.read_state("").nvidia_enable == true, "suffixed write clobbered the default state file")
check(gpuinfo.read_state("_amd").amd_enable == true, "suffixed state did not persist")

-- Out-of-spec: a corrupt (non-JSON) state file must degrade to an empty
-- table, not crash the caller -- this runs on every single poll, so a
-- hand-edited or half-written state file must never take the whole module
-- down.
local corrupt_path = gpuinfo.state_path("_corrupt")
local f = assert(io.open(corrupt_path, "w"))
f:write("{ this is not json")
f:close()
local corrupt_read = gpuinfo.read_state("_corrupt")
check(type(corrupt_read) == "table", "a corrupt state file crashed read_state instead of degrading to {}")

os.remove(gpuinfo.state_path(""))
os.remove(gpuinfo.state_path("_amd"))
os.remove(corrupt_path)

os.exit(failures == 0 and 0 or 1)
```

Create `tests/test_gpuinfo_lua_state.sh`:

```sh
#!/usr/bin/env sh
# Task 1 of the gpuinfo.lua rewrite: state persistence in isolation.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

XDG_RUNTIME_DIR="$work_dir" lua "$TESTS_DIR/lua/gpuinfo_state_spec.lua" ||
    fail "gpuinfo_state_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_state.sh && bash tests/test_gpuinfo_lua_state.sh`
Expected: FAIL — `gpuinfo.lua` does not exist yet, `require("gpuinfo")` errors.

- [ ] **Step 3: Write minimal implementation**

Create `Configs/.local/lib/hyde/gpuinfo.lua`:

```lua
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_state.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_state_spec.lua tests/test_gpuinfo_lua_state.sh
git commit -m "feat(gpuinfo.lua): state persistence as JSON (task 1/12 of the Lua rewrite)"
```

---

### Task 2: Vendor detection (replaces `query()`)

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_vendor_spec.lua`
- Test: `tests/test_gpuinfo_lua_vendor.sh`

**Interfaces:**
- Consumes: nothing from Task 1 directly (vendor detection doesn't touch state).
- Produces: `M.detect_vendor(opts)` → table with keys `nvidia`, `amd`, `intel` (booleans), and per-vendor `<vendor>_gpu` (name string or nil), `<vendor>_addr` (PCI address string or nil). `opts` (table, optional) accepts `pci_dir` (default `/sys/bus/pci/devices`), `modules_file` (default `/proc/modules`), `path_dirs` (default from `$PATH`), `lspci_cmd` (default `"lspci"`) — all overridable so the test never touches the real machine's hardware.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_vendor_spec.lua`:

```lua
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
```

Create `tests/test_gpuinfo_lua_vendor.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

GPUINFO_TEST_WORK_DIR="$work_dir" lua "$TESTS_DIR/lua/gpuinfo_vendor_spec.lua" ||
    fail "gpuinfo_vendor_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_vendor.sh && bash tests/test_gpuinfo_lua_vendor.sh`
Expected: FAIL — `detect_vendor` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua` (after the state functions, before `return M`):

```lua
local lfs = require("lfs")

local PCI_VENDOR_IDS = {["0x10de"] = "nvidia", ["0x1002"] = "amd", ["0x8086"] = "intel"}

local function read_first_line(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local line = f:read("*l")
    f:close()
    return line
end

--- Finds the human-readable device name for a PCI address using the one
--- targeted lspci call this rewrite keeps (see the spec's "what changes"
--- table: reimplementing the PCI ID name database in Lua is out of scope,
--- lspci is the tool built for that -- this call is scoped to one specific
--- address instead of the bash version's three full-bus `lspci | grep` scans).
local function lookup_pci_name(lspci_cmd, addr)
    local handle = io.popen(lspci_cmd .. " -nn -s " .. addr .. " 2>/dev/null")
    if not handle then
        return nil
    end
    local line = handle:read("*l")
    handle:close()
    if not line then
        return nil
    end
    -- "00:02.0 VGA compatible controller [0300]: Intel Corporation Iris Xe Graphics [8086:9a49] (rev 01)"
    -- -> "Iris Xe Graphics" (drop the vendor prefix, the [ids] suffix, the (rev) suffix).
    local rest = line:match(":%s*(.+)$")
    if not rest then
        return nil
    end
    rest = rest:gsub("%[%x%x%x%x:%x%x%x%x%]", ""):gsub("%(rev%s*%x+%)", "")
    rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
    rest = rest:gsub("^%a+ ?%a*%a* Corporation,? ?", ""):gsub("^Advanced Micro Devices, Inc%.,? ?", "")
    return rest ~= "" and rest or nil
end

--- Detects which GPU vendor(s) are present by scanning /sys/bus/pci/devices
--- directly (pure Lua) instead of the bash version's three separate full-bus
--- `lspci -nn | grep -E "VGA|3D" | grep -i <vendor>` scans per poll.
function M.detect_vendor(opts)
    opts = opts or {}
    local pci_dir = opts.pci_dir or "/sys/bus/pci/devices"
    local modules_file = opts.modules_file or "/proc/modules"
    local lspci_cmd = opts.lspci_cmd or "lspci"
    local path_dirs = opts.path_dirs
    if not path_dirs then
        path_dirs = {}
        for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
            path_dirs[#path_dirs + 1] = dir
        end
    end

    local result = {nvidia = false, amd = false, intel = false}

    if lfs.attributes(pci_dir, "mode") == "directory" then
        for entry in lfs.dir(pci_dir) do
            if entry ~= "." and entry ~= ".." then
                local dev_dir = pci_dir .. "/" .. entry
                local class_line = read_first_line(dev_dir .. "/class")
                -- Display controller class codes are 0x03xxxx (VGA 0300, 3D
                -- 0302, other-display 0380). A garbage/unreadable class file
                -- is skipped, not treated as a match.
                if class_line and class_line:match("^0x03%x%x%x%x%s*$") then
                    local vendor_line = read_first_line(dev_dir .. "/vendor")
                    local vendor_id = vendor_line and vendor_line:match("^(0x%x+)")
                    local vendor_name = vendor_id and PCI_VENDOR_IDS[vendor_id:lower()]
                    if vendor_name and not result[vendor_name] then
                        result[vendor_name] = true
                        result[vendor_name .. "_addr"] = entry
                        result[vendor_name .. "_gpu"] = lookup_pci_name(lspci_cmd, entry)
                    end
                end
            end
        end
    end

    -- nouveau (open-source nvidia driver): read /proc/modules directly
    -- instead of `lsmod | grep nouveau`.
    local modules_f = io.open(modules_file, "r")
    if modules_f then
        for line in modules_f:lines() do
            if line:match("^nouveau%s") then
                result.nvidia = true
                result.nvidia_gpu = result.nvidia_gpu or "Linux"
            end
        end
        modules_f:close()
    end

    -- nvidia-smi presence: PATH search instead of `command -v nvidia-smi`.
    if not result.nvidia_smi_present then
        for _, dir in ipairs(path_dirs) do
            if lfs.attributes(dir .. "/nvidia-smi", "mode") == "file" then
                result.nvidia_smi_present = true
                break
            end
        end
    end

    return result
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_vendor.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_vendor_spec.lua tests/test_gpuinfo_lua_vendor.sh
git commit -m "feat(gpuinfo.lua): pure-Lua PCI vendor detection (task 2/12)"
```

---

### Task 3: Toggle / priority cycling (replaces `toggle()`)

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_toggle_spec.lua`
- Test: `tests/test_gpuinfo_lua_toggle.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks directly (operates on a plain state table shaped like `M.read_state`'s return value, with `nvidia_enable`/`amd_enable`/`intel_enable` booleans already set by whatever populated it — Task 11 wires `M.detect_vendor`'s output into that shape).
- Produces: `M.toggle(state, requested)` → `next_vendor: string` (one of `"nvidia"`, `"amd"`, `"intel"`), mutating `state` in place: disables every vendor's own `<vendor>_enable`, enables only `next_vendor`'s, and sets `state.priority = next_vendor`.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_toggle_spec.lua`:

```lua
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
```

Create `tests/test_gpuinfo_lua_toggle.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

lua "$TESTS_DIR/lua/gpuinfo_toggle_spec.lua" || fail "gpuinfo_toggle_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_toggle.sh && bash tests/test_gpuinfo_lua_toggle.sh`
Expected: FAIL — `toggle` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua`:

```lua
local VENDOR_ORDER = {"nvidia", "amd", "intel"}

--- Cycles (or jumps to, if `requested` is set) the enabled GPU vendor,
--- mutating `state` in place. Returns the new vendor name, or (nil, err) if
--- `requested` names a vendor that isn't actually available.
function M.toggle(state, requested)
    local available = {}
    for _, vendor in ipairs(VENDOR_ORDER) do
        if state[vendor .. "_enable"] then
            available[#available + 1] = vendor
        end
    end
    if #available == 0 then
        return nil, "no GPU vendor is available"
    end

    local next_vendor
    if requested then
        local found = false
        for _, vendor in ipairs(available) do
            if vendor == requested then
                found = true
                break
            end
        end
        if not found then
            return nil, requested .. " not found in available vendors"
        end
        next_vendor = requested
    else
        local current_index = 1
        for i, vendor in ipairs(available) do
            if vendor == state.priority then
                current_index = i
                break
            end
        end
        next_vendor = available[(current_index % #available) + 1]
    end

    for _, vendor in ipairs(available) do
        state[vendor .. "_enable"] = (vendor == next_vendor)
    end
    state.priority = next_vendor
    return next_vendor
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_toggle.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_toggle_spec.lua tests/test_gpuinfo_lua_toggle.sh
git commit -m "feat(gpuinfo.lua): vendor toggle/priority cycling (task 3/12)"
```

---

### Task 4: Battery discharge reading (pure Lua sysfs)

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_battery_spec.lua`
- Test: `tests/test_gpuinfo_lua_battery.sh`

**Interfaces:**
- Produces: `M.read_battery_discharge(power_supply_dir)` → `number|nil` (watts).

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_battery_spec.lua`:

```lua
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

-- power_now present and readable: microwatts -> watts.
local dir1 = work_dir .. "/ps1"
os.execute("mkdir -p " .. dir1 .. "/BAT0")
write_file(dir1 .. "/BAT0/power_now", "15000000\n")
check(gpuinfo.read_battery_discharge(dir1) == 15.0, "power_now (15000000 uW) did not convert to 15.0 W")

-- No battery at all: nil, not an error.
local dir2 = work_dir .. "/ps2"
os.execute("mkdir -p " .. dir2)
check(gpuinfo.read_battery_discharge(dir2) == nil, "no battery present should read as nil, not a crash or a number")

-- Out-of-spec: power_now exists but the embedded controller answers ENXIO for
-- it on read (some laptops) -- current_now+voltage_now must be used instead,
-- not left empty just because power_now existed. Simulated portably as an
-- existing-but-empty file (io.open succeeds, read returns "").
local dir3 = work_dir .. "/ps3"
os.execute("mkdir -p " .. dir3 .. "/BAT0")
write_file(dir3 .. "/BAT0/power_now", "")
write_file(dir3 .. "/BAT0/current_now", "2000000\n")
write_file(dir3 .. "/BAT0/voltage_now", "12000000\n")
local watts = gpuinfo.read_battery_discharge(dir3)
check(watts and math.abs(watts - 24.0) < 0.001, "current_now*voltage_now fallback did not compute 24.0 W: got " .. tostring(watts))

os.exit(failures == 0 and 0 or 1)
```

Create `tests/test_gpuinfo_lua_battery.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

GPUINFO_TEST_WORK_DIR="$work_dir" lua "$TESTS_DIR/lua/gpuinfo_battery_spec.lua" ||
    fail "gpuinfo_battery_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_battery.sh && bash tests/test_gpuinfo_lua_battery.sh`
Expected: FAIL — `read_battery_discharge` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua`:

```lua
--- Reads battery discharge power in watts from /sys/class/power_supply
--- (or `power_supply_dir` in tests), pure Lua -- no awk. Prefers power_now
--- (microwatts); falls back to current_now*voltage_now (microamps *
--- microvolts) when power_now is missing or unreadable/empty, since some
--- laptops' embedded controller answers ENXIO for power_now specifically.
function M.read_battery_discharge(power_supply_dir)
    if lfs.attributes(power_supply_dir, "mode") ~= "directory" then
        return nil
    end
    for entry in lfs.dir(power_supply_dir) do
        if entry:match("^BAT") then
            local bat_dir = power_supply_dir .. "/" .. entry
            local power_raw = read_first_line(bat_dir .. "/power_now")
            local power_now = power_raw and tonumber(power_raw)
            if power_now then
                return power_now * 1e-6
            end
            local current_raw = read_first_line(bat_dir .. "/current_now")
            local voltage_raw = read_first_line(bat_dir .. "/voltage_now")
            local current_now = current_raw and tonumber(current_raw)
            local voltage_now = voltage_raw and tonumber(voltage_raw)
            if current_now and voltage_now then
                return (current_now * voltage_now) / 1e12
            end
        end
    end
    return nil
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_battery.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_battery_spec.lua tests/test_gpuinfo_lua_battery.sh
git commit -m "feat(gpuinfo.lua): pure-Lua battery discharge reading (task 4/12)"
```

---

### Task 5: CPU utilization (`/proc/stat`, persisted across polls)

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_utilization_spec.lua`
- Test: `tests/test_gpuinfo_lua_utilization.sh`

**Interfaces:**
- Consumes: a plain state table (same shape `M.read_state`/`M.write_state` from Task 1 round-trip).
- Produces: `M.read_cpu_utilization(state, stat_file)` → `number` (percentage, one decimal place as a Lua number, e.g. `27.3`), mutating `state.prev_stat`/`state.prev_idle`. `stat_file` defaults to `/proc/stat`, overridable for tests.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_utilization_spec.lua`:

```lua
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

local work_dir = os.getenv("GPUINFO_TEST_WORK_DIR")
assert(work_dir, "GPUINFO_TEST_WORK_DIR must be set by the test wrapper")
local stat_file = work_dir .. "/stat"

local function write_stat(user, nice, system, idle, iowait, irq, softirq)
    local f = assert(io.open(stat_file, "w"))
    f:write(string.format("cpu  %d %d %d %d %d %d %d 0 0 0\n", user, nice, system, idle, iowait, irq, softirq))
    f:close()
end

-- First-ever call (no prev_stat/prev_idle in state) must seed rather than
-- crash or report a nonsense huge percentage -- mirrors the already-fixed
-- #2021/#2022 cold-start contract: a brand new state reads back as 0%, not
-- a division-by-zero and not garbage from diffing against zero.
write_stat(1000, 0, 500, 8000, 0, 0, 0)
local state = {}
local first = gpuinfo.read_cpu_utilization(state, stat_file)
check(first == 0.0, "first-ever call did not read as 0%%: got " .. tostring(first))
check(state.prev_stat ~= nil and state.prev_idle ~= nil, "first call did not seed prev_stat/prev_idle into state")

-- A second poll with more busy time than idle time reports a real,
-- persisted-across-calls percentage.
write_stat(1100, 0, 550, 8010, 0, 0, 0) -- stat delta=150, idle delta=10 -> 150/160*100 = 93.75 -> "%.1f" = 93.8
local second = gpuinfo.read_cpu_utilization(state, stat_file)
check(math.abs(second - 93.8) < 0.05, "second poll did not compute the expected percentage: got " .. tostring(second))

-- Out-of-spec: a state table that already carries a *string* prev_stat (as
-- it would after a read_state()/write_state() JSON round-trip, since JSON
-- numbers can come back as either type depending on the decoder) must still
-- work -- this is exactly the boundary between this function and Task 1's
-- state module, so it's tested here rather than assumed.
local string_state = {prev_stat = "1000", prev_idle = "8000"}
write_stat(1100, 0, 550, 8010, 0, 0, 0)
local from_strings = gpuinfo.read_cpu_utilization(string_state, stat_file)
check(math.abs(from_strings - 93.8) < 0.05, "a state with string-typed prev_stat/prev_idle was not handled: got " .. tostring(from_strings))

os.exit(failures == 0 and 0 or 1)
```

Create `tests/test_gpuinfo_lua_utilization.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

GPUINFO_TEST_WORK_DIR="$work_dir" lua "$TESTS_DIR/lua/gpuinfo_utilization_spec.lua" ||
    fail "gpuinfo_utilization_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_utilization.sh && bash tests/test_gpuinfo_lua_utilization.sh`
Expected: FAIL — `read_cpu_utilization` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua`:

```lua
--- Reads current CPU utilization as a percentage, diffed against the
--- previous poll's totals persisted in `state.prev_stat`/`state.prev_idle`.
--- Seeds both to the current reading on the very first call (no prior state),
--- which makes that first call report 0% instead of a division-by-zero or a
--- nonsense diff against zero -- the same cold-start contract #2021/#2022
--- already fixed for the bash version.
function M.read_cpu_utilization(state, stat_file)
    stat_file = stat_file or "/proc/stat"
    local f = assert(io.open(stat_file, "r"), "could not open " .. stat_file)
    local line = f:read("*l")
    f:close()
    local user, nice, system, idle, iowait, irq, softirq =
        line:match("^cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
    local curr_stat = tonumber(user) + tonumber(nice) + tonumber(system)
        + tonumber(irq) + tonumber(softirq) + tonumber(iowait)
    local curr_idle = tonumber(idle)

    local prev_stat = tonumber(state.prev_stat)
    local prev_idle = tonumber(state.prev_idle)
    if not prev_stat or not prev_idle then
        prev_stat, prev_idle = curr_stat, curr_idle
    end

    local diff_stat = curr_stat - prev_stat
    local diff_idle = curr_idle - prev_idle
    state.prev_stat = curr_stat
    state.prev_idle = curr_idle

    local total = diff_stat + diff_idle
    local pct = total > 0 and (diff_stat / total) * 100 or 0
    return tonumber(string.format("%.1f", pct))
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_utilization.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_utilization_spec.lua tests/test_gpuinfo_lua_utilization.sh
git commit -m "feat(gpuinfo.lua): CPU utilization from /proc/stat (task 5/12)"
```

---

### Task 6: CPU clock speed (cpufreq sysfs)

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_clockspeed_spec.lua`
- Test: `tests/test_gpuinfo_lua_clockspeed.sh`

**Interfaces:**
- Produces: `M.read_cpu_clock_speed(cpu_sysfs_dir)` → `current_mhz: number|nil, max_mhz: number|nil`.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_clockspeed_spec.lua`:

```lua
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

-- A host with no cpufreq scaling driver at all (virtualized/cloud CPUs, some
-- ARM boards, CI runners) has no /sys/devices/system/cpu/cpufreq tree -- must
-- read as nil, not crash (this is the exact #2028 shape, re-derived fresh
-- here rather than needing that bash fix ported, per the spec).
local empty_dir = work_dir .. "/empty"
os.execute("mkdir -p " .. empty_dir)
local cur1, max1 = gpuinfo.read_cpu_clock_speed(empty_dir)
check(cur1 == nil, "a missing cpufreq tree did not read current speed as nil: got " .. tostring(cur1))
check(max1 == nil, "a missing cpufreq tree did not read max speed as nil: got " .. tostring(max1))

-- Two policies average correctly, and max comes from cpu0's own file.
local dir2 = work_dir .. "/two_policy"
os.execute("mkdir -p " .. dir2 .. "/cpufreq/policy0 " .. dir2 .. "/cpufreq/policy1 " .. dir2 .. "/cpu0/cpufreq")
write_file(dir2 .. "/cpufreq/policy0/scaling_cur_freq", "1200000")
write_file(dir2 .. "/cpufreq/policy1/scaling_cur_freq", "2400000")
write_file(dir2 .. "/cpu0/cpufreq/cpuinfo_max_freq", "3600000")
local cur2, max2 = gpuinfo.read_cpu_clock_speed(dir2)
check(cur2 == 1800.0, "two policies (1.2GHz+2.4GHz) did not average to 1800MHz: got " .. tostring(cur2))
check(max2 == 3600.0, "max frequency did not read as 3600MHz: got " .. tostring(max2))

-- Out-of-spec: a non-numeric value in one policy's file (a driver quirk)
-- must be skipped, not crash the average.
local dir3 = work_dir .. "/garbage_policy"
os.execute("mkdir -p " .. dir3 .. "/cpufreq/policy0 " .. dir3 .. "/cpufreq/policy1 " .. dir3 .. "/cpu0/cpufreq")
write_file(dir3 .. "/cpufreq/policy0/scaling_cur_freq", "not-a-number")
write_file(dir3 .. "/cpufreq/policy1/scaling_cur_freq", "2000000")
write_file(dir3 .. "/cpu0/cpufreq/cpuinfo_max_freq", "3000000")
local cur3 = gpuinfo.read_cpu_clock_speed(dir3)
check(cur3 == 2000.0, "a garbage policy reading was not skipped from the average: got " .. tostring(cur3))

os.exit(failures == 0 and 0 or 1)
```

Create `tests/test_gpuinfo_lua_clockspeed.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

GPUINFO_TEST_WORK_DIR="$work_dir" lua "$TESTS_DIR/lua/gpuinfo_clockspeed_spec.lua" ||
    fail "gpuinfo_clockspeed_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_clockspeed.sh && bash tests/test_gpuinfo_lua_clockspeed.sh`
Expected: FAIL — `read_cpu_clock_speed` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua`:

```lua
--- Reads current (averaged across policies) and max CPU clock speed in MHz
--- from cpufreq sysfs, pure Lua -- no awk, and guarded existence checks
--- throughout so a host with no cpufreq scaling driver (virtualized/cloud
--- CPUs, some ARM boards, CI runners) reads as (nil, nil) instead of crashing.
function M.read_cpu_clock_speed(cpu_sysfs_dir)
    cpu_sysfs_dir = cpu_sysfs_dir or "/sys/devices/system/cpu"
    local sum, count = 0, 0
    local cpufreq_dir = cpu_sysfs_dir .. "/cpufreq"
    if lfs.attributes(cpufreq_dir, "mode") == "directory" then
        for entry in lfs.dir(cpufreq_dir) do
            if entry:match("^policy") then
                local raw = read_first_line(cpufreq_dir .. "/" .. entry .. "/scaling_cur_freq")
                local khz = raw and tonumber(raw)
                if khz then
                    sum = sum + khz
                    count = count + 1
                end
            end
        end
    end
    local current_mhz = count > 0 and (sum / count / 1000) or nil

    local max_raw = read_first_line(cpu_sysfs_dir .. "/cpu0/cpufreq/cpuinfo_max_freq")
    local max_khz = max_raw and tonumber(max_raw)
    local max_mhz = max_khz and (max_khz / 1000) or nil

    return current_mhz, max_mhz
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_clockspeed.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_clockspeed_spec.lua tests/test_gpuinfo_lua_clockspeed.sh
git commit -m "feat(gpuinfo.lua): pure-Lua cpufreq clock-speed reading (task 6/12)"
```

---

### Task 7: Temperature + fan speed (`sensors -j` + explicit priority)

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_sensors_spec.lua`
- Test: `tests/test_gpuinfo_lua_sensors.sh`

**Interfaces:**
- Produces: `M.read_sensors(sensors_json_text)` → `temperature: number|nil, fan_speed: number|nil`. Takes the raw `sensors -j` output text directly (not a shell-out itself) so it's testable with canned JSON; Task 11 wires the real `io.popen("sensors -j 2>/dev/null")` call.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_sensors_spec.lua`:

```lua
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

-- edge (amdgpu GPU) beats Tctl (AMD CPU) beats Package id (Intel CPU) --
-- the explicit priority this rewrite deliberately introduces (see spec:
-- "Explicit behavior change: sensor-match precedence"). Both present at once:
-- edge must win, because a module called "gpuinfo" should prefer an actual
-- GPU reading over a CPU proxy.
local both = [[{
  "k10temp-pci-00c3": {"Tctl": {"temp1_input": 45.0}},
  "amdgpu-pci-0100": {"edge": {"temp1_input": 60.0}}
}]]
local temp1 = gpuinfo.read_sensors(both)
check(temp1 == 60, "edge did not win over Tctl when both are present: got " .. tostring(temp1))

-- Tctl alone (AMD CPU, no amdgpu GPU) still matches.
local tctl_only = [[{"k10temp-pci-00c3": {"Tctl": {"temp1_input": 45.0}}}]]
check(gpuinfo.read_sensors(tctl_only) == 45, "Tctl alone was not picked up")

-- Tdie alone -- a separate alternative from Tctl, both must work
-- independently (a board/driver may only ever expose one of the two).
local tdie_only = [[{"k10temp-pci-00c3": {"Tdie": {"temp1_input": 52.0}}}]]
check(gpuinfo.read_sensors(tdie_only) == 52, "Tdie alone was not picked up")

-- Package id (Intel CPU package) is the last-resort fallback.
local package_only = [[{"coretemp-isa-0000": {"Package id 0": {"temp1_input": 38.0}}}]]
check(gpuinfo.read_sensors(package_only) == 38, "Package id was not picked up as the last-resort fallback")

-- Fan speed: any chip with a "fanN" label and a numeric input.
local with_fan = [[{"nct6775-isa-0290": {"fan1": {"fan1_input": 1200}}}]]
local _, fan = gpuinfo.read_sensors(with_fan)
check(fan == 1200, "fan speed was not extracted: got " .. tostring(fan))

-- Out-of-spec: no matching chip/label at all -- nil, not a crash.
check(gpuinfo.read_sensors("{}") == nil, "empty sensors data did not read as nil temperature")

-- Out-of-spec: `sensors -j` itself produced no output at all (sensors failed
-- or isn't installed) -- also nil, not a JSON-decode crash.
check(gpuinfo.read_sensors("") == nil, "empty string input crashed instead of reading as nil")

-- Out-of-spec: malformed JSON (a `sensors` version that half-writes output,
-- or is interrupted) -- degrades to nil rather than raising.
check(gpuinfo.read_sensors("{ this is not json") == nil, "malformed JSON crashed read_sensors instead of degrading to nil")

os.exit(failures == 0 and 0 or 1)
```

Create `tests/test_gpuinfo_lua_sensors.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

lua "$TESTS_DIR/lua/gpuinfo_sensors_spec.lua" || fail "gpuinfo_sensors_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_sensors.sh && bash tests/test_gpuinfo_lua_sensors.sh`
Expected: FAIL — `read_sensors` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua`:

```lua
-- Checked in this order for every chip in the sensors -j output: GPU
-- readings before CPU proxies (see spec: "Explicit behavior change").
local TEMPERATURE_LABEL_PRIORITY = {"edge", "junction", "Tctl", "Tdie", "Package id"}

--- Parses `sensors -j` output (passed in as `sensors_json`, so this stays
--- testable without shelling out itself -- Task 11 wires the real
--- `io.popen("sensors -j 2>/dev/null")` call) into (temperature, fan_speed).
--- Malformed/empty input degrades to (nil, nil) rather than raising, since
--- this runs on every single poll.
function M.read_sensors(sensors_json)
    if not sensors_json or sensors_json == "" then
        return nil, nil
    end
    local ok, data = pcall(json.decode, sensors_json)
    if not ok or type(data) ~= "table" then
        return nil, nil
    end

    local temperature
    for _, wanted_label in ipairs(TEMPERATURE_LABEL_PRIORITY) do
        for _, chip in pairs(data) do
            if type(chip) == "table" then
                for label, entry in pairs(chip) do
                    if type(entry) == "table" and label:find(wanted_label, 1, true) then
                        for key, value in pairs(entry) do
                            if key:match("^temp%d+_input$") and type(value) == "number" then
                                temperature = math.floor(value)
                                break
                            end
                        end
                    end
                    if temperature then
                        break
                    end
                end
            end
            if temperature then
                break
            end
        end
        if temperature then
            break
        end
    end

    local fan_speed
    for _, chip in pairs(data) do
        if type(chip) == "table" and not fan_speed then
            for label, entry in pairs(chip) do
                if type(entry) == "table" and label:match("^fan%d") then
                    for key, value in pairs(entry) do
                        if key:match("^fan%d+_input$") and type(value) == "number" then
                            fan_speed = math.floor(value)
                            break
                        end
                    end
                end
            end
        end
    end

    return temperature, fan_speed
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_sensors.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_sensors_spec.lua tests/test_gpuinfo_lua_sensors.sh
git commit -m "feat(gpuinfo.lua): sensors -j temperature/fan parsing with explicit priority (task 7/12)"
```

---

### Task 8: Icon/bucket mapping + JSON output assembly

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_output_spec.lua`
- Test: `tests/test_gpuinfo_lua_output.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks (pure formatting, takes a plain `fields` table the later vendor-branch tasks and Task 11 populate: `primary_gpu`, `temperature`, `utilization`, `fan_speed`, `current_clock_speed`, `max_clock_speed`, `core_clock`, `power_usage`, `power_limit`, `power_discharge`, `emoji` (boolean)).
- Produces: `M.map_floor(spec, value)` → `string` (ported 1:1 from bash `map_floor`); `M.generate_json(fields)` → `string` (one JSON object, matching the bash version's exact field wording).

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_output_spec.lua`:

```lua
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

-- generate_json must always produce something json.decode accepts -- this is
-- the exact #2021/#2022 contract (waybar reads this line by line as JSON).
local minimal = gpuinfo.generate_json({primary_gpu = "Not found"})
local ok, decoded = pcall(json.decode, minimal)
check(ok, "generate_json with no readings at all did not produce valid JSON: " .. tostring(minimal))
check(ok and decoded.percentage ~= nil, "percentage was missing/null with no temperature reading")

-- A full set of readings produces the documented tooltip segments.
local full = gpuinfo.generate_json({
    primary_gpu = "AMD Radeon RX 7800",
    temperature = 62,
    utilization = 45.0,
    fan_speed = 1400,
    current_clock_speed = 1800,
    max_clock_speed = 3600,
    power_usage = 120,
    power_limit = 200,
    power_discharge = 15.5,
})
local ok2, decoded2 = pcall(json.decode, full)
check(ok2, "generate_json with a full field set did not produce valid JSON")
check(decoded2.text:find("62"), "text field did not include the temperature")
check(decoded2.tooltip:find("45"), "tooltip did not include utilization")
check(decoded2.tooltip:find("1800/3600 MHz"), "tooltip did not include the clock speed segment in the documented format")
check(decoded2.tooltip:find("120/200 W"), "tooltip did not include the power usage/limit segment")
check(decoded2.tooltip:find("15.5 W"), "tooltip did not include the power discharge segment")
check(decoded2.class[1] == "temp-60", "temperature class bucket was wrong: got " .. tostring(decoded2.class[1]))
check(decoded2.class[2] == "util-40", "utilization class bucket was wrong: got " .. tostring(decoded2.class[2]))
check(decoded2.percentage == 62, "percentage did not mirror the temperature")

-- core_clock (the AMD-branch-only single-value clock reading) is a separate
-- tooltip line from current/max clock speed, and the two must not both
-- appear -- mirrors the bash version's two separate tooltip_parts entries
-- under the same key.
local core_clock_only = gpuinfo.generate_json({primary_gpu = "AMD Radeon", core_clock = 1500})
local ok3, decoded3 = pcall(json.decode, core_clock_only)
check(ok3, "generate_json with only core_clock did not produce valid JSON")
check(decoded3.tooltip:find("1500 MHz"), "core_clock alone did not appear in the tooltip")

-- Out-of-spec: a negative or absurd temperature (a sensor glitch) must still
-- clamp into a valid bucket/percentage instead of producing an out-of-range
-- or negative "percentage" waybar can't render sensibly.
local negative = gpuinfo.generate_json({primary_gpu = "x", temperature = -5})
local ok4, decoded4 = pcall(json.decode, negative)
check(ok4, "a negative temperature broke JSON generation")
check(decoded4.percentage == 0, "a negative temperature was not clamped to 0%%: got " .. tostring(decoded4.percentage))

local huge = gpuinfo.generate_json({primary_gpu = "x", temperature = 5000})
local ok5, decoded5 = pcall(json.decode, huge)
check(ok5, "an absurdly high temperature broke JSON generation")
check(decoded5.percentage == 100, "an absurd temperature was not clamped to 100%%: got " .. tostring(decoded5.percentage))

os.exit(failures == 0 and 0 or 1)
```

Create `tests/test_gpuinfo_lua_output.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

lua "$TESTS_DIR/lua/gpuinfo_output_spec.lua" || fail "gpuinfo_output_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_output.sh && bash tests/test_gpuinfo_lua_output.sh`
Expected: FAIL — `generate_json` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua`:

```lua
local function clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

--- Ported 1:1 from the bash version's map_floor: given a "threshold:value,
--- threshold:value, ..., default" spec string and a numeric value, returns
--- the value for the highest threshold the number clears, or the default.
function M.map_floor(spec, value)
    local pairs_list = {}
    for piece in (spec .. ","):gmatch("([^,]*),") do
        piece = piece:gsub("^%s+", ""):gsub("%s+$", "")
        if piece ~= "" then
            pairs_list[#pairs_list + 1] = piece
        end
    end
    local default_val
    if pairs_list[#pairs_list] and not pairs_list[#pairs_list]:find(":") then
        default_val = pairs_list[#pairs_list]
        pairs_list[#pairs_list] = nil
    end
    local num = tonumber(tostring(value):match("^-?%d+"))
    for _, pair in ipairs(pairs_list) do
        local key, val = pair:match("^([^:]*):(.*)$")
        local key_num = key and tonumber(key)
        if num and key_num and num > key_num then
            return val
        end
    end
    return default_val or " "
end

--- Assembles the waybar custom-module JSON object -- text/tooltip/class/
--- percentage/alt -- from whatever fields a vendor branch (Tasks 9-11)
--- populated. Always produces valid JSON, even with no readings at all
--- (waybar's return-type:json reads this line by line; a malformed or empty
--- line breaks the whole module, the #2021/#2022 contract this preserves).
function M.generate_json(fields)
    local emoji = fields.emoji
    local temp_lv = emoji and "85:🌋, 65:🔥, 45:☁️, ❄️" or "85:, 65:, 45:☁, ❄"
    local util_lv = "90:, 60:󰓅, 30:󰾅, 󰾆"
    local speedo_icon = M.map_floor(util_lv, fields.utilization or 0)
    local thermo_icon = M.map_floor(temp_lv, fields.temperature or -999)

    local temp_val = fields.temperature and math.floor(fields.temperature) or nil
    local temp_clamped = temp_val and clamp(temp_val, 0, 999) or 0
    local temp_bucket = clamp(math.floor(temp_clamped / 5) * 5, 0, 100)
    local temp_class = "temp-" .. temp_bucket

    local util_val = fields.utilization and math.floor(fields.utilization) or 0
    util_val = clamp(util_val, 0, 100)
    local util_bucket = math.floor(util_val / 10) * 10
    local util_class = "util-" .. util_bucket

    local temp_pct = clamp(temp_val or 0, 0, 100)

    local tooltip = (fields.primary_gpu or "Not found") .. "\n" .. thermo_icon .. " Temperature: " .. (temp_val or "") .. "°C"

    if fields.utilization then
        tooltip = tooltip .. "\n" .. speedo_icon .. " Utilization: " .. fields.utilization .. "%"
    end
    if fields.current_clock_speed and fields.max_clock_speed then
        tooltip = tooltip .. "\n Clock Speed: " .. fields.current_clock_speed .. "/" .. fields.max_clock_speed .. " MHz"
    end
    if fields.core_clock then
        tooltip = tooltip .. "\n Clock Speed: " .. fields.core_clock .. " MHz"
    end
    if fields.power_usage then
        if fields.power_limit then
            tooltip = tooltip .. "\n󱪉 Power Usage: " .. fields.power_usage .. "/" .. fields.power_limit .. " W"
        else
            tooltip = tooltip .. "\n󱪉 Power Usage: " .. fields.power_usage .. " W"
        end
    end
    if fields.power_discharge and tostring(fields.power_discharge) ~= "0" then
        tooltip = tooltip .. "\n Power Discharge: " .. fields.power_discharge .. " W"
    end
    if fields.fan_speed then
        tooltip = tooltip .. "\n Fan Speed: " .. fields.fan_speed .. " RPM"
    end

    return json.encode({
        text = thermo_icon .. " " .. (temp_val or "") .. "°C",
        tooltip = tooltip,
        class = {temp_class, util_class},
        percentage = temp_pct,
        alt = tostring(temp_bucket),
    })
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_output.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_output_spec.lua tests/test_gpuinfo_lua_output.sh
git commit -m "feat(gpuinfo.lua): icon/bucket mapping and JSON output assembly (task 8/12)"
```

---

### Task 9: NVIDIA vendor branch

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_nvidia_spec.lua`
- Test: `tests/test_gpuinfo_lua_nvidia.sh`

**Interfaces:**
- Consumes: `M.read_sensors` (Task 7, for the nouveau "general query" path).
- Produces: `M.nvidia_query(opts)` → `fields: table, suspended: boolean`. `opts` carries `nvidia_gpu` (name), `is_nouveau` (bool), `nvidia_addr`, `tired` (bool), `runtime_status_path` (overridable, default `/sys/bus/pci/devices/0000:<addr>/power/runtime_status`), `nvidia_smi_cmd` (overridable, default `"nvidia-smi"`), and (for the nouveau path) `sensors_json`/`stat_file`/`cpu_sysfs_dir`/`power_supply_dir` passed straight through to the same generic-query pieces Tasks 4/5/6/7 already provide.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_nvidia_spec.lua`:

```lua
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
```

Create `tests/test_gpuinfo_lua_nvidia.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

GPUINFO_TEST_WORK_DIR="$work_dir" lua "$TESTS_DIR/lua/gpuinfo_nvidia_spec.lua" ||
    fail "gpuinfo_nvidia_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_nvidia.sh && bash tests/test_gpuinfo_lua_nvidia.sh`
Expected: FAIL — `nvidia_query` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua`:

```lua
--- NVIDIA vendor branch. Returns (fields, suspended). When `opts.is_nouveau`
--- (the open-source driver, which nvidia-smi cannot query), falls back to
--- the same generic sensors/proc-stat/cpufreq/battery reads every other
--- "no dedicated vendor tool" path uses.
function M.nvidia_query(opts)
    local fields = {primary_gpu = "NVIDIA " .. opts.nvidia_gpu}

    if opts.is_nouveau then
        local temperature, fan_speed = M.read_sensors(opts.sensors_json or "")
        fields.temperature = temperature
        fields.fan_speed = fan_speed
        fields.power_discharge = M.read_battery_discharge(opts.power_supply_dir or "/sys/class/power_supply")
        local state = opts.state or {}
        fields.utilization = M.read_cpu_utilization(state, opts.stat_file)
        fields.current_clock_speed, fields.max_clock_speed = M.read_cpu_clock_speed(opts.cpu_sysfs_dir)
        return fields, false
    end

    if opts.tired then
        local runtime_status_path = opts.runtime_status_path
            or ("/sys/bus/pci/devices/0000:" .. tostring(opts.nvidia_addr) .. "/power/runtime_status")
        local status = read_first_line(runtime_status_path)
        if status and status:find("suspend") then
            return fields, true
        end
    end

    local nvidia_smi_cmd = opts.nvidia_smi_cmd or "nvidia-smi"
    local handle = io.popen(
        nvidia_smi_cmd
            .. " --query-gpu=temperature.gpu,utilization.gpu,clocks.current.graphics,clocks.max.graphics,power.draw,power.limit"
            .. " --format=csv,noheader,nounits 2>/dev/null"
    )
    local line = handle and handle:read("*l")
    if handle then
        handle:close()
    end
    if line then
        local values = {}
        for value in line:gmatch("[^,]+") do
            values[#values + 1] = value:gsub("^%s+", ""):gsub("%s+$", "")
        end
        fields.temperature = values[1]
        fields.utilization = values[2]
        fields.current_clock_speed = values[3]
        fields.max_clock_speed = values[4]
        fields.power_usage = values[5]
        fields.power_limit = values[6]
    end
    return fields, false
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_nvidia.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_nvidia_spec.lua tests/test_gpuinfo_lua_nvidia.sh
git commit -m "feat(gpuinfo.lua): NVIDIA vendor branch (task 9/12)"
```

---

### Task 10: AMD vendor branch

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_amd_spec.lua`
- Test: `tests/test_gpuinfo_lua_amd.sh`

**Interfaces:**
- Consumes: `M.read_sensors`/`M.read_battery_discharge`/`M.read_cpu_utilization`/`M.read_cpu_clock_speed` (Tasks 4-7, for the fallback path).
- Produces: `M.amd_query(opts)` → `fields: table`. `opts.amdgpu_output` is the raw stdout text `amdgpu.py` produced (so this stays testable without invoking Python) — Task 11 wires the real `io.popen(python_bin .. " " .. amdgpu_py_path)` call.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_amd_spec.lua`:

```lua
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

-- amdgpu.py's real JSON shape (see Configs/.local/lib/hyde/amdgpu.py).
local good_output = '{"GPU Temperature": "62°C", "GPU Load": "45.0%", "GPU Core Clock": "1500 MHz", "GPU Power Usage": "120 Watts"}'
local fields = gpuinfo.amd_query({amdgpu_gpu = "Radeon RX 7800", amdgpu_output = good_output})
check(fields.primary_gpu == "AMD Radeon RX 7800", "primary_gpu was not set: got " .. tostring(fields.primary_gpu))
check(fields.temperature == "62", "temperature suffix (°C) was not stripped: got " .. tostring(fields.temperature))
check(fields.utilization == "45.0", "utilization suffix (%%) was not stripped: got " .. tostring(fields.utilization))
check(fields.core_clock == "1500", "core_clock suffix (MHz) was not stripped: got " .. tostring(fields.core_clock))
check(fields.power_usage == "120", "power_usage suffix (Watts) was not stripped: got " .. tostring(fields.power_usage))

-- "No AMD GPUs detected." falls back to the generic sensors-based query,
-- exactly like the bash version.
local no_gpu_fields = gpuinfo.amd_query({
    amdgpu_gpu = "Radeon",
    amdgpu_output = "No AMD GPUs detected.",
    sensors_json = "{}",
    stat_file = "/proc/stat",
    cpu_sysfs_dir = "/nonexistent",
    power_supply_dir = "/nonexistent",
})
check(no_gpu_fields.primary_gpu == "AMD Radeon", "the fallback path did not still set primary_gpu")
check(no_gpu_fields.core_clock == nil, "the fallback path incorrectly carried over an AMD-specific field")

-- Out-of-spec: amdgpu.py hit one of its own exception branches and printed a
-- plain error string instead of JSON (e.g. "Runtime Error: ..."). The bash
-- version only checked for two specific literal substrings and would have
-- tried to jq-parse this as JSON anyway; this rewrite instead falls back
-- whenever the output doesn't actually decode as the expected object, which
-- also correctly covers this case the bash version didn't.
local error_fields = gpuinfo.amd_query({
    amdgpu_gpu = "Radeon",
    amdgpu_output = "Runtime Error: something unexpected",
    sensors_json = "{}",
    stat_file = "/proc/stat",
    cpu_sysfs_dir = "/nonexistent",
    power_supply_dir = "/nonexistent",
})
check(error_fields.primary_gpu == "AMD Radeon", "a non-JSON error string from amdgpu.py did not fall back cleanly")
check(error_fields.core_clock == nil, "a non-JSON error string was still treated as if it were valid amdgpu.py JSON")

os.exit(failures == 0 and 0 or 1)
```

Create `tests/test_gpuinfo_lua_amd.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

lua "$TESTS_DIR/lua/gpuinfo_amd_spec.lua" || fail "gpuinfo_amd_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_amd.sh && bash tests/test_gpuinfo_lua_amd.sh`
Expected: FAIL — `amd_query` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua`:

```lua
--- AMD vendor branch. Parses amdgpu.py's JSON (see Configs/.local/lib/hyde/
--- amdgpu.py) with luautils.json instead of `jq`+`sed`. Falls back to the
--- generic sensors/proc-stat/cpufreq/battery reads whenever the output isn't
--- the expected object -- covers "No AMD GPUs detected." (amdgpu.py's own
--- explicit no-hardware message) *and* any of amdgpu.py's exception-branch
--- error strings, which the bash version's two-literal-substring check did
--- not (it would have tried to jq-parse those as JSON).
function M.amd_query(opts)
    local fields = {primary_gpu = "AMD " .. opts.amdgpu_gpu}

    local ok, decoded = pcall(json.decode, opts.amdgpu_output or "")
    if ok and type(decoded) == "table" and decoded["GPU Temperature"] then
        fields.temperature = decoded["GPU Temperature"]:gsub("°C", "")
        fields.utilization = decoded["GPU Load"]:gsub("%%", "")
        fields.core_clock = decoded["GPU Core Clock"]:gsub(" GHz", ""):gsub(" MHz", "")
        fields.power_usage = decoded["GPU Power Usage"]:gsub(" Watts", "")
        return fields
    end

    local temperature, fan_speed = M.read_sensors(opts.sensors_json or "")
    fields.temperature = temperature
    fields.fan_speed = fan_speed
    fields.power_discharge = M.read_battery_discharge(opts.power_supply_dir or "/sys/class/power_supply")
    local state = opts.state or {}
    fields.utilization = M.read_cpu_utilization(state, opts.stat_file)
    fields.current_clock_speed, fields.max_clock_speed = M.read_cpu_clock_speed(opts.cpu_sysfs_dir)
    return fields
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_amd.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_amd_spec.lua tests/test_gpuinfo_lua_amd.sh
git commit -m "feat(gpuinfo.lua): AMD vendor branch (task 10/12)"
```

---

### Task 11: CLI dispatch (`M.cli_main`) + auto-run guard

**Files:**
- Modify: `Configs/.local/lib/hyde/gpuinfo.lua`
- Test: `tests/lua/gpuinfo_cli_spec.lua`
- Test: `tests/test_gpuinfo_lua_cli.sh`

**Interfaces:**
- Consumes: every `M.*` function from Tasks 1-10.
- Produces: `M.cli_main(argv, opts)` → `exit_code: number` (writes JSON/help/status text to stdout via `opts.print_fn`, defaulting to `print`, so tests can capture it instead of writing to real stdout). The bottom-of-file auto-run guard (copied from `open.lua`'s pattern) calls this with real `arg`/`print` only when the file is executed directly.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/gpuinfo_cli_spec.lua`:

```lua
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
```

Create `tests/test_gpuinfo_lua_cli.sh`:

```sh
#!/usr/bin/env sh
. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

XDG_RUNTIME_DIR="$work_dir" GPUINFO_TEST_WORK_DIR="$work_dir" lua "$TESTS_DIR/lua/gpuinfo_cli_spec.lua" ||
    fail "gpuinfo_cli_spec reported defects"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_cli.sh && bash tests/test_gpuinfo_lua_cli.sh`
Expected: FAIL — `cli_main` is nil.

- [ ] **Step 3: Write minimal implementation**

Add to `Configs/.local/lib/hyde/gpuinfo.lua` (before `return M`):

```lua
local argparse = require("luautils.argparse")

local VENDOR_STAT_KEY = {nvidia = "nvidia_enable", amd = "amd_enable", intel = "intel_enable"}

--- CLI entry point. `opts` (all optional, used by tests to avoid touching
--- the real machine): print_fn, state_suffix_override, detect_vendor_opts,
--- sensors_cmd, nvidia_smi_cmd, amdgpu_py_cmd, python_bin, lspci_cmd,
--- power_supply_dir, stat_file, cpu_sysfs_dir.
function M.cli_main(argv, opts)
    opts = opts or {}
    local print_fn = opts.print_fn or print
    -- Separate from print_fn on purpose: a cold start (no state file yet)
    -- reaches both this diagnostic *and* the regular generate_json print
    -- below in the same invocation. Waybar's return-type:json reads stdout
    -- line by line, so mixing the two on one stream is exactly the
    -- #2021/#2022 bug this rewrite must not reintroduce -- this always goes
    -- to stderr, never through print_fn/stdout.
    local warn_fn = opts.warn_fn or function(s) io.stderr:write(s, "\n") end

    local parser = argparse("gpuinfo", "GPU/CPU info for the waybar custom/gpuinfo module")
    parser:option("--use", "Only call the specified GPU"):argname("GPU")
    parser:option("--stat", "Report whether GPU is enabled (amd, intel, nvidia)"):argname("GPU")
    parser:flag("--toggle", "Toggle available GPU")
    parser:flag("--reset", "Remove & restart all detection")
    parser:flag("--tired", "Do not query nvidia-smi if the GPU is in suspend mode")
    parser:flag("--emoji", "Use emoji instead of glyphs")
    parser:flag("--startup", "Set this GPU at startup (used with --use)")
    local args = parser:parse(argv)

    local suffix = opts.state_suffix_override or (args.startup and "" or (args.use and ("_" .. args.use) or ""))
    local state = M.read_state(suffix)

    if args.tired then
        state.tired = true
    end
    if args.emoji then
        state.emoji = true
    end

    local has_any_vendor = state.nvidia_enable or state.amd_enable or state.intel_enable
    if args.reset or not has_any_vendor then
        local detected = M.detect_vendor(opts.detect_vendor_opts)
        state.nvidia_enable = detected.nvidia
        state.amd_enable = detected.amd
        state.intel_enable = detected.intel
        state.nvidia_gpu = detected.nvidia_gpu
        state.amd_gpu = detected.amd_gpu
        state.intel_gpu = detected.intel_gpu
        state.nvidia_addr = detected.nvidia_addr
        state.amd_addr = detected.amd_addr
        state.intel_addr = detected.intel_addr
        if detected.nvidia then
            state.priority = "nvidia"
        elseif detected.amd then
            state.priority = "amd"
        elseif detected.intel then
            state.priority = "intel"
        end
        M.write_state(suffix, state)
        warn_fn(
            "Initialized: nvidia="
                .. tostring(detected.nvidia)
                .. " amd="
                .. tostring(detected.amd)
                .. " intel="
                .. tostring(detected.intel)
        )
    end

    if args.toggle then
        local next_vendor = M.toggle(state, nil)
        M.write_state(suffix, state)
        print_fn("Sensor: " .. tostring(next_vendor) .. " GPU")
        return 0
    end

    if args.use then
        local next_vendor, err = M.toggle(state, args.use)
        if not next_vendor then
            print_fn("Error: " .. err)
            M.write_state(suffix, state)
            return 1
        end
        M.write_state(suffix, state)
    end

    if args.stat then
        local key = VENDOR_STAT_KEY[args.stat]
        if not key then
            print_fn("Error: Invalid argument for --stat. Use amd, intel, or nvidia.")
            return 1
        end
        if state[key] then
            print_fn(key .. ": true")
            return 0
        end
        print_fn("GPU not enabled.")
        return 1
    end

    local common_opts = {
        sensors_json = opts.sensors_json,
        stat_file = opts.stat_file,
        cpu_sysfs_dir = opts.cpu_sysfs_dir,
        power_supply_dir = opts.power_supply_dir,
        state = state,
    }
    if not opts.sensors_json then
        local handle = io.popen((opts.sensors_cmd or "sensors") .. " -j 2>/dev/null")
        common_opts.sensors_json = handle and handle:read("*a") or ""
        if handle then
            handle:close()
        end
    end

    local fields
    if state.nvidia_enable then
        local nvidia_fields, suspended = M.nvidia_query({
            nvidia_gpu = state.nvidia_gpu,
            is_nouveau = state.nvidia_gpu == "Linux",
            nvidia_addr = state.nvidia_addr,
            tired = state.tired,
            nvidia_smi_cmd = opts.nvidia_smi_cmd,
            sensors_json = common_opts.sensors_json,
            stat_file = common_opts.stat_file,
            cpu_sysfs_dir = common_opts.cpu_sysfs_dir,
            power_supply_dir = common_opts.power_supply_dir,
            state = state,
        })
        if suspended then
            print_fn(json.encode({text = "󰤂", tooltip = nvidia_fields.primary_gpu .. " ⏾ Suspended mode"}))
            return 0
        end
        fields = nvidia_fields
    elseif state.amd_enable then
        local python_bin = opts.python_bin
            or ((os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/hyde/python_env/bin/python")
        local amdgpu_output = opts.amdgpu_output
        if not amdgpu_output then
            local handle = io.popen(python_bin .. " " .. (opts.amdgpu_py_cmd or (root .. "amdgpu.py")) .. " 2>/dev/null")
            amdgpu_output = handle and handle:read("*a") or ""
            if handle then
                handle:close()
            end
        end
        fields = M.amd_query({
            amdgpu_gpu = state.amd_gpu,
            amdgpu_output = amdgpu_output,
            sensors_json = common_opts.sensors_json,
            stat_file = common_opts.stat_file,
            cpu_sysfs_dir = common_opts.cpu_sysfs_dir,
            power_supply_dir = common_opts.power_supply_dir,
            state = state,
        })
    elseif state.intel_enable then
        fields = {primary_gpu = "Intel " .. tostring(state.intel_gpu)}
        fields.temperature, fields.fan_speed = M.read_sensors(common_opts.sensors_json)
        fields.power_discharge = M.read_battery_discharge(common_opts.power_supply_dir or "/sys/class/power_supply")
        fields.utilization = M.read_cpu_utilization(state, common_opts.stat_file)
        fields.current_clock_speed, fields.max_clock_speed = M.read_cpu_clock_speed(common_opts.cpu_sysfs_dir)
    else
        fields = {primary_gpu = "Not found"}
        fields.temperature, fields.fan_speed = M.read_sensors(common_opts.sensors_json)
        fields.power_discharge = M.read_battery_discharge(common_opts.power_supply_dir or "/sys/class/power_supply")
        fields.utilization = M.read_cpu_utilization(state, common_opts.stat_file)
        fields.current_clock_speed, fields.max_clock_speed = M.read_cpu_clock_speed(common_opts.cpu_sysfs_dir)
    end
    fields.emoji = state.emoji

    M.write_state(suffix, state)
    print_fn(M.generate_json(fields))
    return 0
end

local arg_count = #arg
local vararg_count = select("#", ...)
if arg_count == vararg_count and (vararg_count == 0 or select(1, ...) == arg[1]) then
    os.exit(M.cli_main(arg))
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_gpuinfo_lua_cli.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Configs/.local/lib/hyde/gpuinfo.lua tests/lua/gpuinfo_cli_spec.lua tests/test_gpuinfo_lua_cli.sh
git commit -m "feat(gpuinfo.lua): CLI dispatch, argparse wiring, auto-run guard (task 11/12)"
```

---

### Task 12: End-to-end regression port, waybar wiring, retire the bash version

**Files:**
- Create: `tests/test_gpuinfo_lua_e2e.sh` (full port of every case in `tests/test_gpuinfo.sh`, invoking `lua gpuinfo.lua` end-to-end instead of unit-testing individual `M.*` functions)
- Modify: `Configs/.local/share/waybar/modules/custom-gpuinfo#nvidia.jsonc`
- Delete: `Configs/.local/lib/hyde/gpuinfo.sh`, `tests/test_gpuinfo.sh`

**Interfaces:**
- Consumes: the full `gpuinfo.lua` from Tasks 1-11 (invoked as a subprocess via `lua gpuinfo.lua`, the same way waybar itself will run it through `hyde-shell`).

- [ ] **Step 1: Write the failing test**

Create `tests/test_gpuinfo_lua_e2e.sh` (mirrors every case from `tests/test_gpuinfo.sh`, against the real script end-to-end):

```sh
#!/usr/bin/env bash
# End-to-end port of every case in tests/test_gpuinfo.sh (the retired bash
# gpuinfo.sh's regression suite), run against gpuinfo.lua instead. Unit
# coverage for each internal piece already lives in tests/lua/gpuinfo_*_spec.lua
# (Tasks 1-11); this proves the whole CLI, wired together, behaves the same.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

script="$REPO_ROOT/Configs/.local/lib/hyde/gpuinfo.lua"
[ -f "$script" ] || {
    fail "gpuinfo.lua not found at $script"
    finish
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

fake_bin="$work_dir/bin"
mkdir -p "$fake_bin"

run() {
    XDG_RUNTIME_DIR="$work_dir/runtime" PATH="$fake_bin:$PATH" lua "$script" "$@"
}

# Cold start, no sensors at all: must always emit valid JSON, never a
# diagnostic banner mixed into stdout (the #2021/#2022 contract).
rm -rf "$work_dir/runtime"
mkdir -p "$work_dir/runtime"
stdout=$(run --use nonexistent 2>"$work_dir/stderr")
stderr=$(cat "$work_dir/stderr")
case $stdout in
*"Traceback"*) fail "cold start with no vendor produced a Lua traceback instead of a clean error/JSON: $stdout" ;;
esac

# A missing cpufreq tree, missing sensors, and no battery must all degrade
# gracefully together, all the way through the CLI -- rerun with a
# guaranteed-empty environment.
rm -rf "$work_dir/runtime"
mkdir -p "$work_dir/runtime"
cat >"$fake_bin/sensors" <<'EOF'
#!/bin/sh
echo "{}"
EOF
chmod +x "$fake_bin/sensors"
stdout2=$(run 2>"$work_dir/stderr")
stderr2=$(cat "$work_dir/stderr")
if [ -z "$stdout2" ] || ! printf '%s\n' "$stdout2" | python3 -c '
import json, sys
lines = [line for line in sys.stdin.read().splitlines() if line.strip()]
if not lines:
    raise SystemExit(1)
for line in lines:
    if not isinstance(json.loads(line), dict):
        raise SystemExit(1)
' >/dev/null 2>&1; then
    fail "a fully-empty environment did not produce a JSON object on stdout: $stdout2 (stderr: $stderr2)"
fi

# AMD k10temp Tctl/Tdie, out-of-spec value, and Tctl-vs-edge precedence --
# ported from tests/test_gpuinfo.sh's own equivalent cases, updated for the
# explicit priority this rewrite introduces (edge wins over Tctl, see spec).
cat >"$fake_bin/sensors" <<'EOF'
#!/bin/sh
cat <<'SENSORS'
{"k10temp-pci-00c3": {"Tctl": {"temp1_input": 45.0}}, "amdgpu-pci-0100": {"edge": {"temp1_input": 60.0}}}
SENSORS
EOF
chmod +x "$fake_bin/sensors"
rm -rf "$work_dir/runtime"
mkdir -p "$work_dir/runtime"
both_stdout=$(run 2>"$work_dir/stderr")
case $both_stdout in
*'60°C'*) ;;
*) fail "with both Tctl and edge present, edge (the GPU reading) did not win as the new documented priority: $both_stdout" ;;
esac

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_gpuinfo_lua_e2e.sh && bash tests/test_gpuinfo_lua_e2e.sh`
Expected: PASS already, since Tasks 1-11 built a working `gpuinfo.lua` incrementally — this step confirms that rather than finding a gap. If anything fails here, fix `gpuinfo.lua` directly (not the test) before proceeding, since this is the full-system check the unit specs couldn't cover.

- [ ] **Step 3: Wire waybar to the Lua version and retire the bash version**

`hyde-shell`'s own script resolver already prefers a `.lua` file over a same-named `.sh` file (see `Configs/.local/bin/hyde-shell`'s comment: "Lua is resolved before shell, so a script left behind by an older release cannot shadow the implementation that replaced it"). `custom-gpuinfo.jsonc`, `custom-gpuinfo#amd.jsonc`, and `custom-gpuinfo#intel.jsonc` already invoke the bare `hyde-shell gpuinfo` (no extension), so they pick up `gpuinfo.lua` automatically once `gpuinfo.sh` is gone — nothing to change there.

`custom-gpuinfo#nvidia.jsonc` is the one exception: it hardcodes the `.sh` extension and wraps the call in `hyde-shell app -t scope`, unlike the other three modules. Edit `Configs/.local/share/waybar/modules/custom-gpuinfo#nvidia.jsonc`:

```jsonc
{
  "custom/gpuinfo#nvidia": {
    "exec-if": "hyde-shell gpuinfo --stat nvidia >/dev/null 2>&1",
    "exec": "hyde-shell gpuinfo --use nvidia",
    "return-type": "json",
    "format": "{0}",
    "rotate": 0,
    "interval": 5,
    "tooltip": true,
    "max-length": 1000
  }
}
```

- [ ] **Step 4: Run the full existing test suite to confirm nothing else broke**

Run: `bash tests/run.sh`
Expected: every existing case still passes (this rewrite doesn't touch anything else), plus every new `test_gpuinfo_lua_*` case.

- [ ] **Step 5: Delete the retired bash version and its test suite**

```bash
git rm Configs/.local/lib/hyde/gpuinfo.sh tests/test_gpuinfo.sh
```

- [ ] **Step 6: Run the full test suite one more time**

Run: `bash tests/run.sh`
Expected: PASS — confirms nothing still referenced the deleted files.

- [ ] **Step 7: Commit**

```bash
git add tests/test_gpuinfo_lua_e2e.sh Configs/.local/share/waybar/modules/custom-gpuinfo#nvidia.jsonc
git commit -m "feat(gpuinfo.lua): end-to-end regression port, wire up waybar, retire gpuinfo.sh (task 12/12)"
```

- [ ] **Step 8: Note PR #2056 as superseded**

`gpuinfo.sh` no longer exists after this commit, so PR #2056 (the open bash cpufreq fix) no longer has a file to apply to. Leave a comment on that PR noting it's superseded by this rewrite and should be closed, rather than silently letting CI report a conflict — that's a GitHub-visible action, confirm the exact wording with the user before posting it.

---

## Self-Review

**Spec coverage:** every row of the spec's "what changes" table has a task — vendor detection (Task 2), toggle (Task 3), battery (Task 4), utilization (Task 5), clock speed (Task 6), sensors/temperature (Task 7), AMD branch (Task 10), NVIDIA branch (Task 9), state persistence (Task 1), CLI parsing (Task 11), waybar wiring + retirement (Task 12). The explicit sensor-precedence behavior change is implemented in Task 7 and re-asserted end-to-end in Task 12.

**Placeholder scan:** every step carries real, complete code; no "TBD"/"similar to Task N"/"add error handling" placeholders.

**Type consistency:** `M.read_state`/`M.write_state` (Task 1) are consumed with the same `(suffix)` signature everywhere they're used (Tasks 3, 5, 11). `M.detect_vendor(opts)`'s return table's `<vendor>_enable`/`<vendor>_gpu`/`<vendor>_addr` keys (Task 2) match exactly what Task 11's `cli_main` reads off `state`. `M.toggle(state, requested)` (Task 3) matches its one call site in Task 11. `M.read_sensors(sensors_json)` (Task 7) is called identically from Tasks 9, 10, and 11's own fallback/intel/generic branches. `M.generate_json(fields)` (Task 8)'s field names (`primary_gpu`, `temperature`, `utilization`, `fan_speed`, `current_clock_speed`, `max_clock_speed`, `core_clock`, `power_usage`, `power_limit`, `power_discharge`, `emoji`) match what Tasks 9, 10, and 11 populate.
