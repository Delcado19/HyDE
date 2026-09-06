#!/usr/bin/env bash
# wallpaper/cache.sh commence -w <file> must cache only that one file. It used
# to also scan every configured custom wallpaper directory on top of it,
# re-hashing (and re-processing with ImageMagick/wallbash) the whole
# collection for what should be a single-wallpaper request (#1985).
#
# get_hashmap is stubbed to record the paths it was asked to scan instead of
# actually walking the filesystem -- what matters here is which paths
# wallpaper_cache_commence hands it, not get_hashmap's own find/hash logic
# (that already has no dedicated coverage and is out of scope for this fix).

. "$(dirname -- "$0")/lib/common.sh"

cache_sh="$REPO_ROOT/Configs/.local/lib/hyde/wallpaper/cache.sh"
[ -f "$cache_sh" ] || {
    fail "cache.sh not found at $cache_sh"
    finish
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# A handful of files standing in for a large custom wallpaper collection --
# get_hashmap must never be asked to scan this directory for a -w request.
custom_dir="$work_dir/custom-collection"
mkdir -p "$custom_dir"
for i in 1 2 3; do
    printf 'fake' >"$custom_dir/wall$i.jpg"
done

single_wallpaper="$work_dir/target.jpg"
printf 'fake' >"$single_wallpaper"

theme_dir="$work_dir/theme"
mkdir -p "$theme_dir/wallpapers"
printf 'fake' >"$theme_dir/wallpapers/theme-wall.jpg"

hashmap_calls_file="$work_dir/hashmap_calls"

# shellcheck source=/dev/null
. "$cache_sh"

# Overrides: everything wallpaper_cache_commence calls before get_hashmap.
wallpaper_cache_bootstrap() {
    thmbDir="$work_dir/thumbs"
    dcolDir="$work_dir/dcol"
    cacheDir="$work_dir/cache"
    HYDE_THEME_DIR="$theme_dir"
    scrDir="$work_dir"
    mkdir -p "$thmbDir" "$dcolDir" "$cacheDir"
}
wallpaper_cache_init() { return 0; }
fn_envar_cache() { return 0; }

# Records what wallpaper_cache_commence asked to be scanned, one call per
# line, args space-joined -- real get_hashmap behavior is not under test here.
get_hashmap() {
    printf '%s\n' "$*" >>"$hashmap_calls_file"
    wallHash=()
    wallList=()
}

export WALLPAPER_CUSTOM_PATHS=("$custom_dir")

# -w a single file: must scan only that file, not the custom collection.
: >"$hashmap_calls_file"
unset cacheIn mode wallHash wallList
wallpaper_cache_commence -w "$single_wallpaper" >/dev/null 2>&1
call=$(cat "$hashmap_calls_file")
case $call in
*"$custom_dir"*)
    fail "-w scanned the custom wallpaper collection ($custom_dir) instead of just the target file: $call"
    ;;
esac
case $call in
"$single_wallpaper --no-notify") ;;
*) fail "-w did not scan exactly the target file: got '$call'" ;;
esac

# The old bare 'w <file>' compat form must resolve the same way, not silently
# fall back to caching the whole theme directory from wallpaper_cache_init.
: >"$hashmap_calls_file"
unset cacheIn mode wallHash wallList
wallpaper_cache_commence w "$single_wallpaper" >/dev/null 2>&1
call=$(cat "$hashmap_calls_file")
case $call in
"$single_wallpaper --no-notify") ;;
*) fail "bare 'w <file>' compat form did not resolve to the target file: got '$call'" ;;
esac

# -f (full rebuild) is the opposite requirement: it must still scan the
# custom collection, so the -w fix must not have narrowed this mode too.
: >"$hashmap_calls_file"
unset cacheIn mode wallHash wallList
wallpaper_cache_commence -f >/dev/null 2>&1
call=$(cat "$hashmap_calls_file")
case $call in
*"$custom_dir"*) ;;
*) fail "-f (full rebuild) stopped scanning the custom wallpaper collection: got '$call'" ;;
esac

# getopts allows repeating flags, so a caller can pass -w together with -t/-f
# (whichever HyDE itself does or not, getopts does not reject it). The last
# flag processed has to win for single_wallpaper the same way it already does
# for cacheIn/mode -- otherwise "-w file -f" would keep single_wallpaper=1
# from the earlier -w branch and skip the custom-path scan a real -f needs.
: >"$hashmap_calls_file"
unset cacheIn mode wallHash wallList
wallpaper_cache_commence -w "$single_wallpaper" -f >/dev/null 2>&1
call=$(cat "$hashmap_calls_file")
case $call in
*"$custom_dir"*) ;;
*) fail "-w followed by -f did not fall back to a full scan (single_wallpaper leaked across flags): got '$call'" ;;
esac

# And the reverse order: -f followed by -w must end up in single-file mode,
# not have -f's custom-path scan stick around.
: >"$hashmap_calls_file"
unset cacheIn mode wallHash wallList
wallpaper_cache_commence -f -w "$single_wallpaper" >/dev/null 2>&1
call=$(cat "$hashmap_calls_file")
case $call in
*"$custom_dir"*)
    fail "-f followed by -w still scanned the custom wallpaper collection: got '$call'"
    ;;
esac

finish
