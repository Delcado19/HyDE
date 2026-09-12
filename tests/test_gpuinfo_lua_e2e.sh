#!/usr/bin/env bash
# Exercise actual process exit codes and JSON output, including malformed CLI input.
. "$(dirname -- "$0")/lib/common.sh"
if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
script="$REPO_ROOT/Configs/.local/lib/hyde/gpuinfo.lua"
export XDG_RUNTIME_DIR="$work_dir"
for option in --use --stat; do
    for value in bogus ../../outside "" 'intel;exit 0'; do
        if lua "$script" "$option" "$value" >"$work_dir/out" 2>"$work_dir/err"; then
            fail "accepted invalid $option value: $value"
        fi
    done
    if lua "$script" "$option" >"$work_dir/out" 2>"$work_dir/err"; then
        fail "accepted $option without its required value"
    fi
done
for option in --unknown positional; do
    if lua "$script" "$option" >"$work_dir/out" 2>"$work_dir/err"; then
        fail "accepted invalid argument: $option"
    fi
done
lua "$script" --help >"$work_dir/help" || fail "--help failed"
if grep -q 'GPU/CPU' "$work_dir/help"; then fail "help still advertises CPU data"; fi

# Host-independent no-GPU result: no CPU/battery/sensors may fill the gap.
REPO_ROOT="$REPO_ROOT" lua -e '
package.path = os.getenv("REPO_ROOT") .. "/Configs/.local/lib/hyde/?.lua;" .. package.path
local gpuinfo = require("gpuinfo")
os.exit(gpuinfo.cli_main({"--reset"}, {
    detect_vendor_opts = {pci_dir = "/nonexistent", modules_file = "/nonexistent"},
}))
' >"$work_dir/out" 2>"$work_dir/err" || fail "no-GPU invocation failed"
python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["text"] == " N/A"
assert "GPU not found" in data["tooltip"]
assert "Temperature:" not in data["tooltip"]
assert "Utilization:" not in data["tooltip"]
assert "Power" not in data["tooltip"]
assert "percentage" not in data
' <"$work_dir/out" || fail "no-GPU output fabricated measurements or broke JSON"
finish
