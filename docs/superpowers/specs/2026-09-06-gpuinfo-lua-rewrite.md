# gpuinfo.sh → gpuinfo.lua rewrite

## Why

Maintainer request on PR #2058 (https://github.com/HyDE-Project/HyDE/pull/2058#issuecomment-…):
`gpuinfo.sh` is bash's practical ceiling for this project — too many subprocess
calls, fragile `grep|awk|cut` text parsing, hard to keep maintainable. Batterynotify
and alt-tab already made the same jump (`batterynotify.lua`, `altab.lua`); this
does the same for the GPU/CPU waybar module.

## Explicit non-goal: this is not "zero subprocess calls"

Checked prior art before designing this (AwesomeWM's `lain`/`vicious` widgets,
both mature, years-old Lua libraries for exactly this problem) — both still
shell out (`find`, `sensors`) rather than reimplement lm-sensors' own chip/label
database in Lua. NVIDIA temperatures are only available via `nvidia-smi`
regardless of language; there is no sysfs/hwmon path for the proprietary driver.

The goal is **fewer, more targeted calls**, and Lua string/JSON handling instead
of shell pipelines — not eliminating `sensors`/`nvidia-smi`/`lspci` outright.

## What changes vs. the current bash script

| Concern | Bash today | Lua rewrite |
|---|---|---|
| GPU vendor detection | 3 separate full-bus `lspci -nn \| grep` scans per poll | one `/sys/bus/pci/devices/*/class`+`vendor` sysfs scan (pure Lua) to find the display controller + vendor; **one** targeted `lspci -nn -s <addr>` call only for the human-readable name string (PCI ID database parsing is out of scope — reuse the tool built for it) |
| nouveau detection | `lsmod \| grep nouveau` | read `/proc/modules` directly (pure Lua) |
| `nvidia-smi` presence check | `command -v nvidia-smi` | PATH search over `os.getenv("PATH")` with `io.open`/`lfs.attributes` (pure Lua) |
| CPU/GPU temperature + fan speed | `sensors` plain text piped through `grep -m1 -E "(edge\|Package id.*\|Tctl\|Tdie)"` / `grep -m1 -E "fan[1-9]"` \| `awk` | **one** `sensors -j` call, parsed with the existing `luautils.json` decoder (mirrors `cpuinfo.sh`'s already-proven `sensors -j` + JSON-parser pattern, Lua instead of Perl) |
| Battery discharge (`power_now`/`current_now`+`voltage_now`) | `awk` arithmetic over `cat`'d sysfs values | pure Lua (`tonumber`, no subprocess) |
| CPU utilization (`/proc/stat`) | `awk` field sums, `sed -i` in-place state update | pure Lua string parsing + JSON state file rewrite |
| CPU clock speed (cpufreq) | `awk` averaging over a glob, `awk` on a single file | pure Lua (`lfs.dir` + `io.open`, guarded existence checks — carries forward the lessons from #2028 without needing that fix ported) |
| AMD branch | `amdgpu.py` (kept) → `jq` + `sed` | `amdgpu.py` (kept, untouched) → `luautils.json.decode` + Lua string patterns |
| NVIDIA branch | `nvidia-smi --query-gpu=... --format=csv` → `IFS=',' read -ra` | same `nvidia-smi` call (unavoidable), parsed with Lua `gmatch` |
| State persistence | hand-rolled `KEY="value"` shell file, incremental `echo >>`/`sed -i` edits, `source`d back in | one JSON object (via `luautils.json`), read-mutate-write — no in-place text editing |
| State file location | `/tmp/hyde-$UID-gpuinfo` | `${XDG_RUNTIME_DIR:-/tmp}/hyde-$UID-gpuinfo` (matches `cpuinfo.sh`'s own, more-correct convention) |
| CLI parsing | hand-rolled `case "$1" in` | `luautils.argparse` (already used by `altab.lua`, `config.lua`, `shaders.lua`) |

## Explicit behavior change: sensor-match precedence

The bash regex `grep -m1 -E "(edge|Package id.*|Tctl|Tdie)"` matches whichever
label happens to come first in `sensors`' own (arbitrary, driver/board-dependent)
plaintext ordering. `sensors -j`'s JSON object has no defined key order in Lua
(`pairs()` iteration order over decoded JSON is unspecified), so "first in the
dump" cannot be preserved as-is without extra bookkeeping that adds real
complexity for an already-accidental property.

**Decision:** replace it with an explicit priority list, checked in this order:
`edge`/`junction` (amdgpu GPU) → `Tctl`/`Tdie` (AMD CPU) → `Package id N` (Intel
CPU package). This is *more* predictable than the old behavior, not less — GPU
temperature (if present) always wins over a CPU proxy reading, which is what a
module called "gpuinfo" should prefer anyway. The existing regression test for
the ambiguous case (`tests/test_gpuinfo.sh`, the "Tctl and edge both present"
case) asserted the old accidental order; its ported equivalent must assert the
new explicit one instead (`edge` wins) and say why in a comment.

## Files

- Create: `Configs/.local/lib/hyde/gpuinfo.lua` — the full rewrite, one file
  (matches this repo's own convention: `altab.lua`, `batterynotify.lua`,
  `dconf.lua` are each a single file despite comparable complexity).
- Create: `tests/test_gpuinfo_lua.sh` + `tests/lua/gpuinfo_lua_harness_helpers.lua`
  (a small stub-injection helper shared by the harness's sub-scenarios) — full
  port of every regression case in the current `tests/test_gpuinfo.sh`.
- Modify: `Configs/.local/share/waybar/modules/custom-gpuinfo#nvidia.jsonc` —
  drops the hardcoded `.sh` (so `hyde-shell`'s own "Lua resolved before shell"
  rule picks the new file the same way the other 3 gpuinfo modules already do
  via the bare `hyde-shell gpuinfo` invocation) and drops the inconsistent
  `app -t scope` wrapper the other 3 modules don't use.
- Delete (final task, only after the Lua version's full test suite is green):
  `Configs/.local/lib/hyde/gpuinfo.sh`, `tests/test_gpuinfo.sh`.

## Out of scope

- Rewriting `amdgpu.py` (Python, already working, not bash).
- Any change to `cpuinfo.sh` (separate script; same JSON-parsing pattern
  already exists there in Perl — a future rewrite is a separate spec if wanted).
- PR #2056 (the open cpufreq bash fix): the Lua clock-speed reader is written
  fresh with guarded existence checks from the start, so it doesn't need that
  fix ported — #2056 becomes moot once this lands and should be closed by
  whoever's handling it, noting the file it patches no longer exists.
- Full PCI ID name database parsing in Lua (see table above — one targeted
  `lspci` call stays for the human-readable name only).
