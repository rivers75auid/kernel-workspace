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

        # 2. Patch C source: ghost touch filter, KEY_POWER for D2TW, /sys/touchpanel/double_tap hook
        c_file = os.path.join(d, "nt36xxx.c")
        if os.path.exists(c_file):
            with open(c_file, "r", encoding="utf-8", errors="ignore") as f:
                c_content = f.read()

            # Include tp_common.h
            if "#include <linux/input/tp_common.h>" not in c_content:
                target_h = "#include <linux/pm_runtime.h>"
                repl_h = "#include <linux/pm_runtime.h>\n#include <linux/input/tp_common.h>"
                c_content = c_content.replace(target_h, repl_h, 1)
                print(f"[+] Included linux/input/tp_common.h in {c_file}")

            # Filter electrical noise & bezel stray capacitance
            target_filter = "input_w = (uint32_t)(point_data[position + 4]);"
            repl_filter = (
                "/* Filter electrical noise & bezel stray capacitance */\n"
                "\t\t\tif (point_data[position + 4] == 0 && point_data[position + 5] == 0)\n"
                "\t\t\t\tcontinue;\n"
                "\t\t\tinput_w = (uint32_t)(point_data[position + 4]);"
            )
            if target_filter in c_content and "Filter electrical noise" not in c_content:
                c_content = c_content.replace(target_filter, repl_filter, 1)
                print(f"[+] Injected ghost touch filter in {c_file}")

            # Map GESTURE_DOUBLE_CLICK to KEY_POWER so Android PhoneWindowManager turns on display
            target_key = "KEY_WAKEUP,  //GESTURE_DOUBLE_CLICK"
            repl_key = "KEY_POWER,   //GESTURE_DOUBLE_CLICK (Double Tap To Wake via KEY_POWER)"
            if target_key in c_content:
                c_content = c_content.replace(target_key, repl_key, 1)
                print(f"[+] Mapped GESTURE_DOUBLE_CLICK to KEY_POWER in {c_file}")

            # Define /sys/touchpanel/double_tap ops right after forward declaration at line 107
            target_ops = "static int lct_nvt_tp_gesture_callback(bool flag);"
            repl_ops = (
                "static int lct_nvt_tp_gesture_callback(bool flag);\n\n"
                "static ssize_t nvt_double_tap_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf) {\n"
                '\treturn sprintf(buf, "%d\\n", ts ? ts->is_gesture_mode : 0);\n'
                "}\n"
                "static ssize_t nvt_double_tap_store(struct kobject *kobj, struct kobj_attribute *attr, const char *buf, size_t count) {\n"
                "\tunsigned int input = 0;\n"
                '\tif (sscanf(buf, "%u", &input) == 1)\n'
                "\t\tlct_nvt_tp_gesture_callback(input > 0);\n"
                "\treturn count;\n"
                "}\n"
                "static struct tp_common_ops nvt_double_tap_ops = {\n"
                "\t.show = nvt_double_tap_show,\n"
                "\t.store = nvt_double_tap_store,\n"
                "};"
            )
            if target_ops in c_content and "nvt_double_tap_ops" not in c_content:
                c_content = c_content.replace(target_ops, repl_ops, 1)
                print(f"[+] Created nvt_double_tap_ops in {c_file}")

            # Register /sys/touchpanel/double_tap in probe
            target_call = "ret = init_lct_tp_gesture(lct_nvt_tp_gesture_callback);"
            repl_call = (
                "ret = init_lct_tp_gesture(lct_nvt_tp_gesture_callback);\n"
                "\ttp_common_set_double_tap_ops(&nvt_double_tap_ops);"
            )
            if target_call in c_content and "tp_common_set_double_tap_ops" not in c_content:
                c_content = c_content.replace(target_call, repl_call, 1)
                print(f"[+] Registered tp_common_set_double_tap_ops in probe in {c_file}")

            # Initialize ts->is_gesture_mode = true in probe
            target_init = 'ts->stylus_resol_double = of_property_read_bool(np, "novatek,stylus-resol-double");'
            repl_init = (
                'ts->stylus_resol_double = of_property_read_bool(np, "novatek,stylus-resol-double");\n'
                '\tts->is_gesture_mode = true; /* Enable D2TW gesture mode by default */'
            )
            if target_init in c_content and "is_gesture_mode = true" not in c_content:
                c_content = c_content.replace(target_init, repl_init, 1)
                print(f"[+] Enabled ts->is_gesture_mode by default in {c_file}")

            # Allow gesture callback to arm immediately without waiting for screen cycle
            target_delay = (
                "\tif (!bTouchIsAwake) {\n"
                "\t\tts->delay_gesture = true;\n"
                '\t\tNVT_LOG("The gesture mode will be %s the next time you wakes up.\\n", flag?"enabled":"disbaled");\n'
                "\t\treturn 0;\n"
                "\t}"
            )
            if target_delay in c_content:
                c_content = c_content.replace(target_delay, "\t/* Arm gesture mode immediately */", 1)
                print(f"[+] Removed bTouchIsAwake delay in gesture callback in {c_file}")

            with open(c_file, "w", encoding="utf-8", newline="\n") as f:
                f.write(c_content)

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

        # 2. Fix Double-Tap event: change KEY_GESTURE_U (letter U) to KEY_POWER (wake screen)
        gest_c = os.path.join(d, "focaltech_gesture.c")
        if os.path.exists(gest_c):
            with open(gest_c, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()

            # Include tp_common.h
            if "#include <linux/input/tp_common.h>" not in content:
                content = "#include <linux/input/tp_common.h>\n" + content
                print(f"[+] Included linux/input/tp_common.h in {gest_c}")

            target_key = "case GESTURE_DOUBLECLICK:\n        gesture = KEY_GESTURE_U;"
            repl_key = "case GESTURE_DOUBLECLICK:\n        gesture = KEY_POWER; /* Wake screen via KEY_POWER */"
            if target_key in content:
                content = content.replace(target_key, repl_key, 1)
                print(f"[+] Fixed FocalTech GESTURE_DOUBLECLICK -> KEY_POWER in {gest_c}")
            elif "KEY_GESTURE_U" in content:
                content = content.replace("gesture = KEY_GESTURE_U;", "gesture = KEY_POWER;", 1)
                print(f"[+] Replaced KEY_GESTURE_U with KEY_POWER in {gest_c}")

            # Define FocalTech /sys/touchpanel/double_tap ops BEFORE fts_gesture_init
            if "fts_double_tap_ops" not in content:
                target_init = "int fts_gesture_init(struct fts_ts_data *ts_data)"
                ops_code = (
                    "static ssize_t fts_double_tap_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf) {\n"
                    '\treturn sprintf(buf, "%d\\n", fts_data ? fts_data->gesture_mode : 0);\n'
                    "}\n"
                    "static ssize_t fts_double_tap_store(struct kobject *kobj, struct kobj_attribute *attr, const char *buf, size_t count) {\n"
                    "\tunsigned int input = 0;\n"
                    '\tif (sscanf(buf, "%u", &input) == 1)\n'
                    "\t\tlct_fts_tp_gesture_callback(input > 0);\n"
                    "\treturn count;\n"
                    "}\n"
                    "static struct tp_common_ops fts_double_tap_ops = {\n"
                    "\t.show = fts_double_tap_show,\n"
                    "\t.store = fts_double_tap_store,\n"
                    "};\n\n"
                    "int fts_gesture_init(struct fts_ts_data *ts_data)"
                )
                if target_init in content:
                    content = content.replace(target_init, ops_code, 1)
                    print(f"[+] Defined fts_double_tap_ops before fts_gesture_init in {gest_c}")

            # Hook in fts_gesture_init
            target_sysfs = "fts_create_gesture_sysfs(ts_data->dev);"
            repl_sysfs = "fts_create_gesture_sysfs(ts_data->dev);\n    tp_common_set_double_tap_ops(&fts_double_tap_ops);"
            if target_sysfs in content and "tp_common_set_double_tap_ops" not in content:
                content = content.replace(target_sysfs, repl_sysfs, 1)
                print(f"[+] Registered FocalTech tp_common_set_double_tap_ops in {gest_c}")

            with open(gest_c, "w", encoding="utf-8", newline="\n") as f:
                f.write(content)

if __name__ == "__main__":
    patch_nt36xxx()
    patch_lct_gesture()
    patch_focaltech()
