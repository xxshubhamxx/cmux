#!/usr/bin/env python3
"""
Regression test: the generated OpenCode session plugin is valid ESM.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def main() -> int:
    bun = shutil.which("bun")
    if bun is None:
        print("SKIP: bun not found")
        return 0

    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-opencode-plugin-") as td:
        root = Path(td)
        config_dir = root / "opencode"
        env = os.environ.copy()
        env["OPENCODE_CONFIG_DIR"] = str(config_dir)

        install = subprocess.run(
            [cli_path, "opencode", "install-hooks", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install.returncode != 0:
            print("FAIL: opencode plugin install failed")
            print(f"exit={install.returncode}")
            print(f"stdout={install.stdout.strip()}")
            print(f"stderr={install.stderr.strip()}")
            return 1

        plugin_path = config_dir / "plugins" / "cmux-session.js"
        if not plugin_path.exists():
            print(f"FAIL: expected plugin at {plugin_path}")
            return 1

        check_env = env.copy()
        check_env["CMUX_TEST_OPENCODE_PLUGIN_PATH"] = str(plugin_path)
        check_source = """
const pluginPath = process.env.CMUX_TEST_OPENCODE_PLUGIN_PATH;
const mod = await import(pluginPath);
if (typeof mod.CMUXSessionRestore !== "function") {
  throw new Error("missing CMUXSessionRestore export");
}
const hooks = await mod.CMUXSessionRestore({ directory: process.cwd() });
if (!hooks || typeof hooks.event !== "function") {
  throw new Error("missing event hook");
}
"""
        check = subprocess.run(
            [bun, "--eval", check_source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=check_env,
            timeout=20,
        )
        if check.returncode != 0:
            print("FAIL: generated OpenCode plugin is not importable ESM")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

    print("PASS: generated OpenCode plugin installs and imports as ESM")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
