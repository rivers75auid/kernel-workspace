#!/system/bin/sh
# Kairos RAM Management - Universal Background Service
MODDIR=${0%/*}

# Wait until Android runtime is fully booted
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

# Wait for vendor post-boot scripts to finish
sleep 3

LOG="/cache/kairos_ram_management.log"
echo "=== Kairos RAM Management Started: $(date) ===" > $LOG

# 1. LMKD Shield (Disable aggressive killing)
for prop in \
  "ro.lmk.lowmem_min_oom_score:1001" \
  "ro.lmk.kill_heaviest_task:false" \
  "ro.lmk.swap_free_low_percentage:0" \
  "ro.lmk.swap_is_low_kill_enable:0" \
  "ro.lmk.swap_util_max:100" \
  "ro.lmk.use_psi:true" \
  "ro.lmk.use_minfree_levels:false" \
  "ro.lmk.psi_partial_stall_ms:250" \
  "ro.lmk.psi_complete_stall_ms:700" \
  "ro.lmk.thrashing_limit:100" \
  "ro.lmk.thrashing_limit_decay:10" \
  "ro.sys.fw.bg_apps_limit:64"; do
  key="${prop%%:*}"
  val="${prop##*:}"
  resetprop "$key" "$val"
done

# 2. Activity Manager & Phantom Process Killer Mitigation
device_config put activity_manager max_cached_processes 64 2>/dev/null
device_config put activity_manager max_phantom_processes 64 2>/dev/null
device_config put activity_manager no_kill_cached_processes_post_boot_completed_duration_millis 2147483647 2>/dev/null
device_config put activity_manager max_empty_time_millis 2147483647 2>/dev/null
device_config put activity_manager kill_bg_restricted_cached_idle_settle_time 2147483647 2>/dev/null
device_config put activity_manager use_compaction false 2>/dev/null
device_config put activity_manager proactive_kills_enabled false 2>/dev/null
settings put global settings_enable_monitor_phantom_procs false 2>/dev/null

# 3. Kernel VM Tunables Enforcement (Lock against ROM scripts)
chmod 666 /proc/sys/vm/swappiness 2>/dev/null
echo 160 > /proc/sys/vm/swappiness
chmod 444 /proc/sys/vm/swappiness 2>/dev/null

chmod 666 /proc/sys/vm/watermark_scale_factor 2>/dev/null
echo 10 > /proc/sys/vm/watermark_scale_factor
chmod 444 /proc/sys/vm/watermark_scale_factor 2>/dev/null

echo 0 > /proc/sys/vm/watermark_boost_factor 2>/dev/null
echo 0 > /proc/sys/vm/page-cluster 2>/dev/null
echo 100 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
echo 1 > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null
echo 5 > /proc/sys/vm/dirty_background_ratio 2>/dev/null
echo 10 > /proc/sys/vm/dirty_ratio 2>/dev/null
echo 0 > /proc/sys/vm/panic_on_oom 2>/dev/null

# 4. CPU Schedutil Smoothing & Headroom
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
  if [ -d "$pol/schedutil" ]; then
    echo 20000 > "$pol/schedutil/down_rate_limit_us" 2>/dev/null
  fi
done

if [ -d /dev/stune/top-app ]; then
  echo 5 > /dev/stune/top-app/schedtune.boost 2>/dev/null
  echo 1 > /dev/stune/top-app/schedtune.prefer_idle 2>/dev/null
fi

# 5. Restart LMKD once to adopt new parameters cleanly
killall lmkd 2>/dev/null

echo "=== Kairos RAM Management Applied Successfully ===" >> $LOG
