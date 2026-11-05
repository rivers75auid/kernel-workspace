#!/system/bin/sh
# Kairos RAM Management - Universal Background Service
MODDIR=${0%/*}

# Wait until Android runtime is fully booted
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

# Wait for vendor post-boot scripts to finish
sleep 3

LOG="/data/adb/kairos_ram_management.log"
echo "=== Kairos RAM Management Started: $(date) ===" > $LOG

CONFIG="/data/adb/kairos_config.json"
if [ ! -f "$CONFIG" ]; then
  cat << 'EOF' > "$CONFIG"
{
  "bypass_charging": false,
  "auto_bypass_games": [],
  "heavy_swap_apps": [],
  "swappiness": 100,
  "zram_size": "4000M",
  "bg_limit": 32,
  "thermal_guard": false,
  "thermal_limit_c": 52,
  "charge_limit": 100
}
EOF
  chmod 644 "$CONFIG"
fi

cfg_num() {
  tr -d '\n' < "$CONFIG" | sed -n "s/.*\"$1\": *\"\{0,1\}\([0-9]\{1,5\}M\{0,1\}\)\"\{0,1\}.*/\1/p"
}
SWAPPINESS=$(cfg_num swappiness); [ -z "$SWAPPINESS" ] && SWAPPINESS=100
BG_LIMIT=$(cfg_num bg_limit); [ -z "$BG_LIMIT" ] && BG_LIMIT=32
ZRAM_SIZE=$(cfg_num zram_size)

# 1. LMKD thresholds live in system.prop: lmkd reads ro.lmk.* once at start,
#    so resetprop here would only change getprop output, not lmkd behavior.
resetprop ro.sys.fw.bg_apps_limit "$BG_LIMIT"

# 2. Activity Manager & Phantom Process Killer Mitigation
device_config put activity_manager max_cached_processes "$BG_LIMIT" 2>/dev/null
device_config put activity_manager max_phantom_processes 32 2>/dev/null
device_config put activity_manager use_compaction false 2>/dev/null
device_config put activity_manager proactive_kills_enabled false 2>/dev/null
settings put global settings_enable_monitor_phantom_procs false 2>/dev/null

# 3. Kernel VM Tunables Enforcement (Lock against ROM scripts)
chmod 666 /proc/sys/vm/swappiness 2>/dev/null
echo "$SWAPPINESS" > /proc/sys/vm/swappiness
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

# Charging control node: smblite exposes no charging_enabled; fall back to input_suspend
CHARGE_NODE=""
CH_ON=1
CH_OFF=0
if [ -e /sys/class/power_supply/battery/charging_enabled ]; then
  CHARGE_NODE="/sys/class/power_supply/battery/charging_enabled"
elif [ -e /sys/class/power_supply/battery/input_suspend ]; then
  CHARGE_NODE="/sys/class/power_supply/battery/input_suspend"
  CH_ON=0   # input_suspend semantics are inverted: 0 = charging allowed
  CH_OFF=1
fi

# Background supervisor loop
(
  thermal_cut=0
  cap_cut=0

  while true; do
    sleep 4

    [ -f "$CONFIG" ] || continue

    config_flat=$(tr -d '\n' < "$CONFIG")
    batt_temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    [ -z "$batt_temp" ] && batt_temp=0
    batt_cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    [ -z "$batt_cap" ] && batt_cap=0
    ac_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)

    # 1. Thermal Guard (opt-in: cut at limit, resume 3°C below)
    thermal_guard=0
    printf '%s' "$config_flat" | grep -q '"thermal_guard": *true' && thermal_guard=1
    thermal_limit_c=$(printf '%s' "$config_flat" | sed -n 's/.*"thermal_limit_c": *\([0-9]\{1,3\}\).*/\1/p')
    [ -z "$thermal_limit_c" ] && thermal_limit_c=52
    if [ "$thermal_guard" -eq 1 ]; then
      limit_t=$((thermal_limit_c * 10))
      if [ "$batt_temp" -ge "$limit_t" ]; then
        thermal_cut=1
      elif [ "$batt_temp" -le $((limit_t - 30)) ]; then
        thermal_cut=0
      fi
    else
      thermal_cut=0
    fi

    # 2. Battery Charge Limit Cut-off (e.g. 80%, 85%, 90%)
    charge_limit=$(printf '%s' "$config_flat" | sed -n 's/.*"charge_limit": *\([0-9]\{1,3\}\).*/\1/p')
    [ -z "$charge_limit" ] && charge_limit=100

    if [ "$charge_limit" -lt 100 ]; then
      if [ "$batt_cap" -ge "$charge_limit" ]; then
        cap_cut=1
      elif [ "$batt_cap" -le $((charge_limit - 3)) ]; then
        cap_cut=0
      fi
    else
      cap_cut=0
    fi

    # 3. Game Mode: only matters while plugged in, so skip the costly dumpsys on battery
    is_game=0
    games_block=$(printf '%s' "$config_flat" | sed -n 's/.*"auto_bypass_games": *\[\([^]]*\)\].*/\1/p')
    if [ -n "$games_block" ] && [ -n "$ac_status" ] && [ "$ac_status" != "Discharging" ]; then
      curr_pkg=$(dumpsys window 2>/dev/null | grep -m 1 "mFocusedApp" | grep -o "u0 [^/]*" | cut -d" " -f2)
      if [ -n "$curr_pkg" ] && printf '%s\n' "$games_block" | grep -q "\"$curr_pkg\""; then
        is_game=1
      fi
    fi

    manual_bypass=0
    printf '%s' "$config_flat" | grep -q '"bypass_charging": *true' && manual_bypass=1

    # 4. Desired charging state, compare-and-set every tick (never a latched flag)
    should_bypass=0
    if [ "$thermal_cut" -eq 1 ] || [ "$cap_cut" -eq 1 ] || [ "$manual_bypass" -eq 1 ]; then
      should_bypass=1
    elif [ "$is_game" -eq 1 ] && [ -n "$ac_status" ] && [ "$ac_status" != "Discharging" ]; then
      should_bypass=1
    fi

    if [ -n "$CHARGE_NODE" ]; then
      curr_state=$(cat "$CHARGE_NODE" 2>/dev/null)
      if [ -n "$curr_state" ]; then
        desired=$CH_ON
        [ "$should_bypass" -eq 1 ] && desired=$CH_OFF
        if [ "$curr_state" != "$desired" ]; then
          echo "$desired" > "$CHARGE_NODE" 2>/dev/null
        fi
      fi
    fi
  done
) </dev/null >/dev/null 2>&1 &

