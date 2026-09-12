local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = root .. "../../Configs/.local/lib/hyde/?.lua;" .. package.path
local gpuinfo = require("gpuinfo")
local json = require("luautils.json")
local function render(fields) return json.decode(gpuinfo.generate_json(fields)) end
local empty = render({primary_gpu = "GPU"})
assert(empty.text == " N/A" and empty.percentage == nil)
assert(empty.alt == "unavailable" and empty.class[1] == "unavailable")
assert(not empty.tooltip:find("°C") and not empty.tooltip:find("Utilization:"))
local full = render({
    primary_gpu = "NVIDIA GPU", temperature = 62, fan_speed = 1400,
    utilization = 45, current_clock_speed = 1800, max_clock_speed = 3600,
    power_usage = 120, power_limit = 200, power_discharge = 15.5,
})
for _, line in ipairs({
    " Temperature: 62 °C", " Fan Speed: 1400 RPM",
    "󰾅 Utilization: 45 %", " Clock Speed: 1800/3600 MHz",
    " Power Usage: 120/200 W",
}) do
    assert(full.tooltip:find(line, 1, true), "missing category/icon: " .. line)
end
assert(not full.tooltip:find("Discharge"))
assert(full.percentage == 62 and full.class[1] == "temp-60" and full.class[2] == "util-40")
for _, invalid in ipairs({"", "[N/A]", "NaN", "inf", "1e999", "12 W", {}, true, -1, math.huge, 0/0}) do
    local item = render({
        temperature = invalid, utilization = invalid, fan_speed = invalid,
        current_clock_speed = invalid, power_usage = invalid,
    })
    assert(item.text:find("N/A") and not item.tooltip:find("Speed:"))
    assert(not item.tooltip:find("Usage:") and item.percentage == nil)
end
assert(not render({utilization = 101}).tooltip:find("Utilization:"))
local zero = render({temperature = 0, utilization = 0, fan_speed = 0, power_usage = 0})
assert(zero.percentage == 0 and zero.tooltip:find("0 RPM") and zero.tooltip:find("0 W"))
local partial = render({current_clock_speed = 350, power_usage = 10.5})
assert(partial.tooltip:find("350 MHz") and partial.tooltip:find("10.5 W"))
assert(not render({max_clock_speed = 900, power_limit = 200}).tooltip:find("Speed:"))
local hot = render({temperature = "95", utilization = "95"})
assert(hot.text == " 95°C" and hot.tooltip:find(" Utilization", 1, true))
local emoji = render({temperature = 95, emoji = true})
assert(emoji.text:find("🌋", 1, true) and emoji.tooltip:find(" Temperature", 1, true))
local escaped = render({primary_gpu = '<GPU> "test"\nnext'})
assert(escaped.tooltip:find('<GPU> "test"', 1, true))
print("GPU output validation and category-icon checks passed")
