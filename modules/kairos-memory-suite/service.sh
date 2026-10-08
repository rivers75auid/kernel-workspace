#!/system/bin/sh
# Kairos Memory Management Suite - Boot Stage Service
# Enforces Scene-aligned memory retention & 60Hz frame pacing
MODDIR=${0%/*}

# 1. Tunggu sampai boot selesai penuh
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

# Beri jeda 3s agar script bawaan vendor/ROM (qcom power, extra_free_kbytes) selesai eksekusi
sleep 3

LOG="/cache/kairos_memory_suite.log"
echo "=== Kairos Memory Suite Started: $(date) ===" > $LOG

# ==============================================================
# 2. LMKD Shield (Melucuti Pemicu Kill Bawaan AOSP/Custom ROM)
# ==============================================================
# Kunci skor minimum kill watermark (nilai 1001 melumpuhkan breach kill)
resetprop ro.lmk.lowmem_min_oom_score 1001
# Larang bunuh app berat (cegah Chrome, Sosmed, Game langsung mati)
resetprop ro.lmk.kill_heaviest_task false
# Larang bunuh app dengan alasan swap tersisa sedikit
resetprop ro.lmk.swap_free_low_percentage 0
resetprop ro.lmk.swap_is_low_kill_enable 0
# Bolehkan pemakaian ZRAM hingga 100% kapasitas
resetprop ro.lmk.swap_util_max 100
# Alihkan deteksi ke PSI murni (bukan minfree MB fisik)
resetprop ro.lmk.use_psi true
resetprop ro.lmk.use_minfree_levels false
resetprop ro.lmk.psi_partial_stall_ms 250
resetprop ro.lmk.psi_complete_stall_ms 700
resetprop ro.lmk.thrashing_limit 100
resetprop ro.lmk.thrashing_limit_decay 10
# Naikkan batas background apps
resetprop ro.sys.fw.bg_apps_limit 64

# ==============================================================
# 3. Disable Phantom Process Killer & Buka Batas Cache Android
# ==============================================================
device_config put activity_manager max_cached_processes 64 2>/dev/null
device_config put activity_manager max_phantom_processes 64 2>/dev/null
device_config put activity_manager no_kill_cached_processes_post_boot_completed_duration_millis 2147483647 2>/dev/null
device_config put activity_manager max_empty_time_millis 2147483647 2>/dev/null
device_config put activity_manager kill_bg_restricted_cached_idle_settle_time 2147483647 2>/dev/null
device_config put activity_manager use_compaction false 2>/dev/null
device_config put activity_manager proactive_kills_enabled false 2>/dev/null
settings put global settings_enable_monitor_phantom_procs false 2>/dev/null

# ==============================================================
# 4. Kunci VM & ZRAM Tunables (Timpa Balik Skrip ROM)
# ==============================================================
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

# ==============================================================
# 5. Kunci 60Hz UI Schedutil Smoothing (Cegah Drop ke 300MHz)
# ==============================================================
echo 1000 > /sys/devices/system/cpu/cpufreq/policy0/schedutil/up_rate_limit_us 2>/dev/null
echo 20000 > /sys/devices/system/cpu/cpufreq/policy0/schedutil/down_rate_limit_us 2>/dev/null
echo 500 > /sys/devices/system/cpu/cpufreq/policy4/schedutil/up_rate_limit_us 2>/dev/null
echo 40000 > /sys/devices/system/cpu/cpufreq/policy4/schedutil/down_rate_limit_us 2>/dev/null

# Schedtune Headroom untuk UI Thread
echo 5 > /dev/stune/top-app/schedtune.boost 2>/dev/null
echo 1 > /dev/stune/top-app/schedtune.prefer_idle 2>/dev/null

# ==============================================================
# 6. Restart LMKD Sekali Agar Mengadopsi Konfigurasi Baru
# ==============================================================
killall lmkd 2>/dev/null

echo "=== Kairos Memory Suite Applied Successfully ===" >> $LOG
echo "ZRAM Used: $(cat /proc/swaps | grep zram0 | awk '{print $4}')" >> $LOG
