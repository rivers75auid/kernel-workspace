#!/system/bin/sh
# Kairos Engine - Memory, ZRAM Writeback & Charging Supervisor
MODDIR=${0%/*}

while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

# Give vendor post-boot setup time to finish before enforcing Kairos state
sleep 3

LOG="/data/adb/kairos_ram_management.log"
echo "=== Kairos Engine Started: $(date) ===" > "$LOG"

CONFIG="/data/adb/kairos_config.json"
if [ ! -f "$CONFIG" ]; then
  cat << 'EOF' > "$CONFIG"
{
  "bypass_charging": false,
  "auto_bypass_games": [],
  "heavy_swap_apps": [],
  "swappiness": 100,
  "comp_algorithm": "zstd",
  "zram_size": "3072M",
  "zram_writeback": false,
  "wb_size_mb": 1024,
  "watermark_scale": 15,
  "vfs_cache_pressure": 100,
  "compaction_proactiveness": 20,
  "bg_limit": 32,
  "thermal_guard": false,
  "thermal_limit_c": 52,
  "charge_limit": 100
}
EOF
  chmod 644 "$CONFIG"
fi

cfg_val() {
  awk -v key="\"$1\"" '
    {
      gsub(/[\r\n]/, " ")
      line = line $0
    }
    END {
      if (match(line, key "[[:space:]]*:[[:space:]]*\"?[^,}\\]]+\"?")) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^[^:]*:[[:space:]]*/, "", s)
        gsub(/^"|"$/, "", s)
        gsub(/[[:space:]]+$/, "", s)
        print s
      }
    }
  ' "$CONFIG" 2>/dev/null
}

cfg_bool() {
  v=$(cfg_val "$1")
  [ "$v" = "true" ] && echo 1 || echo 0
}

SWAPPINESS=$(cfg_val swappiness); [ -z "$SWAPPINESS" ] && SWAPPINESS=100
COMP_ALGO=$(cfg_val comp_algorithm); [ -z "$COMP_ALGO" ] && COMP_ALGO="zstd"
ZRAM_SIZE=$(cfg_val zram_size); [ -z "$ZRAM_SIZE" ] && ZRAM_SIZE="3072M"
ZRAM_WB=$(cfg_bool zram_writeback)
WB_SIZE=$(cfg_val wb_size_mb); [ -z "$WB_SIZE" ] && WB_SIZE=1024
WM_SCALE=$(cfg_val watermark_scale); [ -z "$WM_SCALE" ] && WM_SCALE=15
VFS_PRESSURE=$(cfg_val vfs_cache_pressure); [ -z "$VFS_PRESSURE" ] && VFS_PRESSURE=100
COMP_PROACT=$(cfg_val compaction_proactiveness); [ -z "$COMP_PROACT" ] && COMP_PROACT=20
BG_LIMIT=$(cfg_val bg_limit); [ -z "$BG_LIMIT" ] && BG_LIMIT=32

# 1. Align ActivityManager & LMKD (keep PSI active; prune cached junk without starving IME/UI)
resetprop ro.sys.fw.bg_apps_limit "$BG_LIMIT"
if command -v device_config >/dev/null 2>&1; then
  device_config put activity_manager max_cached_processes "$BG_LIMIT" 2>/dev/null
  device_config put activity_manager max_phantom_processes 64 2>/dev/null
  device_config put activity_manager use_compaction false 2>/dev/null
  device_config put activity_manager proactive_kills_enabled false 2>/dev/null
  device_config delete activity_manager no_kill_cached_processes_post_boot_completed_duration_millis 2>/dev/null
  if [ "$(getprop ro.lmk.use_psi)" = "true" ]; then
    device_config put lmkd_native use_minfree_levels false 2>/dev/null
  fi
fi
settings put global settings_enable_monitor_phantom_procs false 2>/dev/null

# 2. Disable conflicting vendor reclaimers (Scene-adapted, MGLRU/PSI friendly)
[ -e /sys/module/process_reclaim/parameters/enable_process_reclaim ] && echo 0 > /sys/module/process_reclaim/parameters/enable_process_reclaim 2>/dev/null
[ -e /sys/kernel/mi_reclaim/enable ] && echo 0 > /sys/kernel/mi_reclaim/enable 2>/dev/null
[ -e /sys/kernel/mi_reclaim/greclaim_enable ] && echo 0 > /sys/kernel/mi_reclaim/greclaim_enable 2>/dev/null
[ -e /sys/kernel/low_free/low_free_enable ] && echo 0 > /sys/kernel/low_free/low_free_enable 2>/dev/null
[ -e /sys/kernel/mm/transparent_hugepage/enabled ] && echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
[ -e /sys/kernel/mm/transparent_hugepage/defrag ] && echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null

