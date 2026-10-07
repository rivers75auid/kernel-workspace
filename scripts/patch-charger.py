#!/usr/bin/env python3
import os
import sys

def patch_smb1351():
    kernel_root = os.getcwd()
    filepath = os.path.join(kernel_root, "drivers/power/supply/qcom/smb1351-charger.c")

    if not os.path.exists(filepath):
        print(f"[-] WARNING: {filepath} not found, skipping charger patch.")
        return

    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    # Fix commented-out HVDCP_3 (Quick Charge 3.0 18W) notification to USB PSY
    target = '''\telse if (is_hvdcp_3) {
\t     pr_err("HVDCP_3 detected; notifying USB PSY\\n");
\t    chip->charger_type  = POWER_SUPPLY_TYPE_USB_HVDCP_3;
\t     //power_supply_set_property(chip->usb_psy,
\t\t\t\t\t//POWER_SUPPLY_PROP_TYPE, &pval);
\t}'''

    replacement = '''\telse if (is_hvdcp_3) {
\t\tpr_err("HVDCP_3 (QC 3.0) detected; notifying USB PSY for 18W fast charging\\n");
\t\tpval.intval = POWER_SUPPLY_TYPE_USB_HVDCP_3;
\t\tpower_supply_set_property(chip->usb_psy,
\t\t\tPOWER_SUPPLY_PROP_TYPE, &pval);
\t\tchip->charger_type = POWER_SUPPLY_TYPE_USB_HVDCP_3;
\t}'''

    if replacement in content:
        print("[+] smb1351 HVDCP_3 QC3.0 notification already enabled.")
        return

    if target in content:
        content = content.replace(target, replacement, 1)
        with open(filepath, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print(f"[+] Successfully enabled HVDCP_3 QC3.0 notification in {filepath}")
    else:
        print("[-] WARNING: Target string for HVDCP_3 not found in smb1351-charger.c!")

if __name__ == "__main__":
    patch_smb1351()
