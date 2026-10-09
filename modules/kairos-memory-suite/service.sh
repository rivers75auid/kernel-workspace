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

# 1. LMKD Shield (Protect active apps, prune bottom cached apps when swap low)
for prop in \
  "ro.lmk.lowmem_min_oom_score:850" \
  "ro.lmk.kill_heaviest_task:false" \
  "ro.lmk.swap_free_low_percentage:15" \
  "ro.lmk.swap_is_low_kill_enable:1" \
  "ro.lmk.swap_util_max:90" \
  "ro.lmk.use_psi:true" \
  "ro.lmk.use_minfree_levels:false" \
  "ro.lmk.psi_partial_stall_ms:250" \
  "ro.lmk.psi_complete_stall_ms:700" \
  "ro.lmk.thrashing_limit:100" \
  "ro.lmk.thrashing_limit_decay:10" \
  "ro.sys.fw.bg_apps_limit:32"; do
  key="${prop%%:*}"
  val="${prop##*:}"
  resetprop "$key" "$val"
done

# 2. Activity Manager & Phantom Process Killer Mitigation
device_config put activity_manager max_cached_processes 32 2>/dev/null
device_config put activity_manager max_phantom_processes 32 2>/dev/null
device_config put activity_manager use_compaction false 2>/dev/null
device_config put activity_manager proactive_kills_enabled false 2>/dev/null
settings put global settings_enable_monitor_phantom_procs false 2>/dev/null

# 3. Kernel VM Tunables Enforcement (Lock against ROM scripts)
chmod 666 /proc/sys/vm/swappiness 2>/dev/null
echo 100 > /proc/sys/vm/swappiness
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

# 5. Parameters applied
echo "=== Kairos RAM Management Applied Successfully ===" >> $LOG

# 6. Kairos Dynamic Background Policy Daemon
CONFIG="/data/adb/kairos_config.json"
if [ ! -f "$CONFIG" ]; then
  cat << 'EOF' > "$CONFIG"
{
  "bypass_charging": false,
  "auto_bypass_games": [],
  "heavy_swap_apps": [],
  "swappiness": 100,
  "zram_size": "4000M",
  "bg_limit": 32
}
EOF
  chmod 644 "$CONFIG"
fi

# Background supervisor loop
(
  auto_disabled=0
  while true; do
    sleep 4

    if [ -f "$CONFIG" ]; then
      ac_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
      curr_pkg=$(dumpsys window 2>/dev/null | grep -m 1 "mFocusedApp" | grep -o "u0 [^/]*" | cut -d" " -f2)

      # Check if current focused app is flagged in auto_bypass_games
      is_game=0
      if [ -n "$curr_pkg" ]; then
        grep -q "\"$curr_pkg\"" "$CONFIG" 2>/dev/null && is_game=1
      fi

      manual_bypass=0
      grep -q '"bypass_charging": true' "$CONFIG" 2>/dev/null && manual_bypass=1

      if [ "$manual_bypass" -eq 1 ] || { [ "$is_game" -eq 1 ] && [ "$ac_status" != "Discharging" ]; }; then
        curr_state=$(cat /sys/class/power_supply/battery/charging_enabled 2>/dev/null)
        if [ "$curr_state" != "0" ]; then
          echo 0 > /sys/class/power_supply/battery/charging_enabled
          auto_disabled=1
        fi
      elif [ "$auto_disabled" -eq 1 ]; then
        echo 1 > /sys/class/power_supply/battery/charging_enabled
        auto_disabled=0
      fi
    fi
  done
) </dev/null >/dev/null 2>&1 &

