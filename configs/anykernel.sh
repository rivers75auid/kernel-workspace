### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## Custom Kairos Kernel for Redmi 10C (fog / wind / rain / sm6225)

### AnyKernel setup
# global properties
properties() { '
kernel.string=Kairos Kernel for Redmi 10C (fog)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=fog
device.name2=wind
device.name3=rain
device.name4=sm6225
device.name5=Redmi 10C
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=/dev/block/by-name/boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;

# Plant Kairos VM & LMKD tuning into boot ramdisk (Runs on early-boot before LMKD starts)
# Ensures maximum ZRAM utilization (1.4GB+) and prevents background app kills on any Custom ROM
if [ -d $RAMDISK ]; then
  cat << 'EOF' > $RAMDISK/init.kairos.rc
on early-init
    # VM Tunables for Fast ZSTD ZRAM & Low Watermark
    write /proc/sys/vm/swappiness 160
    write /proc/sys/vm/page-cluster 0
    write /proc/sys/vm/watermark_scale_factor 10
    write /proc/sys/vm/watermark_boost_factor 0
    write /proc/sys/vm/vfs_cache_pressure 100
    write /proc/sys/vm/dirty_background_ratio 5
    write /proc/sys/vm/dirty_ratio 10
    write /proc/sys/vm/compact_unevictable_allowed 1
    write /proc/sys/vm/panic_on_oom 0

on property:sys.boot_completed=1
    # Smooth Schedutil Rate Limits (Fix 60Hz UI Sawtooth Drops)
    write /sys/devices/system/cpu/cpufreq/policy0/schedutil/up_rate_limit_us 1000
    write /sys/devices/system/cpu/cpufreq/policy0/schedutil/down_rate_limit_us 20000
    write /sys/devices/system/cpu/cpufreq/policy4/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpufreq/policy4/schedutil/down_rate_limit_us 40000

    # LMKD Memory Pressure & Watermark Protection (Scene-Aligned)
    setprop persist.device_config.lmkd_native.kill_heaviest_task false
    setprop persist.device_config.lmkd_native.lowmem_min_oom_score 1001
    setprop persist.device_config.lmkd_native.psi_partial_stall_ms 250
    setprop persist.device_config.lmkd_native.psi_complete_stall_ms 700
    setprop persist.device_config.lmkd_native.thrashing_limit 100
    setprop persist.device_config.lmkd_native.thrashing_limit_decay 10
    setprop persist.device_config.lmkd_native.swap_util_max 100

    # Disable Phantom Process Killer & Expand Cached Process Pool
    setprop persist.device_config.activity_manager.max_cached_processes 64
    setprop persist.device_config.activity_manager.max_phantom_processes 64
    setprop persist.device_config.activity_manager.proactive_kills_enabled false
    setprop persist.sys.fflag.override.settings_enable_monitor_phantom_procs false

    # Schedtune UI Headroom
    write /dev/stune/top-app/schedtune.boost 5
    write /dev/stune/top-app/schedtune.prefer_idle 1
EOF

  # Import init.kairos.rc in main init.rc if not present
  if [ -f $RAMDISK/init.rc ]; then
    grep -q "import /init.kairos.rc" $RAMDISK/init.rc || sed -i '1iimport /init.kairos.rc' $RAMDISK/init.rc
  fi
fi

# write new kernel image and dtb
write_boot;
## end boot install
