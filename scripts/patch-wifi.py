#!/usr/bin/env python3
"""Surgical backport of Qualcomm qcacld-3.0 on-demand loading & WCN3950/3980 compatibility.

Applies the proven Wi-Fi fixes from alternoegraha's afterimage branch directly to fog:
1. Lazy on-demand driver loading in wlan_hdd_main.c (prevents early-boot firmware load failure before /vendor mount).
2. Disable 160MHz and 802.11ax in default_defconfig (Redmi 10C WCN3950/3980 is 802.11ac only; prevents QMI negotiation failure).
3. HIF CE and HTT H2T QDF_STATUS error casts (prevents compiler/runtime status mismatch).
"""
import os
import sys

def patch_wlan_hdd_main():
    path = "drivers/staging/qcacld-3.0/core/hdd/src/wlan_hdd_main.c"
    if not os.path.exists(path):
        print(f"[-] {path} not found, skipping.")
        return False
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        c = f.read()

    if "static bool hdd_loaded = false;" in c:
        print(f"[+] {path} already patched for on-demand loading.")
        return True

    # 1. Add static bool hdd_loaded
    t1 = "static dev_t device;"
    r1 = "static dev_t device;\nstatic bool hdd_loaded = false;"
    if t1 not in c:
        print(f"[-] Target t1 not found in {path}")
        return False
    c = c.replace(t1, r1, 1)

    # 2. Add prototype and lazy load call in wlan_hdd_state_ctrl_param_write
    t2 = 'if (!cds_is_driver_loaded() || cds_is_driver_recovering()) {'
    r2 = '''\tif (!hdd_loaded) {
\t\tif (hdd_driver_load()) {
\t\t\tpr_err("%s: Failed to init hdd module\\n", __func__);
\t\t\tgoto exit;
\t\t}
\t}

\tif (!cds_is_driver_loaded() || cds_is_driver_recovering()) {'''
    if t2 not in c:
        print(f"[-] Target t2 not found in {path}")
        return False
    c = c.replace(t2, r2, 1)

    # Also add prototype static int hdd_driver_load(void); before wlan_hdd_state_ctrl_param_write
    t2_proto = "static ssize_t wlan_hdd_state_ctrl_param_write(struct file *filp,"
    r2_proto = "static int hdd_driver_load(void);\nstatic ssize_t wlan_hdd_state_ctrl_param_write(struct file *filp,"
    if t2_proto not in c:
        print(f"[-] Target t2_proto not found in {path}")
        return False
    c = c.replace(t2_proto, r2_proto, 1)

    # 3. In hdd_driver_load, remove param create and set hdd_loaded = true
    t3 = '''\terrno = wlan_hdd_state_ctrl_param_create();
\tif (errno) {
\t\thdd_err("Failed to create ctrl param; errno:%d", errno);
\t\tgoto wakelock_destroy;
\t}'''
    if t3 in c:
        c = c.replace(t3, "", 1)

    t3_clean = '''param_destroy:
\twlan_hdd_state_ctrl_param_destroy();'''
    if t3_clean in c:
        c = c.replace(t3_clean, "", 1)

    t3_set = 'hdd_debug("%s: driver loaded", WLAN_MODULE_NAME);'
    r3_set = 'hdd_loaded = true;\n\thdd_debug("%s: driver loaded", WLAN_MODULE_NAME);'
    if t3_set in c and "hdd_loaded = true;" not in c:
        c = c.replace(t3_set, r3_set, 1)

    # 4. In hdd_module_init, only create ctrl param node
    t4 = '''static int hdd_module_init(void)
{
\tif (hdd_driver_load())
\t\treturn -EINVAL;

\treturn 0;
}'''
    r4 = '''static int hdd_module_init(void)
{
\tint ret;

\tret = wlan_hdd_state_ctrl_param_create();
\tif (ret)
\t\tpr_err("wlan_hdd_state_create:%x\\n", ret);

\treturn ret;
}'''
    if t4 not in c:
        print(f"[-] Target t4 not found in {path}")
        return False
    c = c.replace(t4, r4, 1)

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    print(f"[+] Successfully patched on-demand WLAN loading in {path}!")
    return True

def patch_ce_and_htt():
    # 1. ce_main.c
    p1 = "drivers/staging/qca-wifi-host-cmn/hif/src/ce/ce_main.c"
    if os.path.exists(p1):
        with open(p1, "r", encoding="utf-8", errors="ignore") as f:
            c1 = f.read()
        t1 = 'HIF_ERROR("%s: error CE handle is null", __func__);\n\t\treturn A_ERROR;'
        r1 = 'HIF_ERROR("%s: error CE handle is null", __func__);\n\t\treturn (QDF_STATUS)A_ERROR;'
        if t1 in c1:
            c1 = c1.replace(t1, r1, 1)
            with open(p1, "w", encoding="utf-8", newline="\n") as f:
                f.write(c1)
            print(f"[+] Patched QDF_STATUS in {p1}")

    # 2. htt_h2t.c
    p2 = "drivers/staging/qcacld-3.0/core/dp/htt/htt_h2t.c"
    if os.path.exists(p2):
        with open(p2, "r", encoding="utf-8", errors="ignore") as f:
            c2 = f.read()
        c2 = c2.replace("return A_ERROR; /* failure */", "return (QDF_STATUS)A_ERROR; /* failure */")
        with open(p2, "w", encoding="utf-8", newline="\n") as f:
            f.write(c2)
        print(f"[+] Patched QDF_STATUS in {p2}")

if __name__ == "__main__":
    patch_wlan_hdd_main()
    patch_ce_and_htt()