# 3. Apply persisted ZRAM (size, algorithm, optional writeback) & VM tunables at boot
ZRES=$(sh "$MODDIR/kairos_zram.sh" apply "$ZRAM_SIZE" "$COMP_ALGO" "$ZRAM_WB" "$WB_SIZE" "$SWAPPINESS" "$VFS_PRESSURE" "$WM_SCALE" "$COMP_PROACT" 2>&1)
echo "Boot ZRAM apply: $ZRES" >> "$LOG"

# 4. Keep kswapd/kcompactd responsive on foreground cpuset (avoid getting starved on idle cores)
for kproc in kswapd0 kcompactd0; do
  kpid=$(pgrep -x "$kproc" 2>/dev/null | head -1)
  if [ -n "$kpid" ] && [ -d /dev/cpuset/foreground ]; then
    echo "$kpid" > /dev/cpuset/foreground/cgroup.procs 2>/dev/null
  fi
done

# 5. CPU Schedutil Smoothing & Headroom
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
  if [ -d "$pol/schedutil" ]; then
    echo 20000 > "$pol/schedutil/down_rate_limit_us" 2>/dev/null
  fi
done
if [ -d /dev/stune/top-app ]; then
  echo 5 > /dev/stune/top-app/schedtune.boost 2>/dev/null
  echo 1 > /dev/stune/top-app/schedtune.prefer_idle 2>/dev/null
fi

echo "=== Kairos Engine Boot Setup Completed ===" >> "$LOG"

# 6. Charging control node detection
CHARGE_NODE=""
CH_ON=1
CH_OFF=0
if [ -e /sys/class/power_supply/battery/charging_enabled ]; then
  CHARGE_NODE="/sys/class/power_supply/battery/charging_enabled"
elif [ -e /sys/class/power_supply/battery/input_suspend ]; then
  CHARGE_NODE="/sys/class/power_supply/battery/input_suspend"
  CH_ON=0
  CH_OFF=1
fi

# Dynamic supervisor loop (Thermal guard, charge limit, game bypass & heavy_swap enforcement)
(
  thermal_cut=0
  cap_cut=0
  tick=0

  while true; do
    sleep 4
    tick=$((tick + 1))

    [ -f "$CONFIG" ] || continue

    config_flat=$(tr -d '\n' < "$CONFIG")
    batt_temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    [ -z "$batt_temp" ] && batt_temp=0
    batt_cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    [ -z "$batt_cap" ] && batt_cap=0
    ac_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)

    # Thermal Guard
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

    # Charge Limit
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

    games_block=$(printf '%s' "$config_flat" | sed -n 's/.*"auto_bypass_games": *\[\([^]]*\)\].*/\1/p')
    swap_block=$(printf '%s' "$config_flat" | sed -n 's/.*"heavy_swap_apps": *\[\([^]]*\)\].*/\1/p')

    curr_pkg=""
    need_fg=0
    if [ -n "$games_block" ] && [ -n "$ac_status" ] && [ "$ac_status" != "Discharging" ]; then
      need_fg=1
    elif [ -n "$swap_block" ] && [ $((tick % 5)) -eq 0 ]; then
      # Only enforce heavy_swap_apps every ~20s to avoid polling overhead
      need_fg=1
    fi

    if [ "$need_fg" -eq 1 ]; then
      curr_pkg=$(dumpsys window 2>/dev/null | grep -m 1 "mFocusedApp" | grep -o "u0 [^/]*" | cut -d" " -f2)
    fi

    # Game Mode Bypass
    is_game=0
    if [ -n "$games_block" ] && [ -n "$curr_pkg" ] && printf '%s\n' "$games_block" | grep -q "\"$curr_pkg\""; then
      is_game=1
    fi

    # Real Heavy Swap Enforcement (only when app is NOT foreground and NEVER on active IME)
    if [ -n "$swap_block" ] && [ $((tick % 5)) -eq 0 ]; then
      ime_pkg=$(settings get secure default_input_method 2>/dev/null | cut -d/ -f1)
      printf '%s' "$swap_block" | tr ',' '\n' | tr -d ' "' | while IFS= read -r spkg; do
        [ -n "$spkg" ] || continue
        [ "$spkg" = "$curr_pkg" ] && continue
        [ -n "$ime_pkg" ] && [ "$spkg" = "$ime_pkg" ] && continue
        for pid in $(pidof "$spkg" 2>/dev/null); do
          if [ -w "/proc/$pid/oom_score_adj" ]; then
            cur_oom=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null)
            # Nudge cached background heavy apps gently toward swap/LMKD pruning without killing foreground services (<= 200)
            if [ -n "$cur_oom" ] && [ "$cur_oom" -gt 200 ] && [ "$cur_oom" -lt 900 ]; then
              echo 900 > "/proc/$pid/oom_score_adj" 2>/dev/null
            fi
          fi
        done
      done
    fi

    manual_bypass=0
    printf '%s' "$config_flat" | grep -q '"bypass_charging": *true' && manual_bypass=1

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
