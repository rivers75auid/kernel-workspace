#!/system/bin/sh
# governor_schedutil.sh
# Force schedutil default governor until kernel config fix ships (CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL).
# ponytail: delete this file once CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y is the compiled default.
MODDIR=${0%/*}

for c in /sys/devices/system/cpu/cpu[0-7]; do
    [ -w "$c/cpufreq/scaling_governor" ] && echo schedutil > "$c/cpufreq/scaling_governor" 2>/dev/null
done

# Optimal RAM tuning for 4GB physical RAM + 3GB ZRAM (zstd)
# Prevents aggressive LMK app killing by actively paging cold memory into ZRAM
echo 100 > /proc/sys/vm/swappiness 2>/dev/null
echo 100 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
echo 0 > /proc/sys/vm/page-cluster 2>/dev/null
echo 20 > /proc/sys/vm/dirty_ratio 2>/dev/null
echo 10 > /proc/sys/vm/dirty_background_ratio 2>/dev/null
[ -w /sys/kernel/mm/lru_gen/enabled ] && echo 1 > /sys/kernel/mm/lru_gen/enabled 2>/dev/null

# Deep Sleep preservation while Wi-Fi / Bluetooth scanning is enabled
# Batches location scans to prevent continuous CPU wakelocks
settings put global wifi_scan_throttle_enabled 1 2>/dev/null
settings put global ble_scan_low_power_window_ms 500 2>/dev/null
settings put global ble_scan_low_power_interval_ms 5000 2>/dev/null
settings put global ble_scan_balanced_window_ms 2000 2>/dev/null
settings put global ble_scan_balanced_interval_ms 10000 2>/dev/null


