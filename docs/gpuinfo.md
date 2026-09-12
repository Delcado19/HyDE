# GPU information

`hyde-shell gpuinfo` produces one JSON object per poll for Waybar. The
tooltip identifies the selected GPU and shows only available GPU measurements.
It never substitutes CPU temperature, CPU load, CPU clock, a chassis fan, or
battery discharge power. Unsupported readings are omitted, not reported as zero.
A real zero remains valid, including a stopped GPU fan.

## Categories

| Category | Icon | Unit |
| --- | --- | --- |
| GPU name | Device name in the tooltip heading | — |
| Temperature | Shell thermometer levels:     | °C |
| Fan Speed |  | Measured RPM |
| Utilization | Shell load levels: 󰾆 󰾅 󰓅  | % |
| Clock Speed |  | MHz, optionally current/maximum |
| Power Usage |  | W, optionally current/limit |

`--emoji` changes the bar's temperature icon; tooltip category symbols remain
consistent. Without a GPU temperature, the bar shows ` N/A`, uses the
`unavailable` class, and omits `percentage`. Other supported measurements still
appear in the tooltip. A tooltip with no measurements explains their absence.

## Sources and limits

- NVIDIA proprietary driver: `nvidia-smi --id=<PCI address>` for temperature,
  utilization, graphics clocks, power and power limit. Calls time out after
  three seconds. Failed queries and unsupported CSV fields produce no reading.
  Empty CSV columns retain their position. The query never implicitly selects
  the first NVIDIA card. `--tired` avoids querying suspended devices.
- AMD and Nouveau: only hwmon nodes under the selected PCI device, restricted
  to GPU driver names. `temp1_input` supplies temperature, `fan1_input` supplies
  measured RPM, and `freq1_input` supplies the graphics clock. AMD utilization
  comes from that device's `gpu_busy_percent`, when exposed.
- Intel i915: the selected device's DRM `gt_act_freq_mhz` supplies actual GPU
  frequency and `gt_RP0_freq_mhz` supplies maximum frequency. Requested GT
  frequency and CPU cpufreq are not substitutes for actual GPU frequency.
  Drivers without these interfaces may expose fewer or no measurements.
- Generic sysfs power is deliberately omitted: AMD APU `power1_*` can include
  CPU/SoC consumption. No discrete/APU guess based on marketing names is used.
- NVIDIA `fan.speed` is a target percentage, not measured RPM, so it is not
  used for Fan Speed. A measured device-local RPM sensor is required.
- Selection remains one detected device per vendor, with the existing
  `--use`, `--startup`, `--toggle`, `--stat`, and `--reset` interface.
  Missing or invalid PCI addresses produce no measurements.

The previous AMD Python helper is no longer invoked by this widget; its
implicit first-device selection could disagree with the detected GPU.
No sensor permissions are elevated and no new monitoring daemon is installed.

Kernel ABI references:
[AMDGPU monitoring](https://docs.kernel.org/gpu/amdgpu/thermal.html) and
[hwmon units](https://docs.kernel.org/hwmon/sysfs-interface.html).

## Validation

Run `sh tests/run.sh gpuinfo_lua` from the repository root. The cases cover
state, vendor detection and toggling, CLI errors, output, NVIDIA and sysfs.
Fixtures cover absent devices, foreign GPU/CPU sensors, malformed values,
unsupported readings, NaN/infinity, invalid percentages, genuine zero values,
partial/failed CSV output, invalid PCI addresses, and suspended devices.
Removed CPU/battery reader tests are replaced by assertions that those data
sources cannot contaminate GPU output.

Live validation on Intel HD Graphics 620 confirms device name and actual GPU
clock reporting without CPU proxies. AMD/NVIDIA validation uses fixtures;
physical AMD/NVIDIA cards are still required for hardware acceptance.
