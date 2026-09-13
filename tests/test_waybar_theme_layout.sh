#!/usr/bin/env sh
# Exercise theme lookup, layout selection and CSS generation without a desktop.
set -eu
REPO_ROOT=${REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
export REPO_ROOT
python3 - <<'PY'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

root = Path(os.environ["REPO_ROOT"])
lib = root / "Configs/.local/lib/hyde"
sys.path.insert(0, str(lib))

with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp)
    for kind in ("CONFIG", "STATE", "CACHE", "RUNTIME", "DATA"):
        os.environ[f"XDG_{kind}_HOME" if kind != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(base / kind)
    config = base / "CONFIG/waybar"
    config.mkdir(parents=True)
    themes = base / "CONFIG/hyde/themes"
    theme = themes / "Mac OS/hypr.theme"
    theme.parent.mkdir(parents=True)
    theme.write_text("$WAYBAR_LAYOUT = macos\n")
    layouts = config / "layouts"
    styles = config / "styles"
    layouts.mkdir()
    styles.mkdir()
    for name in ("default", "macos", "other"):
        (layouts / f"{name}.jsonc").write_text('{"name": "' + name + '"}\n')
        (styles / f"{name}.css").write_text(f"/* {name} */\n")
    (styles / "custom.css").write_text("/* separately selected style */\n")
    (config / "theme.css").touch()

    spec = importlib.util.spec_from_file_location("waybar", lib / "waybar.py")
    waybar = importlib.util.module_from_spec(spec)
    with patch("shutil.which", return_value="/usr/bin/waybar"):
        spec.loader.exec_module(waybar)

    def hyq(args, **kwargs):
        # A quoted argv path would not exist: regression for "Mac OS".
        assert args[0] == "hyq", args
        content = Path(args[1]).read_text()
        value = content.partition("=")[2].strip() if args[-1] == "$WAYBAR_LAYOUT" else ""
        return subprocess.CompletedProcess(args, 0, value, "")

    def select(name):
        waybar.set_state_value("WAYBAR_LAYOUT_PATH", layouts / f"{name}.jsonc")
        waybar.set_state_value("WAYBAR_LAYOUT_NAME", name)
        waybar.set_state_value("WAYBAR_STYLE_PATH", styles / f"{name}.css")
        (config / "config.jsonc").write_text((layouts / f"{name}.jsonc").read_text())

    # Stub desktop effects, retaining actual state, layout lookup and CSS writes.
    with patch.object(waybar, "source_env_file"), \
         patch.object(waybar, "update_icon_size"), \
         patch.object(waybar, "update_border_radius"), \
         patch.object(waybar, "update_global_css"), \
         patch.object(waybar, "restart_waybar"), \
         patch.object(waybar.notify, "send"), \
         patch.object(waybar.subprocess, "run", side_effect=hyq), \
         patch.object(sys, "argv", ["waybar.py", "--update"]):
        select("default")
        waybar.set_state_value("WAYBAR_STYLE_PATH", styles / "custom.css")
        waybar.set_state_value("HYDE_THEME", "Mac OS")
        waybar.main()
        assert waybar.get_state_value("WAYBAR_LAYOUT_NAME") == "macos"
        assert (config / "config.jsonc").read_text() == (layouts / "macos.jsonc").read_text()
        assert f'@import "{styles / "macos.css"}";' in (config / "style.css").read_text()
        waybar.main()  # Reapplying the theme must keep the same pair.
        assert waybar.get_state_value("WAYBAR_LAYOUT_NAME") == "macos"

        # A second theme preset must not overwrite the original saved pair.
        theme.write_text("$WAYBAR_LAYOUT = other\n")
        waybar.main()
        assert waybar.get_state_value("WAYBAR_LAYOUT_NAME") == "other"
        theme.write_text("# No preferred layout\n")
        waybar.main()
        assert waybar.get_state_value("WAYBAR_LAYOUT_NAME") == "default"
        assert (config / "config.jsonc").read_text() == (layouts / "default.jsonc").read_text()
        assert f'@import "{styles / "custom.css"}";' in (config / "style.css").read_text()
        assert not waybar.get_state_value("WAYBAR_PRE_THEME_LAYOUT")
        waybar.main()
        assert f'@import "{styles / "custom.css"}";' in (config / "style.css").read_text()

        # A new visit saves the user's new selection; unavailable presets leave it alone.
        select("other")
        theme.write_text("$WAYBAR_LAYOUT = missing\n")
        waybar.main()
        assert not waybar.get_state_value("WAYBAR_PRE_THEME_LAYOUT")
        assert waybar.get_state_value("WAYBAR_LAYOUT_NAME") == "other"
        theme.write_text("$WAYBAR_LAYOUT = macos\n")
        waybar.main()
        theme.write_text("# No preferred layout\n")
        waybar.main()
        assert waybar.get_state_value("WAYBAR_LAYOUT_NAME") == "other"
        assert f'@import "{styles / "other.css"}";' in (config / "style.css").read_text()

print("Theme round trips, custom CSS, repeated updates, preset chains and missing presets passed.")
PY
