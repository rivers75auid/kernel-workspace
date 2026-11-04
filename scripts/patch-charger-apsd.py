#!/usr/bin/env python3
"""smb1351: delay the APSD rerun so a QC adapter is not locked in as SDP/100mA.

Measured on Redmi 10C (fog): the first plug after a data-cable swap reads
STATUS_5_REG as SDP, the immediate rerun lands on still-settling D+/D- lines
and also reads SDP, and the apsd_rerun guard then blocks every further
attempt -> charging stuck at 0W until the next replug. Re-running APSD from a
delayed work (after the lines settle) classifies the adapter as DCP and the
existing hvdcp_det_work then completes QC 3.0 negotiation."""
import os
import sys

DRIVER = "drivers/power/supply/qcom/smb1351-charger.c"

STRUCT_ANCHOR = "\tstruct delayed_work\thvdcp_det_work;"
STRUCT_NEW = (STRUCT_ANCHOR +
    "\n\tstruct delayed_work\tapsd_rerun_work;")

WORKER_ANCHOR = (
    "\tif (rc)\n"
    "\t\tpr_err(\"Couldn't re-run APSD algo\\n\");\n"
    "\n"
    "\treturn 0;\n"
    "}\n"
)
WORKER_NEW = WORKER_ANCHOR + (
    "\n"
    "/* Delayed rerun: see smb1351_apsd_rerun_work() comment. */\n"
    "static void smb1351_apsd_rerun_work(struct work_struct *work)\n"
    "{\n"
    "\tstruct smb1351_charger *chip = container_of(work,\n"
    "\t\t\t\t\tstruct smb1351_charger,\n"
    "\t\t\t\t\tapsd_rerun_work.work);\n"
    "\n"
    "\tpr_err(\"Delayed APSD rerun after settle\\n\");\n"
    "\trerun_apsd(chip);\n"
    "\tpm_relax(chip->dev);\n"
    "}\n"
)

RERUN_ANCHOR = (
    "\t\t\t\tchip->apsd_rerun = true;\n"
    "\t\t\t\trerun_apsd(chip);"
)
RERUN_NEW = (
    "\t\t\t\tchip->apsd_rerun = true;\n"
    "\t\t\t\tpm_stay_awake(chip->dev);\n"
    "\t\t\t\tschedule_delayed_work(&chip->apsd_rerun_work,\n"
    "\t\t\t\t\t\tmsecs_to_jiffies(800));"
)

INIT_ANCHOR = "\tINIT_DELAYED_WORK(&chip->hvdcp_det_work, smb1351_hvdcp_det_work);"
INIT_NEW = (INIT_ANCHOR +
    "\n\tINIT_DELAYED_WORK(&chip->apsd_rerun_work, smb1351_apsd_rerun_work);")

CANCEL_ANCHOR = "\t\tcancel_delayed_work_sync(&chip->hvdcp_det_work);"
CANCEL_NEW = (CANCEL_ANCHOR +
    "\n\t\tcancel_delayed_work_sync(&chip->apsd_rerun_work);")

EDITS = [
    ("struct apsd_rerun_work field", STRUCT_ANCHOR, STRUCT_NEW),
    ("apsd_rerun_work worker", WORKER_ANCHOR, WORKER_NEW),
    ("delayed rerun at handler", RERUN_ANCHOR, RERUN_NEW),
    ("INIT_DELAYED_WORK in probe", INIT_ANCHOR, INIT_NEW),
    ("cancel on teardown", CANCEL_ANCHOR, CANCEL_NEW),
]


def main():
    if not os.path.exists(DRIVER):
        print(f"[-] {DRIVER} not found")
        return 1
    with open(DRIVER, encoding="utf-8", errors="ignore") as f:
        c = f.read()
    if "apsd_rerun_work" in c:
        print("[+] smb1351 delayed APSD rerun already applied")
        return 0
    failed = False
    for name, old, new in EDITS:
        if old not in c:
            print(f"[-] anchor not found: {name}")
            failed = True
            continue
        c = c.replace(old, new, 1)
        print(f"[+] {name}")
    if failed:
        return 1
    with open(DRIVER, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    print("[+] smb1351 delayed APSD rerun patched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
