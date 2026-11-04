#!/system/bin/sh
# Kairos device audit - run as root, outputs everything to /sdcard
# su -c "sh /sdcard/device_audit.sh"
# Phone is free to use afterwards; the file stays on internal storage.

OUT="/sdcard/kairos_audit_$(date +%Y%m%d_%H%M).txt"

{
echo "=== KAIROS DEVICE AUDIT $(date) ==="
echo "--- identity ---"
uname -a
getprop ro.product.device
getprop ro.build.version.release
getprop ro.build.version.incremental

echo ""
echo "=== CHARGER (audit #1-3, #6) ==="
ls /sys/class/power_supply/
ls /sys/class/power_supply/battery/ | grep -E "charging_enabled|input_suspend|system_temp|charge_control|constant_charge|step"
for f in status health temp current_now voltage_now input_suspend charge_control_limit constant_charge_current_max; do
  echo "$f=$(cat /sys/class/power_supply/battery/$f 2>&1)"
done
echo "usb_real_type=$(cat /sys/class/power_supply/usb/real_type 2>&1)"
echo "usb_voltage_max=$(cat /sys/class/power_supply/usb/voltage_max 2>&1)"
echo "usb_current_max=$(cat /sys/class/power_supply/usb/current_max 2>&1)"
echo "--- dmesg charger ---"
dmesg | grep -iE "smblite|smb[0-9]|bq2|sgm|nopmi|charger|jeita|aicl|icl|sh3661" | tail -80

echo ""
echo "=== TOUCH (audit #5, #14) ==="
echo "--- dmesg touch ---"
dmesg | grep -iE "NVT|nt36|FTS|ft8006|Novatek|FocalTech|ESD|recovery|Gesture" | tail -80
echo "--- getevent ---"
getevent -lp 2>/dev/null | grep -B2 -A12 -i "touch"

echo ""
echo "=== HOTSPOT (audit #7) ==="
echo "--- dmesg net ---"
dmesg | grep -iE "page allocation failure|wlan|sap|hostapd|ipa|rmnet" | tail -80
echo "--- logcat tether ---"
logcat -b all -d 2>/dev/null | grep -iE "softap|tether|hostapd|netd|Tethering" | tail -120

echo ""
echo "=== ROOT / SUSFS (exposure check) ==="
echo "--- modules ---"
ls /data/adb/modules/ 2>/dev/null
echo "--- kernel log root ---"
dmesg | grep -iE "susfs|sukisu|kernelsu|ksu " | tail -60
echo "--- mounts (susfs visibility) ---"
cat /proc/mounts | grep -iE "module|overlay" | head -20

echo ""
echo "=== END AUDIT ==="
} > "$OUT" 2>&1

echo "Saved to $OUT"
