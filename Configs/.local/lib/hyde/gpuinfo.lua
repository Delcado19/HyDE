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

local function find_in_path(cmd, path_dirs)
    if cmd:match("^/") then
        -- Absolute path
        if lfs.attributes(cmd, "mode") == "file" then
            return cmd
        end
        return nil
    end
    for _, dir in ipairs(path_dirs) do
        local full_path = dir .. "/" .. cmd
        if lfs.attributes(full_path, "mode") == "file" then
            return full_path
        end
    end
    return nil
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
    -- Anchored on "]:" (the class-id's closing bracket), not a bare ":" --
    -- the PCI slot itself ("00:02.0") contains a colon earlier in the line,
    -- and Lua patterns search from the first position that matches, so a
    -- bare ":" anchor grabs everything after the *slot's* colon instead
    -- (verified empirically while writing this plan: a bare ":" pattern
    -- against the example line above returns "02.0 VGA compatible
    -- controller [0300]: Intel Corporation Iris Xe Graphics ..." --  the
    -- slot number leaking into the name -- not the intended match).
    local rest = line:match("%]:%s*(.+)$")
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

    -- Resolve lspci command to full path
    local resolved_lspci = find_in_path(lspci_cmd, path_dirs) or lspci_cmd

    local result = {nvidia = false, amd = false, intel = false}
    local nouveau_found = false

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
                        result[vendor_name .. "_gpu"] = lookup_pci_name(resolved_lspci, entry)
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
                nouveau_found = true
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

    -- nvidia is only true if there's a way to query it (nouveau or nvidia-smi present)
    if result.nvidia and not (nouveau_found or result.nvidia_smi_present) then
        result.nvidia = false
    end

    return result
end

local VENDOR_ORDER = {"nvidia", "amd", "intel"}

--- Cycles (or jumps to, if `requested` is set) the enabled GPU vendor,
--- mutating `state` in place. Returns the new vendor name, or (nil, err) if
--- `requested` names a vendor that isn't actually available.
function M.toggle(state, requested)
    local available = {}
    for _, vendor in ipairs(VENDOR_ORDER) do
        if state[vendor .. "_enable"] ~= nil then
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
        local trimmed = piece:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            pairs_list[#pairs_list + 1] = trimmed
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

return M
