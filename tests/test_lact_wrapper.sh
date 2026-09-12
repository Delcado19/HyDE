#!/usr/bin/env bash
# The LACT Waybar wrapper must keep malformed or out-of-range daemon data on
# one valid JSON line so Waybar stays alive.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

fixture=$(mktemp -d)
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT HUP INT TERM

cat >"$fixture/lact" <<'EOF'
#!/usr/bin/env sh
case "${1:-}" in
    valid) printf '%s\n' '{"primary_gpu":"Test GPU","temperature":-5,"utilization":150,"current_clock_speed":300,"max_clock_speed":900,"power_usage":"[N/A]","power_limit":50}' ;;
    invalid) printf '%s\n' 'not json' ;;
    fail) exit 1 ;;
esac
EOF
chmod +x "$fixture/lact"

wrapper="$REPO_ROOT/Configs/.local/lib/hyde/lact.lua"

check_output() {
    local mode=$1 expected=$2
    local output
    output=$(HYDE_LACT_GPUINFO="$fixture/lact" lua "$wrapper" "$mode") || {
        fail "LACT wrapper exited non-zero for $mode"
        return
    }
python3 - "$output" "$expected" <<'PY' || fail "unexpected LACT wrapper output for $mode"
import json
import sys

data = json.loads(sys.argv[1])
expected = sys.argv[2]
assert expected in data["tooltip"], data
assert isinstance(data["text"], str), data
if "-5°C" in expected:
    assert data["percentage"] == 0, data
    assert "util-100" in data["class"], data
PY
}

check_output valid "Temperature: -5°C"
check_output invalid "Temperature: N/A"
check_output fail "Temperature: N/A"

finish
