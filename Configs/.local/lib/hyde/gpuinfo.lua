#!/usr/bin/env lua
local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = package.path .. ";" .. root .. "?.lua;" .. root .. "?/init.lua;"
require("luautils.init")

local json = require("luautils.json")
local lfs = require("lfs")

local M = {}

--- Path to this gpuinfo instance's state file. `suffix` matches the bash
--- version's "$gpuinfo_file$2" (a per-waybar-module-instance state, set via
--- --use/--startup so e.g. the #amd and #intel waybar modules don't clobber
--- each other's toggle/priority state).
function M.state_path(suffix)
    local runtime_dir = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
    -- UID is a bash shell variable, never exported, so os.getenv("UID") is
    -- always nil here. Stat $HOME instead, so the /tmp fallback (used when
    -- XDG_RUNTIME_DIR is unset -- when it is set it is already per-user)
    -- stays scoped per user rather than colliding on /tmp/hyde-0-gpuinfo.json.
    local uid = lfs.attributes(os.getenv("HOME") or "/", "uid") or 0
    return runtime_dir .. "/hyde-" .. tostring(uid) .. "-gpuinfo" .. (suffix or "") .. ".json"
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
    -- Example device: "Intel Corporation Kaby Lake-U GT2 [HD Graphics 620]
    -- [8086:5916] (rev 02)", following the PCI address and class prefix.
    -- -> "Kaby Lake-U GT2 [HD Graphics 620]" (drop the vendor prefix, the
    -- trailing [ids] bracket, and the (rev) suffix -- but keep a marketing-
    -- name bracket like "[HD Graphics 620]" or "[GeForce RTX 3060]": that's
    -- the name most people actually know the card by, unlike the bare
    -- codename bash's original `gsub(/ *\[[^\]]*\]/,"")` left behind).
    -- Anchored on "]:" (the class-id's closing bracket), not a bare ":" --
    -- the PCI slot itself ("00:02.0") contains a colon earlier in the line,
    -- and Lua patterns search from the first position that matches, so a
    -- bare ":" anchor grabs everything after the *slot's* colon instead
    -- (verified empirically while writing this plan: a bare ":" pattern
    -- against the example line above returns "02.0 VGA compatible
    -- controller [0300]: Intel Corporation Kaby Lake-U GT2 ..." --  the
    -- slot number leaking into the name -- not the intended match).
    local rest = line:match("%]:%s*(.+)$")
    if not rest then
        return nil
    end
    -- Only the trailing [vendor:device] id bracket is stripped -- it's
    -- always exactly 4 hex digits either side of the colon, which a
    -- marketing-name bracket never is, so this can't misfire on one.
    rest = rest:gsub("%[%x%x%x%x:%x%x%x%x%]", ""):gsub("%(rev%s*%x+%)", "")
    rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
    rest = rest:gsub("^%a+ ?%a*%a* Corporation,? ?", ""):gsub("^Advanced Micro Devices, Inc%.,? ?", "")
    -- pci.ids lists AMD's vendor name as "Advanced Micro Devices, Inc.
    -- [AMD/ATI]" -- that bracket is a vendor alias, not part of the chip's
    -- identity, and unlike a genuine marketing-name bracket it sits before
    -- the codename rather than after it, so it must go even though the
    -- rule above is to keep marketing brackets.
    rest = rest:gsub("^%[AMD/ATI%] ?", "")
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
                -- Display-name fallback only, when PCI detection couldn't
                -- resolve one via lspci. Nouveau-ness itself is recorded
                -- separately below -- comparing the name against this
                -- placeholder would misidentify a real PCI-resolved name
                -- as "not nouveau" even when nouveau is the only driver
                -- present (caught in review: cli_main used to do exactly
                -- that comparison, so a nouveau host that also happened to
                -- have a resolvable lspci name took the nvidia-smi path
                -- and got nothing back instead of the device's hwmon data).
                result.nvidia_gpu = result.nvidia_gpu or "Linux"
            end
        end
        modules_f:close()
    end
    result.nvidia_nouveau = nouveau_found

    -- nvidia-smi presence: PATH search instead of `command -v nvidia-smi`.
    for _, dir in ipairs(path_dirs) do
        if lfs.attributes(dir .. "/nvidia-smi", "mode") == "file" then
            result.nvidia_smi_present = true
            break
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
---
--- Availability comes from `state.available`, the list detection records once
--- (the port of the bash version's GPUINFO_AVAILABLE). It deliberately does
--- not come from the `*_enable` keys, in either direction:
---   * `state[v .. "_enable"] ~= nil` (presence) is wrong because cli_main
---     writes all three keys on every detection, explicit `false` included --
---     so every vendor looked available on every machine, one --toggle could
---     select a vendor that was never detected, and every later poll then
---     crashed on its never-populated `*_gpu` name (blank module until
---     --reset).
---   * truthiness alone is wrong because `*_enable` records which vendor is
---     *selected*, and the loop at the bottom of this function sets the others
---     to false -- so after one toggle there would be nothing left to cycle to
---     and --toggle would become a no-op. (Bash avoided this by *commenting
---     out* the losing GPUINFO_*_ENABLE=1 lines, keeping them greppable.)
--- A state with no recorded availability (hand-edited, or a direct API caller)
--- degrades to "whatever is currently enabled".
function M.toggle(state, requested)
    local recorded
    if type(state.available) == "table" and #state.available > 0 then
        recorded = {}
        for _, name in ipairs(state.available) do
            recorded[name] = true
        end
    end

    local available = {}
    for _, vendor in ipairs(VENDOR_ORDER) do
        local is_available
        if recorded then
            is_available = recorded[vendor]
        else
            is_available = state[vendor .. "_enable"]
        end
        if is_available then
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

-- Only accept finite decimal measurements. Missing files, driver error
-- strings, NaN and invalid types must never become plausible zero readings.
local function measurement(value, maximum)
    if type(value) == "string" then
        value = value:match("^%s*([+-]?%d+%.?%d*)%s*$")
    elseif type(value) ~= "number" then
        return nil
    end
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number < 0
        or (maximum and number > maximum) then
        return nil
    end
    return number
end

local function pci_address(addr)
    return type(addr) == "string" and addr:match("^%x%x%x%x:%x%x:%x%x%.[0-7]$") ~= nil
end

local function entries(path, pattern)
    -- Devices may disappear between the existence check and opening sysfs.
    local ok, iter, directory = pcall(lfs.dir, path)
    local result = {}
    if ok then
        for entry in iter, directory do
            if entry:match(pattern) then
                result[#result + 1] = entry
            end
        end
        table.sort(result)
    end
    return result
end

--- Read only sensors below the selected GPU's PCI device, never global
--- sensors, CPU cpufreq, /proc/stat, or battery power. Intel i915 exposes
--- actual GPU frequency in its DRM directory; unsupported metrics stay nil.
function M.read_gpu_sysfs(opts)
    local fields = {}
    if not pci_address(opts.addr) then
        return fields
    end
    local device = (opts.pci_dir or "/sys/bus/pci/devices") .. "/" .. opts.addr
    local function read(path, scale, maximum)
        local value = measurement(read_first_line(path))
        return value and measurement(value / (scale or 1), maximum) or nil
    end
    fields.utilization = read(device .. "/gpu_busy_percent", 1, 100)
    for _, entry in ipairs(entries(device .. "/hwmon", "^hwmon%d+$")) do
        local hwmon = device .. "/hwmon/" .. entry
        local driver = read_first_line(hwmon .. "/name")
        if driver == "amdgpu" or driver == "nouveau" or driver == "i915" or driver == "xe" then
            fields.temperature = read(hwmon .. "/temp1_input", 1000)
            fields.fan_speed = read(hwmon .. "/fan1_input")
            fields.current_clock_speed = read(hwmon .. "/freq1_input", 1000000)
            -- AMD APU power1_* includes CPU/SoC consumption. Do not present
            -- it as GPU-only power without a reliable scope discriminator.
            break
        end
    end
    local card = entries(device .. "/drm", "^card%d+$")[1]
    if card then
        local drm = device .. "/drm/" .. card
        fields.current_clock_speed = fields.current_clock_speed or read(drm .. "/gt_act_freq_mhz")
        fields.max_clock_speed = read(drm .. "/gt_RP0_freq_mhz")
    end
    return fields
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
--- percentage/alt -- from whatever fields a GPU query
--- populated. Always produces valid JSON, even with no readings at all
--- (waybar's return-type:json reads this line by line; a malformed or empty
--- line breaks the whole module, the #2021/#2022 contract this preserves).
function M.generate_json(fields)
    local temperature = measurement(fields.temperature)
    local utilization = measurement(fields.utilization, 100)
    local fan = measurement(fields.fan_speed)
    local current = measurement(fields.current_clock_speed)
    local maximum = measurement(fields.max_clock_speed)
    local power = measurement(fields.power_usage)
    local limit = measurement(fields.power_limit)
    local thermo = M.map_floor("85:, 65:, 45:, ", temperature or 0)
    local speedo = M.map_floor("90:, 60:󰓅, 30:󰾅, 󰾆", utilization or 0)
    local text_icon = fields.emoji
        and M.map_floor("85:🌋, 65:🔥, 45:☁️, ❄️", temperature or 0) or thermo
    local tooltip = {fields.primary_gpu or "GPU not found"}
    local function add(icon, label, value, unit)
        if value ~= nil then
            tooltip[#tooltip + 1] = icon .. " " .. label .. ": " .. value .. " " .. unit
        end
    end
    add(thermo, "Temperature", temperature, "°C")
    add("", "Fan Speed", fan, "RPM")
    add(speedo, "Utilization", utilization, "%")
    if current then
        add("", "Clock Speed", maximum and (current .. "/" .. maximum) or current, "MHz")
    end
    add("", "Power Usage", power and (limit and (power .. "/" .. limit) or power), "W")
    if #tooltip == 1 then
        tooltip[#tooltip + 1] = "GPU measurements unavailable"
    end

    -- Missing values have an explicit state, not a fabricated temp-0/util-0.
    local classes = {}
    local bucket = temperature and clamp(math.floor(temperature / 5) * 5, 0, 100)
    if bucket then classes[#classes + 1] = "temp-" .. bucket end
    if utilization then classes[#classes + 1] = "util-" .. math.floor(utilization / 10) * 10 end
    if not temperature then classes[#classes + 1] = "unavailable" end
    return json.encode({
        text = temperature and (text_icon .. " " .. math.floor(temperature) .. "°C") or " N/A",
        tooltip = table.concat(tooltip, "\n"),
        class = classes,
        percentage = temperature and clamp(temperature, 0, 100) or nil,
        alt = bucket and tostring(bucket) or "unavailable",
    })
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

--- NVIDIA measurements are scoped to the detected PCI address. Never query
--- the first card implicitly, and never substitute CPU data on failure.
function M.nvidia_query(opts)
    local fields = {primary_gpu = "NVIDIA " .. (opts.nvidia_gpu or "GPU")}
    if not pci_address(opts.nvidia_addr) then
        return fields, false
    end
    local device = (opts.pci_devices_dir or "/sys/bus/pci/devices") .. "/" .. opts.nvidia_addr
    if opts.tired then
        local status = read_first_line(opts.runtime_status_path or (device .. "/power/runtime_status"))
        if status == "suspended" or status == "suspending" then
            return fields, true
        end
    end
    if opts.is_nouveau then
        fields = M.read_gpu_sysfs({addr = opts.nvidia_addr, pci_dir = opts.pci_devices_dir})
        fields.primary_gpu = "NVIDIA " .. (opts.nvidia_gpu or "GPU")
        return fields, false
    end
    local handle = io.popen(
        "timeout 3s " .. shell_quote(opts.nvidia_smi_cmd or "nvidia-smi")
            .. " --id=" .. shell_quote(opts.nvidia_addr)
            .. " --query-gpu=temperature.gpu,utilization.gpu,clocks.current.graphics,"
            .. "clocks.max.graphics,power.draw,power.limit"
            .. " --format=csv,noheader,nounits 2>/dev/null"
    )
    local line = handle and handle:read("*l")
    local success = handle and handle:close()
    if success and line then
        local values = {}
        -- Preserve empty CSV columns so later measurements cannot shift.
        for value in (line .. ","):gmatch("(.-),") do
            values[#values + 1] = value
        end
        if #values == 6 then
            fields.temperature = measurement(values[1])
            fields.utilization = measurement(values[2], 100)
            fields.current_clock_speed = measurement(values[3])
            fields.max_clock_speed = measurement(values[4])
            fields.power_usage = measurement(values[5])
            fields.power_limit = measurement(values[6])
        end
    end
    -- nvidia-smi fan.speed is a target percentage, not measured RPM.
    -- Only expose a real RPM sensor if the selected device provides one.
    fields.fan_speed = M.read_gpu_sysfs({addr = opts.nvidia_addr, pci_dir = opts.pci_devices_dir}).fan_speed
    return fields, false
end

local argparse = require("luautils.argparse")

local VENDOR_STAT_KEY = {nvidia = "nvidia_enable", amd = "amd_enable", intel = "intel_enable"}

--- CLI entry point. Tests can inject print/warn functions, a state suffix,
--- PCI detection/sysfs roots, and the nvidia-smi executable.
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

    local parser = argparse("gpuinfo", "GPU-only information for the waybar custom/gpuinfo module")
    parser:option("--use", "Only call the specified GPU"):argname("GPU")
    parser:option("--stat", "Report whether GPU is enabled (amd, intel, nvidia)"):argname("GPU")
    parser:flag("--toggle", "Toggle available GPU")
    parser:flag("--reset", "Remove & restart all detection")
    parser:flag("--tired", "Do not query nvidia-smi if the GPU is in suspend mode")
    parser:flag("--emoji", "Use emoji instead of glyphs")
    parser:flag("--startup", "Set this GPU at startup (used with --use)")
    local args = parser:parse(argv)

    -- Validated before it becomes part of a filesystem path below: an
    -- unchecked --use value (e.g. "../../../home/user/.config/foo") would
    -- otherwise let a cold start read/write an arbitrary JSON file outside
    -- the runtime dir once concatenated into the state suffix.
    if args.use and not VENDOR_STAT_KEY[args.use] then
        print_fn("Error: Invalid argument for --use. Use amd, intel, or nvidia.")
        return 1
    end

    local suffix = opts.state_suffix_override or (args.startup and "" or (args.use and ("_" .. args.use) or ""))
    local state = M.read_state(suffix)

    -- Gated on "has detection ever run", not on "did it find anything": on
    -- hardware with none of the three recognized vendors (a VM's virtio-gpu,
    -- say) all three enables stay false forever, so the old
    -- `not has_any_vendor` condition re-walked /sys/bus/pci/devices, rewrote
    -- the state file and re-emitted the "Initialized:" warning on every poll.
    if args.reset or not state.detected then
        -- --reset starts from a genuinely empty state, matching the bash
        -- version's `rm -fr` of the state file (its --help still advertises
        -- that): stale tired/emoji flags from an earlier invocation must not
        -- survive. Flags passed on *this* invocation are applied just below.
        if args.reset then
            state = {}
        end
        local detected = M.detect_vendor(opts.detect_vendor_opts)
        state.detected = true
        state.nvidia_enable = detected.nvidia
        state.amd_enable = detected.amd
        state.intel_enable = detected.intel
        state.nvidia_gpu = detected.nvidia_gpu
        state.nvidia_nouveau = detected.nvidia_nouveau
        state.amd_gpu = detected.amd_gpu
        state.intel_gpu = detected.intel_gpu
        state.nvidia_addr = detected.nvidia_addr
        state.amd_addr = detected.amd_addr
        state.intel_addr = detected.intel_addr
        -- The set of vendors --toggle/--use may switch between, recorded once
        -- here because the *_enable keys below get overwritten with the
        -- *selection* on every toggle (see M.toggle's note).
        state.available = {}
        for _, vendor in ipairs(VENDOR_ORDER) do
            if detected[vendor] then
                state.available[#state.available + 1] = vendor
            end
        end
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

    if args.tired then
        state.tired = true
    end
    if args.emoji then
        state.emoji = true
    end

    if args.toggle then
        local next_vendor, err = M.toggle(state, nil)
        if not next_vendor then
            print_fn("Error: " .. err)
            return 1
        end
        M.write_state(suffix, state)
        print_fn("Sensor: " .. next_vendor .. " GPU")
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

    local pci_dir = opts.pci_dir or (opts.detect_vendor_opts or {}).pci_dir
    local fields
    if state.nvidia_enable then
        local suspended
        fields, suspended = M.nvidia_query({
            nvidia_gpu = state.nvidia_gpu,
            is_nouveau = state.nvidia_nouveau,
            nvidia_addr = state.nvidia_addr,
            tired = state.tired,
            nvidia_smi_cmd = opts.nvidia_smi_cmd,
            pci_devices_dir = pci_dir,
        })
        if suspended then
            print_fn(json.encode({text = "󰤂", tooltip = fields.primary_gpu .. " ⏾ Suspended mode"}))
            return 0
        end
    elseif state.amd_enable or state.intel_enable then
        local vendor = state.amd_enable and "amd" or "intel"
        fields = M.read_gpu_sysfs({addr = state[vendor .. "_addr"], pci_dir = pci_dir})
        fields.primary_gpu = (vendor == "amd" and "AMD " or "Intel ") .. (state[vendor .. "_gpu"] or "GPU")
    else
        fields = {primary_gpu = "GPU not found"}
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
