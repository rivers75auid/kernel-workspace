#!/system/bin/sh
# ==============================================================
# Potato Suite Runtime Optimizer (Android 16 / SM6225)
# Wait for Android system boot completion
# ==============================================================
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 2
done

# Tunggu ROM post_boot (init.qcom.post_boot.sh) selesai agar tidak ter-override
sleep 10

# ==============================================================
# 1. CPU Scheduling: EAS & Schedutil Tuning (Smooth & Responsive)
# ==============================================================
# Reset WALT boost and uninitialized core_ctl thresholds
echo 0 > /proc/sys/kernel/sched_boost 2>/dev/null || true
for cc in /sys/devices/system/cpu/cpu*/core_ctl; do
  [ -d "$cc" ] || continue
  echo 68 68 68 68 > "$cc/busy_up_thres" 2>/dev/null || true
  echo 40 40 40 40 > "$cc/busy_down_thres" 2>/dev/null || true
done

for gov in /sys/devices/system/cpu/cpufreq/policy*/schedutil; do
  [ -d "$gov" ] || continue
  echo 1000 > "$gov/up_rate_limit_us" 2>/dev/null || true
  echo 4000 > "$gov/down_rate_limit_us" 2>/dev/null || true
  echo 0 > "$gov/hispeed_freq" 2>/dev/null || true
  echo 0 > "$gov/rtg_boost_freq" 2>/dev/null || true
done

# Schedtune & WALT Boost untuk Kryo 265 Gold (4x A73)
if [ -d "/dev/stune/top-app" ]; then
  echo 15 > /dev/stune/top-app/schedtune.boost 2>/dev/null || true
  echo 1 > /dev/stune/top-app/schedtune.prefer_idle 2>/dev/null || true
fi
if [ -d "/dev/stune/background" ]; then
  echo 0 > /dev/stune/background/schedtune.boost 2>/dev/null || true
  echo 0 > /dev/stune/background/schedtune.prefer_idle 2>/dev/null || true
fi
if [ -d "/dev/cpuset/background" ]; then
  echo 0-3 > /dev/cpuset/background/cpus 2>/dev/null || true
fi
if [ -d "/dev/cpuset/top-app" ]; then
  echo 0-7 > /dev/cpuset/top-app/cpus 2>/dev/null || true
fi

# ==============================================================
# 2. Storage I/O: UFS 2.2 / Flash SCSI Queue + Anxiety Scheduler
# ==============================================================
for queue in /sys/block/*/queue; do
  [ -d "$queue" ] || continue
  if grep -q "anxiety" "$queue/scheduler"; then
    echo anxiety > "$queue/scheduler" 2>/dev/null || true
  elif grep -q "bfq" "$queue/scheduler"; then
    echo bfq > "$queue/scheduler" 2>/dev/null || true
    echo 1 > "$queue/iosched/low_latency" 2>/dev/null || true
    echo 0 > "$queue/iosched/slice_idle" 2>/dev/null || true
  fi
  echo 512 > "$queue/read_ahead_kb" 2>/dev/null || true
  # UFS 2.2 Full-Duplex SCSI Queue & Interrupt Affinity
  echo 2 > "$queue/rq_affinity" 2>/dev/null || true
  echo 0 > "$queue/iostats" 2>/dev/null || true
  echo 64 > "$queue/nr_requests" 2>/dev/null || true
  echo 0 > "$queue/add_random" 2>/dev/null || true
done

# ==============================================================
# 3. Multi-Gen LRU (MGLRU) Aggressive Tiering
# ==============================================================
if [ -f "/sys/kernel/mm/lru_gen/enabled" ]; then
  echo 7 > /sys/kernel/mm/lru_gen/enabled
  echo 1000 > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null || true
fi

# ==============================================================
# 4. Kernel Samepage Merging (KSM) - Deduplikasi RAM ART
# ==============================================================
if [ -d "/sys/kernel/mm/ksm" ]; then
  echo 1 > /sys/kernel/mm/ksm/run
  echo 200 > /sys/kernel/mm/ksm/pages_to_scan
  echo 500 > /sys/kernel/mm/ksm/sleep_millisecs
  echo 1 > /sys/kernel/mm/ksm/deferred_timer 2>/dev/null || true
fi

# ==============================================================
# 5. ZRAM Dynamic Reallocation (4GB ZSTD + DEDUP)
# ==============================================================
if [ -b "/dev/block/zram0" ]; then
  swapoff /dev/block/zram0 2>/dev/null || true
  echo 1 > /sys/block/zram0/reset 2>/dev/null || true
  echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  echo 4294967296 > /sys/block/zram0/disksize 2>/dev/null || true
  mkswap /dev/block/zram0 2>/dev/null || true
  swapon /dev/block/zram0 -p 32758 2>/dev/null || true
fi

# ==============================================================
# 6. Virtual Memory, VFS Choke Prevention & I/O Tuning
# ==============================================================
echo 0 > /proc/sys/vm/page-cluster
echo 160 > /proc/sys/vm/swappiness
echo 70 > /proc/sys/vm/vfs_cache_pressure
echo 5 > /proc/sys/vm/dirty_ratio
echo 2 > /proc/sys/vm/dirty_background_ratio
echo 200 > /proc/sys/vm/dirty_expire_centisecs
echo 300 > /proc/sys/vm/dirty_writeback_centisecs
echo 0 > /proc/sys/vm/watermark_boost_factor
echo 125 > /proc/sys/vm/watermark_scale_factor
echo 24300 > /proc/sys/vm/extra_free_kbytes
echo 11520 > /proc/sys/vm/min_free_kbytes
echo 50 > /proc/sys/vm/compaction_proactiveness 2>/dev/null || true

# ==============================================================
# 7. Process Reclaim Background Compression
# ==============================================================
if [ -d "/sys/module/process_reclaim/parameters" ]; then
  echo 1 > /sys/module/process_reclaim/parameters/enable_process_reclaim
  echo 50 > /sys/module/process_reclaim/parameters/pressure_min
  echo 85 > /sys/module/process_reclaim/parameters/pressure_max
  echo 512 > /sys/module/process_reclaim/parameters/per_swap_size
  echo 10 > /sys/module/process_reclaim/parameters/swap_opt_eff
fi

# ==============================================================
# 8. Android 16 SurfaceFlinger, LMKD & Real-Time UI Scheduling
# ==============================================================
# Gunakan resetprop jika tersedia agar kompatibel dengan SELinux & tidak memicu audit
SETPROP="setprop"
if command -v resetprop >/dev/null 2>&1; then
  SETPROP="resetprop -n"
fi

$SETPROP sys.use_fifo_ui 1
$SETPROP ro.lmk.kill_heaviest_task true
$SETPROP ro.lmk.use_psi true
$SETPROP ro.lmk.psi_complete_stall_ms 350
$SETPROP ro.lmk.psi_partial_stall_ms 100
$SETPROP ro.lmk.thrashing_limit 50
$SETPROP ro.lmk.thrashing_limit_decay 10
$SETPROP debug.sf.latch_unsignaled 1
$SETPROP debug.sf.disable_backpressure 1
$SETPROP debug.hwui.render_dirty_regions false
$SETPROP debug.hwui.use_buffer_age false

# ==============================================================
# 9. Network Bufferbloat Kill (Google BBR + FQ-CoDel)
# ==============================================================
echo fq_codel > /proc/sys/net/core/default_qdisc 2>/dev/null || true
echo bbr > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
