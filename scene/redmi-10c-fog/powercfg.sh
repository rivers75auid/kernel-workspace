#!/system/bin/sh
# Custom Scene9 powercfg for Xiaomi Redmi 10C (fog / SM6225 khaje)
# Hardware profile grounded in Cirno-Pin kernel DTS + config:
# - CPU0..3: Kryo 265 Silver (policy0, capacity-dmips-mhz 1024)
# - CPU4..7: Kryo 265 Gold   (policy4, capacity-dmips-mhz 1638)
# - Scheduler: CONFIG_SCHED_WALT=y + CONFIG_SCHED_TUNE=y + CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y
# - GPU: Adreno 610 (kgsl-3d0, msm-adreno-tz)
# - Memory/ZRAM/MGLRU/PSI left untouched so Kairos RAM Management v2.3 owns RAM cleanly.

action="${1:-balance}"

P0="/sys/devices/system/cpu/cpufreq/policy0"
P4="/sys/devices/system/cpu/cpufreq/policy4"
GPU_DIR="/sys/class/kgsl/kgsl-3d0"
GPU_DF="$GPU_DIR/devfreq"

set_val() {
    local val="$1"
    local path="$2"
    [ -w "$path" ] && echo "$val" > "$path" 2>/dev/null
}

# Pick the highest available frequency <= target (or lowest if target is below min).
pick_freq_le() {
    local avail_file="$1"
    local target="$2"
    [ -r "$avail_file" ] || { echo "$target"; return; }
    local best=""
    local first=""
    local f
    for f in $(tr ' ' '\n' < "$avail_file" | sort -n); do
        [ -n "$f" ] || continue
        [ -z "$first" ] && first="$f"
        if [ "$f" -le "$target" ] 2>/dev/null; then
            best="$f"
        fi
    done
    if [ -n "$best" ]; then
        echo "$best"
    elif [ -n "$first" ]; then
        echo "$first"
    else
        echo "$target"
    fi
}

# Pick the lowest available frequency >= target (or max if target is above max).
pick_freq_ge() {
    local avail_file="$1"
    local target="$2"
    [ -r "$avail_file" ] || { echo "$target"; return; }
    local last=""
    local f
    for f in $(tr ' ' '\n' < "$avail_file" | sort -n); do
        [ -n "$f" ] || continue
        last="$f"
        if [ "$f" -ge "$target" ] 2>/dev/null; then
            echo "$f"
            return
        fi
    done
    [ -n "$last" ] && echo "$last" || echo "$target"
}

policy_bounds() {
    local pdir="$1"
    local req_min="$2"
    local req_max="$3"
    local avail="$pdir/scaling_available_frequencies"
    local fmin fmax
    fmin="$(pick_freq_ge "$avail" "$req_min")"
    fmax="$(pick_freq_le "$avail" "$req_max")"
    [ "$fmin" -gt "$fmax" ] 2>/dev/null && fmin="$fmax"
    # Update max before min when raising, min before max when lowering cleanly via dual pass
    set_val "$fmax" "$pdir/scaling_max_freq"
    set_val "$fmin" "$pdir/scaling_min_freq"
    set_val "$fmax" "$pdir/scaling_max_freq"
}

tune_schedutil() {
    local pdir="$1"
    local up_us="$2"
    local down_us="$3"
    local hi_target="$4"
    local hi_load="$5"
    local pl="$6"
    set_val "schedutil" "$pdir/scaling_governor"
    local su="$pdir/schedutil"
    [ -d "$su" ] || return 0
    local hi_freq
    hi_freq="$(pick_freq_le "$pdir/scaling_available_frequencies" "$hi_target")"
    set_val "$up_us"   "$su/up_rate_limit_us"
    set_val "$down_us" "$su/down_rate_limit_us"
    set_val "$hi_freq" "$su/hispeed_freq"
    set_val "$hi_load" "$su/hispeed_load"
    set_val "$pl"      "$su/pl"
}

tune_stune() {
    local ta_boost="$1"
    local ta_idle="$2"
    local fg_boost="$3"
    local fg_idle="$4"
    local bg_boost="$5"
    set_val "$ta_boost" "/dev/stune/top-app/schedtune.boost"
    set_val "$ta_idle"  "/dev/stune/top-app/schedtune.prefer_idle"
    set_val "$fg_boost" "/dev/stune/foreground/schedtune.boost"
    set_val "$fg_idle"  "/dev/stune/foreground/schedtune.prefer_idle"
    set_val "$bg_boost" "/dev/stune/background/schedtune.boost"
    set_val 0           "/dev/stune/background/schedtune.prefer_idle"
}

