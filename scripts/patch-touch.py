import os
import sys

def patch_nt36xxx():
    kernel_root = os.getcwd()
    dirs = [
        os.path.join(kernel_root, "drivers/input/touchscreen/nt36xxx"),
        os.path.join(kernel_root, "drivers/input/touchscreen/nt36525b_spi")
    ]

    for d in dirs:
        if not os.path.exists(d):
            continue

        # 1. Enable ESD Protect & Auto-Recovery in header
        h_file = os.path.join(d, "nt36xxx.h")
        if os.path.exists(h_file):
            with open(h_file, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
            if "#define NVT_TOUCH_ESD_PROTECT 0" in content:
                content = content.replace("#define NVT_TOUCH_ESD_PROTECT 0", "#define NVT_TOUCH_ESD_PROTECT 1")
                with open(h_file, "w", encoding="utf-8", newline="\n") as f:
                    f.write(content)
                print(f"[+] Enabled NVT_TOUCH_ESD_PROTECT in {h_file}")

        # 2. Filter zero-area / zero-pressure phantom ghost touches in C source
        c_file = os.path.join(d, "nt36xxx.c")
        if os.path.exists(c_file):
            with open(c_file, "r", encoding="utf-8", errors="ignore") as f:
                c_content = f.read()

            target = "input_w = (uint32_t)(point_data[position + 4]);"
            replacement = (
                "/* Filter electrical noise & bezel stray capacitance */\n"
                "\t\t\tif (point_data[position + 4] == 0 && point_data[position + 5] == 0)\n"
                "\t\t\t\tcontinue;\n"
                "\t\t\tinput_w = (uint32_t)(point_data[position + 4]);"
            )

            if target in c_content and "Filter electrical noise" not in c_content:
                c_content = c_content.replace(target, replacement, 1)
                with open(c_file, "w", encoding="utf-8", newline="\n") as f:
                    f.write(c_content)
                print(f"[+] Injected zero-width/zero-pressure ghost touch filter in {c_file}")

def patch_lct_gesture():
    kernel_root = os.getcwd()
    f_path = os.path.join(kernel_root, "drivers/input/touchscreen/lct_tp_gesture.c")
    if not os.path.exists(f_path):
        return

    with open(f_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    # 1. Enable D2TW gesture by default at boot
    target_flag = "lct_tp_p->enable_tp_gesture_flag = false;"
    repl_flag = "lct_tp_p->enable_tp_gesture_flag = true; /* D2TW enabled by default */"
    if target_flag in content:
        content = content.replace(target_flag, repl_flag, 1)
        print("[+] Set default D2TW gesture status to TRUE in lct_tp_gesture.c")

    # 2. Grant 0666 read-write permission to /proc/tp_gesture so AOSP services can toggle it
    target_perm = 'proc_create_data(TP_GESTURE_NAME, 0444, NULL, &lct_proc_tp_gesture_fops, NULL);'
    repl_perm = 'proc_create_data(TP_GESTURE_NAME, 0666, NULL, &lct_proc_tp_gesture_fops, NULL);'
    if target_perm in content:
        content = content.replace(target_perm, repl_perm, 1)
        print("[+] Fixed /proc/tp_gesture permission from 0444 to 0666 in lct_tp_gesture.c")

    with open(f_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)

def patch_focaltech():
    kernel_root = os.getcwd()
    dirs = [
        os.path.join(kernel_root, "drivers/input/touchscreen/ft8006s_spi"),
        os.path.join(kernel_root, "drivers/input/touchscreen/focaltech_touch"),
        os.path.join(kernel_root, "drivers/input/touchscreen/ft3418_i2c")
    ]

    for d in dirs:
        if not os.path.exists(d):
            continue

        # 1. Enable FocalTech gesture in config header
        cfg_h = os.path.join(d, "focaltech_config.h")
        if os.path.exists(cfg_h):
            with open(cfg_h, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
            if "#define FTS_GESTURE_EN                          0" in content:
                content = content.replace(
                    "#define FTS_GESTURE_EN                          0",
                    "#define FTS_GESTURE_EN                          1"
                )
                with open(cfg_h, "w", encoding="utf-8", newline="\n") as f:
                    f.write(content)
                print(f"[+] Enabled FTS_GESTURE_EN in {cfg_h}")

        # 2. Fix Double-Tap event: change KEY_GESTURE_U (letter U) to KEY_WAKEUP (wake screen)
        gest_c = os.path.join(d, "focaltech_gesture.c")
        if os.path.exists(gest_c):
            with open(gest_c, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()

            target_key = "case GESTURE_DOUBLECLICK:\n        gesture = KEY_GESTURE_U;"
            repl_key = "case GESTURE_DOUBLECLICK:\n        gesture = KEY_WAKEUP; /* Wake screen instead of letter U */"

            target_key_alt = "case GESTURE_DOUBLECLICK:\n\t\tgesture = KEY_POWER;"

            if target_key in content:
                content = content.replace(target_key, repl_key, 1)
                with open(gest_c, "w", encoding="utf-8", newline="\n") as f:
                    f.write(content)
                print(f"[+] Fixed FocalTech GESTURE_DOUBLECLICK -> KEY_WAKEUP in {gest_c}")
            elif "KEY_GESTURE_U" in content:
                content = content.replace("gesture = KEY_GESTURE_U;", "gesture = KEY_WAKEUP;", 1)
                with open(gest_c, "w", encoding="utf-8", newline="\n") as f:
                    f.write(content)
                print(f"[+] Replaced KEY_GESTURE_U with KEY_WAKEUP in {gest_c}")

if __name__ == "__main__":
    patch_nt36xxx()
    patch_lct_gesture()
    patch_focaltech()
