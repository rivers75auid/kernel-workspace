#!/usr/bin/env python3
"""
Remove upstream cirno-pin fs/exec.c hack that blocks `/system/bin/lmkd --reinit`.

With CONFIG_PSI=y and CONFIG_ANDROID_SIMPLE_LMK disabled, Android's userspace lmkd
actively manages memory pressure. Returning -ENOENT on `/system/bin/lmkd --reinit`
prevents lmkd.rc (`property:lmkd.reinit=1` / `sys.boot_completed=1`) and root/ROM
tuners from reloading `ro.lmk.*` / `persist.device_config.lmkd_native.*` properties,
leaving lmkd stuck on aggressive device build.prop defaults (e.g., 50ms PSI stall).
"""

import os
import re
import sys

TARGET_REL = os.path.join("fs", "exec.c")

HELPER_PATTERN = re.compile(
    r"\nstatic\s+noinline\s+bool\s+is_lmkd_reinit\s*\(\s*struct\s+user_arg_ptr\s*\*argv\s*\)\s*"
    r"\{.*?return\s+!strcmp\(buf,\s*\"--reinit\"\);\n\}\n",
    re.DOTALL,
)

HOOK_PATTERN = re.compile(
    r"\n[ \t]*(?://[^\n]*is_lmkd_reinit[^\n]*|//[^\n]*disable lmkd reloading props[^\n]*)\n"
    r"[ \t]*if\s*\(\s*unlikely\s*\(\s*strcmp\s*\(\s*bprm\.filename\s*,\s*\"/system/bin/lmkd\"\s*\)\s*==\s*0\s*\)\s*\)\s*\{\n"
    r"[ \t]*if\s*\(\s*is_lmkd_reinit\s*\(\s*&argv\s*\)\s*\)\s*\{.*?\n[ \t]*\}\n[ \t]*\}\n",
    re.DOTALL,
)


def patch_file(exec_c_path: str) -> bool:
    if not os.path.isfile(exec_c_path):
        print(f"[-] ERROR: {exec_c_path} not found!", file=sys.stderr)
        sys.exit(1)

    with open(exec_c_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    if "is_lmkd_reinit" not in content:
        print(f"[i] {exec_c_path} already clean (no is_lmkd_reinit hack present).")
        return False

    new_content, hook_count = HOOK_PATTERN.subn("", content, count=1)
    if hook_count != 1:
        print(
            f"[-] ERROR: Expected 1 is_lmkd_reinit execve hook in {exec_c_path}, matched {hook_count}.",
            file=sys.stderr,
        )
        sys.exit(1)

    new_content, helper_count = HELPER_PATTERN.subn("", new_content, count=1)
    if helper_count != 1:
        print(
            f"[-] ERROR: Expected 1 is_lmkd_reinit helper in {exec_c_path}, matched {helper_count}.",
            file=sys.stderr,
        )
        sys.exit(1)

    if "is_lmkd_reinit" in new_content:
        print(f"[-] ERROR: Leftover reference to is_lmkd_reinit in {exec_c_path}!", file=sys.stderr)
        sys.exit(1)

    with open(exec_c_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_content)

    print(f"[+] Removed upstream is_lmkd_reinit block from {exec_c_path}; `/system/bin/lmkd --reinit` restored.")
    return True


def main() -> None:
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.getcwd(), TARGET_REL)
    patch_file(target)


if __name__ == "__main__":
    main()