tune_gpu() {
    local req_min="$1"
    local req_max="$2"
    local boost="$3"
    local no_nap="$4"
    local gavail="$GPU_DF/available_frequencies"
    local gmin gmax
    gmin="$(pick_freq_ge "$gavail" "$req_min")"
    gmax="$(pick_freq_le "$gavail" "$req_max")"
    [ "$gmin" -gt "$gmax" ] 2>/dev/null && gmin="$gmax"
    set_val "msm-adreno-tz" "$GPU_DF/governor"
    set_val "$gmax"         "$GPU_DF/max_freq"
    set_val "$gmin"         "$GPU_DF/min_freq"
    set_val "$gmax"         "$GPU_DF/max_freq"
    set_val "$boost"        "$GPU_DF/adrenoboost"
    set_val "$no_nap"       "$GPU_DIR/force_no_nap"
}

tune_bus_bw() {
    local boost_ms="$1"
    local d
    for d in /sys/class/devfreq/*cpu-cpu-ddr-bw* /sys/class/devfreq/*cpu*-ddr-lat*; do
        [ -d "$d" ] || continue
        set_val "$boost_ms" "$d/mem_latency/ratio_ceil"
    done
    # Keep Thermal/Cooling limits enabled
    set_val 0 "$GPU_DIR/throttling"
    set_val 1 "$GPU_DIR/thermal_pwrlevel"
}

case "$action" in
    init)
        # Ensure all 8 cores online and base schedutil initialized once
        for c in /sys/devices/system/cpu/cpu[0-7]/online; do
            set_val 1 "$c"
        done
        for q in /sys/block/mmcblk0/queue /sys/block/sda/queue; do
            [ -d "$q" ] || continue
            set_val 128 "$q/read_ahead_kb"
            set_val 0   "$q/iostats"
        done
        action="balance"
        ;;
esac

case "$action" in
    powersave)
        # Hemat daya harian: Silver ringan, Gold dibatasi ke mid-OPP efisiensi, no idle boost
        tune_schedutil "$P0" 2000 10000 1190400 90 0
        tune_schedutil "$P4" 4000 8000  1344000 92 0
        policy_bounds  "$P0" 300000  1516800
        policy_bounds  "$P4" 300000  1766400
        tune_stune     0 0 0 0 -10
        tune_gpu       320000000 600000000 0 0
        tune_bus_bw    400
        ;;

    balance)
        # Responsif + adem untuk sosial media, multitasking, dan hotspot
        tune_schedutil "$P0" 1000 15000 1344000 85 1
        tune_schedutil "$P4" 1500 12000 1766400 85 1
        policy_bounds  "$P0" 300000  1900800
        policy_bounds  "$P4" 300000  2208000
        tune_stune     5 1 0 1 -5
        tune_gpu       320000000 785000000 1 0
        tune_bus_bw    300
        ;;

    performance)
        # Gaming stabil & UI mulus tanpa terlalu cepat throttling
        tune_schedutil "$P0" 500 20000 1516800 80 1
        tune_schedutil "$P4" 500 16000 2016000 80 1
        policy_bounds  "$P0" 691200  1900800
        policy_bounds  "$P4" 768000  2400000
        tune_stune     15 1 5 1 0
        tune_gpu       320000000 1114800000 2 0
        tune_bus_bw    200
        ;;

    fast)
        # Peak burst / benchmark / load berat maksimal (mengikuti speed-bin SoC)
        tune_schedutil "$P0" 500 30000 1804800 75 1
        tune_schedutil "$P4" 500 25000 2400000 75 1
        policy_bounds  "$P0" 1190400 9999999
        policy_bounds  "$P4" 1056000 9999999
        tune_stune     30 1 10 1 0
        tune_gpu       465000000 9999999999 3 1
        tune_bus_bw    150
        ;;

    pedestal)
        # Charging / Docked pedestal: jaga performa tetap rata & hindari spike panas ekstra
        tune_schedutil "$P0" 1000 16000 1516800 82 1
        tune_schedutil "$P4" 1000 16000 1900800 82 1
        policy_bounds  "$P0" 691200  1900800
        policy_bounds  "$P4" 691200  2208000
        tune_stune     10 1 0 1 0
        tune_gpu       320000000 900000000 1 0
        tune_bus_bw    250
        ;;
esac

exit 0
