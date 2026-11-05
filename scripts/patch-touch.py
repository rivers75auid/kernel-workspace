import os
import sys

def patch_nt36xxx():
    kernel_root = os.getcwd()
    d = os.path.join(kernel_root, "drivers/input/touchscreen/nt36525b_spi")
    if not os.path.exists(d):
        return

    # Add /sys/touchpanel/double_tap sysfs node for AOSP ROMs without forcing KEY_POWER or ESD loop
    c_file = os.path.join(d, "nt36xxx.c")
    if os.path.exists(c_file):
        with open(c_file, "r", encoding="utf-8", errors="ignore") as f:
            c_content = f.read()

        # Include tp_common.h
        if "#include <linux/input/tp_common.h>" not in c_content:
            target_h = "#include <linux/pm_runtime.h>"
            repl_h = "#include <linux/pm_runtime.h>\n#include <linux/input/tp_common.h>"
            c_content = c_content.replace(target_h, repl_h, 1)

        # Define /sys/touchpanel/double_tap ops
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

        # Register /sys/touchpanel/double_tap in probe
        target_call = "ret = init_lct_tp_gesture(lct_nvt_tp_gesture_callback);"
        repl_call = (
            "ret = init_lct_tp_gesture(lct_nvt_tp_gesture_callback);\n"
            "\ttp_common_set_double_tap_ops(&nvt_double_tap_ops);"
        )
        if target_call in c_content and "tp_common_set_double_tap_ops" not in c_content:
            c_content = c_content.replace(target_call, repl_call, 1)

        with open(c_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(c_content)
        print("[+] Configured clean Novatek SPI touch without ESD reload loop or KEY_POWER triggers")

def _usb_pulgin_defined_somewhere(kernel_root):
    """True if g_touchscreen_usb_pulgin is defined (not just extern'd) in the tree."""
    import re
    pat = re.compile(r"^\s*touchscreen_usb_p[li]ugin_data_t\s+g_touchscreen_usb_pulgin\s*=", re.M)
    for base in ("drivers/input/touchscreen", "drivers/power/supply"):
        base_dir = os.path.join(kernel_root, base)
        for root, _dirs, files in os.walk(base_dir):
            for name in files:
                if not name.endswith(".c"):
                    continue
                try:
                    with open(os.path.join(root, name), encoding="utf-8", errors="ignore") as f:
                        if pat.search(f.read()):
                            return True
                except OSError:
                    pass
    return False

def patch_focaltech():
    kernel_root = os.getcwd()
    d = os.path.join(kernel_root, "drivers/input/touchscreen/ft8006s_spi")
    if not os.path.exists(d):
        return

    # Define g_touchscreen_usb_pulgin in focaltech_core.c to satisfy the linker
    # on trees where nothing defines it (afterimage). cirno-pin defines it
    # natively in smb1351-charger.c; instantiating a second copy breaks the
    # vmlinux link with a multiple-definition error.
    core_c = os.path.join(d, "focaltech_core.c")
    if os.path.exists(core_c):
        with open(core_c, "r", encoding="utf-8", errors="ignore") as f:
            core_data = f.read()
        if "extern touchscreen_usb_plugin_data_t g_touchscreen_usb_pulgin;" in core_data:
            if _usb_pulgin_defined_somewhere(kernel_root):
                print("[*] g_touchscreen_usb_pulgin already defined by the tree; keeping extern")
            else:
                core_data = core_data.replace(
                    "extern touchscreen_usb_plugin_data_t g_touchscreen_usb_pulgin;",
                    "touchscreen_usb_plugin_data_t g_touchscreen_usb_pulgin;",
                    1
                )
                with open(core_c, "w", encoding="utf-8", newline="\n") as f:
                    f.write(core_data)
                print(f"[+] Instantiated g_touchscreen_usb_pulgin in {core_c}")

    # Hook /sys/touchpanel/double_tap safely using KEY_WAKEUP
    gest_c = os.path.join(d, "focaltech_gesture.c")
    if os.path.exists(gest_c):
        with open(gest_c, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

        # Tree-native tp_common wiring (e.g. cirno-pin) manages double_tap itself;
        # its include is usually #ifdef CONFIG_TP_COMMON-guarded, so injecting our
        # ops outside the guard breaks the build with an incomplete type
        native_tp_common = "tp_common_set_double_tap_ops" in content
        if not native_tp_common and "#include <linux/input/tp_common.h>" not in content:
            content = "#include <linux/input/tp_common.h>\n" + content

        # Map double click safely to KEY_WAKEUP (standard Android wakeup event)
        if "gesture = KEY_POWER;" in content:
            content = content.replace("gesture = KEY_POWER;", "gesture = KEY_WAKEUP; /* Standard wakeup */")
        elif "gesture = KEY_GESTURE_U;" in content:
            content = content.replace("gesture = KEY_GESTURE_U;", "gesture = KEY_WAKEUP; /* Standard wakeup */")

        # Define FocalTech /sys/touchpanel/double_tap ops
        if "fts_double_tap_ops" not in content and not native_tp_common:
            target_init = "int fts_gesture_init(struct fts_ts_data *ts_data)"
            ops_code = (
                "static ssize_t fts_double_tap_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf) {\n"
                '\treturn sprintf(buf, "%d\\n", fts_data ? fts_data->gesture_mode : 0);\n'
                "}\n"
                "static ssize_t fts_double_tap_store(struct kobject *kobj, struct kobj_attribute *attr, const char *buf, size_t count) {\n"
                "\tunsigned int input = 0;\n"
                '\tif (sscanf(buf, "%u", &input) == 1 && fts_data)\n'
                "\t\tfts_data->gesture_mode = (input > 0) ? 1 : 0;\n"
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

        target_sysfs = "fts_create_gesture_sysfs(ts_data->dev);"
        repl_sysfs = "fts_create_gesture_sysfs(ts_data->dev);\n    tp_common_set_double_tap_ops(&fts_double_tap_ops);"
        if target_sysfs in content and "tp_common_set_double_tap_ops" not in content:
            content = content.replace(target_sysfs, repl_sysfs, 1)

        with open(gest_c, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print("[+] Configured clean FocalTech SPI touch")

def patch_dsi_display():
    kernel_root = os.getcwd()
    f_path = os.path.join(kernel_root, "techpack/display/msm/dsi/dsi_display.c")
    if os.path.exists(f_path):
        with open(f_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
        target = "set_lct_tp_lockdown_info_callback(lct_tp_lockdown_info_callback);"
        repl = "/* set_lct_tp_lockdown_info_callback(lct_tp_lockdown_info_callback); - stubbed */"
        if target in content:
            content = content.replace(target, repl, 1)
            with open(f_path, "w", encoding="utf-8", newline="\n") as f:
                f.write(content)
            print("[+] Stubbed set_lct_tp_lockdown_info_callback in dsi_display.c")

def disable_conflicting_touch():
    kernel_root = os.getcwd()
    makefile = os.path.join(kernel_root, "drivers/input/touchscreen/Makefile")
    if os.path.exists(makefile):
        with open(makefile, "r", encoding="utf-8") as f:
            c = f.read()
        c = c.replace("obj-$(CONFIG_TOUCHSCREEN_NT36XXX)\t+= nt36xxx/", "# obj-$(CONFIG_TOUCHSCREEN_NT36XXX) += nt36xxx/ (Disabled for fog SPI)")
        c = c.replace("obj-$(CONFIG_TOUCHSCREEN_FTS)\t+= ft3418_i2c/", "# obj-$(CONFIG_TOUCHSCREEN_FTS) += ft3418_i2c/ (Disabled for fog SPI)")
        with open(makefile, "w", encoding="utf-8") as f:
            f.write(c)
        print("[+] Disabled conflicting I2C touchscreen drivers in drivers/input/touchscreen/Makefile")

if __name__ == "__main__":
    disable_conflicting_touch()
    patch_nt36xxx()
    patch_focaltech()
    patch_dsi_display()
