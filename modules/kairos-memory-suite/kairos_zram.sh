#!/system/bin/sh
# Kairos Engine - Unified ZRAM, Swapfile, Writeback & VM Helper (Android 13-16 / Linux 4.19+)
# Single entry point invoked by service.sh at boot and WebUI at runtime.

MODDIR=${0%/*}
WB_IMG="/data/adb/kairos_writeback.img"
WB_PROP="persist.kairos.wb_loop"
SWAP_IMG="/data/adb/kairos_swapfile"
SWAP_PROP="persist.kairos.swap_loop"

clamp_int() {
  val="$1"; lo="$2"; hi="$3"; def="$4"
  case "$val" in
    ''|*[!0-9]*) printf '%s\n' "$def"; return ;;
  esac
  [ "$val" -lt "$lo" ] && val="$lo"
  [ "$val" -gt "$hi" ] && val="$hi"
  printf '%s\n' "$val"
}

clamp_signed() {
  val="$1"; lo="$2"; hi="$3"; def="$4"
  case "$val" in
    ''|-) printf '%s\n' "$def"; return ;;
    -*[0-9])
      digits="${val#-}"
      case "$digits" in *[!0-9]*|'') printf '%s\n' "$def"; return ;; esac
      ;;
    *[!0-9]*) printf '%s\n' "$def"; return ;;
  esac
  [ "$val" -lt "$lo" ] && val="$lo"
  [ "$val" -gt "$hi" ] && val="$hi"
  printf '%s\n' "$val"
}

write_node() {
  val="$1"; path="$2"
  [ -e "$path" ] || return 1
  chmod 664 "$path" 2>/dev/null || true
  printf '%s' "$val" > "$path" 2>/dev/null
}

bytes_from_size() {
  raw="$1"
  case "$raw" in
    *G|*g) n="${raw%[Gg]}"; echo $(( ${n:-0} * 1073741824 )) ;;
    *M|*m) n="${raw%[Mm]}"; echo $(( ${n:-0} * 1048576 )) ;;
    *[!0-9]*|'') echo 0 ;;
    *) echo "$raw" ;;
  esac
}

find_free_loop() {
  losetup -f 2>/dev/null && return 0
  for i in $(seq 0 63); do
    node="/dev/block/loop$i"
    [ -e "$node" ] || continue
    if ! losetup "$node" >/dev/null 2>&1; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

optimize_loop_queue() {
  loop_dev="$1"
  base="${loop_dev##*/}"
  q="/sys/block/$base/queue"
  [ -d "$q" ] || return 0
  write_node "mq-deadline" "$q/scheduler"
  write_node 4096 "$q/max_sectors_kb"
  write_node 4096 "$q/read_ahead_kb"
  write_node 256 "$q/nr_requests"
  write_node 0 "$q/nomerges"
}

detach_loop_by_file() {
  prop_key="$1"
  img_path="$2"
  old_loop=$(getprop "$prop_key" 2>/dev/null)
  if [ -n "$old_loop" ]; then
    swapoff "$old_loop" 2>/dev/null || true
    losetup -d "$old_loop" 2>/dev/null || true
    setprop "$prop_key" "" 2>/dev/null || true
  fi
  if [ -f "$img_path" ] && command -v losetup >/dev/null 2>&1; then
    for dev in $(losetup -a 2>/dev/null | grep "${img_path##*/}" | cut -d: -f1); do
      swapoff "$dev" 2>/dev/null || true
      losetup -d "$dev" 2>/dev/null || true
    done
  fi
}

setup_backing_dev() {
  wb_mb=$(clamp_int "$1" 256 4096 1024)
  [ -e /sys/block/zram0/backing_dev ] || return 1

  detach_loop_by_file "$WB_PROP" "$WB_IMG"
  want_bytes=$((wb_mb * 1048576))
  curr_bytes=0
  [ -f "$WB_IMG" ] && curr_bytes=$(wc -c < "$WB_IMG" 2>/dev/null || echo 0)
  if [ ! -f "$WB_IMG" ] || [ "$curr_bytes" -ne "$want_bytes" ]; then
    rm -f "$WB_IMG"
    fallocate -l "$want_bytes" "$WB_IMG" 2>/dev/null \
      || dd if=/dev/zero of="$WB_IMG" bs=1048576 count="$wb_mb" >/dev/null 2>&1 \
      || return 1
    chmod 600 "$WB_IMG" 2>/dev/null
  fi

  loop_dev=$(find_free_loop)
  [ -n "$loop_dev" ] || return 1
  losetup "$loop_dev" "$WB_IMG" >/dev/null 2>&1 || return 1
  setprop "$WB_PROP" "$loop_dev" 2>/dev/null || true
  optimize_loop_queue "$loop_dev"

  if ! printf '%s' "$loop_dev" > /sys/block/zram0/backing_dev 2>/dev/null; then
    detach_loop_by_file "$WB_PROP" "$WB_IMG"
    return 1
  fi
  write_node 0 /sys/block/zram0/writeback_limit_enable
  return 0
}

apply_vm_tunables() {
  swappiness=$(clamp_int "$1" 0 200 100)
  vfs_pressure=$(clamp_int "$2" 10 200 100)
  wm_scale=$(clamp_int "$3" 5 100 15)
  comp_proact=$(clamp_int "$4" 0 100 20)

  write_node "$swappiness" /proc/sys/vm/swappiness
  write_node "$vfs_pressure" /proc/sys/vm/vfs_cache_pressure
  write_node "$wm_scale" /proc/sys/vm/watermark_scale_factor
  write_node 0 /proc/sys/vm/watermark_boost_factor
  write_node 0 /proc/sys/vm/page-cluster
  write_node 1 /proc/sys/vm/compact_unevictable_allowed
  write_node 5 /proc/sys/vm/dirty_background_ratio
  write_node 10 /proc/sys/vm/dirty_ratio
  write_node 1 /proc/sys/vm/overcommit_memory
  write_node 100 /proc/sys/vm/overcommit_ratio
  write_node 0 /proc/sys/vm/oom_kill_allocating_task
  write_node 0 /proc/sys/vm/panic_on_oom
  write_node "$comp_proact" /proc/sys/vm/compaction_proactiveness
  write_node true /sys/kernel/mm/swap/vma_ra_enabled

  if [ -r /proc/sys/vm/min_free_kbytes ]; then
    cur_min=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null || echo 0)
    [ "${cur_min:-0}" -lt 20480 ] && write_node 20480 /proc/sys/vm/min_free_kbytes
  fi
}

cmd_vm() {
  swappiness=$(clamp_int "${1:-100}" 0 200 100)
  vfs_pressure=$(clamp_int "${2:-100}" 10 200 100)
  wm_scale=$(clamp_int "${3:-15}" 5 100 15)
  comp_proact=$(clamp_int "${4:-20}" 0 100 20)

  apply_vm_tunables "$swappiness" "$vfs_pressure" "$wm_scale" "$comp_proact"
  echo "VM_OK swappiness=${swappiness} vfs=${vfs_pressure} wm=${wm_scale} comp=${comp_proact}"
}

cmd_zram() {
  zram_size="${1:-3072M}"
  want_algo="${2:-zstd}"
  want_wb=$(clamp_int "${3:-0}" 0 1 0)
  wb_mb=$(clamp_int "${4:-1024}" 256 4096 1024)

  if [ ! -e /dev/block/zram0 ] && [ -e /sys/class/zram-control/hot_add ]; then
    cat /sys/class/zram-control/hot_add >/dev/null 2>&1 || true
  fi
  [ -e /sys/block/zram0/disksize ] || { echo "ZRAM_MISSING"; return 1; }

  want_bytes=$(bytes_from_size "$zram_size")
  [ "$want_bytes" -gt 0 ] || { echo "ZRAM_BAD_SIZE"; return 1; }

  curr_bytes=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
  curr_algo=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null)
  curr_bd=$(cat /sys/block/zram0/backing_dev 2>/dev/null | tr -d ' \n')
  have_swap=0
  grep -q '/zram0' /proc/swaps 2>/dev/null && have_swap=1

  wb_match=1
  if [ -e /sys/block/zram0/backing_dev ]; then
    if [ "$want_wb" -eq 1 ] && { [ -z "$curr_bd" ] || [ "$curr_bd" = "none" ]; }; then
      wb_match=0
    elif [ "$want_wb" -eq 0 ] && [ -n "$curr_bd" ] && [ "$curr_bd" != "none" ]; then
      wb_match=0
    fi
  fi

  diff=$((want_bytes - ${curr_bytes:-0}))
  [ "$diff" -lt 0 ] && diff=$((-diff))

  if [ "$have_swap" -eq 1 ] && [ "$diff" -le 33554432 ] && [ "$curr_algo" = "$want_algo" ] && [ "$wb_match" -eq 1 ]; then
    echo "ZRAM_UNCHANGED"
    return 0
  fi

  swapoff /dev/block/zram0 2>/dev/null || true
  detach_loop_by_file "$WB_PROP" "$WB_IMG"
  echo 1 > /sys/block/zram0/reset 2>/dev/null || true

  # Algorithm MUST be written after reset and BEFORE disksize on 4.19
  avail_algos=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)
  selected_algo="$want_algo"
  if ! printf '%s' "$avail_algos" | grep -qw "$selected_algo"; then
    for fallback in zstd lz4 lzo-rle lzo; do
      if printf '%s' "$avail_algos" | grep -qw "$fallback"; then
        selected_algo="$fallback"
        break
      fi
    done
  fi
  [ -n "$selected_algo" ] && echo "$selected_algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  [ -e /sys/block/zram0/max_comp_streams ] && echo 4 > /sys/block/zram0/max_comp_streams 2>/dev/null || true

  if [ "$want_wb" -eq 1 ]; then
    setup_backing_dev "$wb_mb" || echo "WB_UNSUPPORTED"
  else
    rm -f "$WB_IMG" 2>/dev/null || true
  fi

  echo "$want_bytes" > /sys/block/zram0/disksize 2>/dev/null || { echo "ZRAM_DISKSIZE_FAIL"; return 1; }
  mkswap /dev/block/zram0 >/dev/null 2>&1 || { echo "ZRAM_MKSWAP_FAIL"; return 1; }
  swapon /dev/block/zram0 -p 0 >/dev/null 2>&1 || swapon /dev/block/zram0 >/dev/null 2>&1

  if grep -q '/zram0' /proc/swaps 2>/dev/null; then
    echo "ZRAM_OK algo=${selected_algo} size=${zram_size} wb=${want_wb}"
    return 0
  fi
  echo "ZRAM_FAIL"
  return 1
}

cmd_swapfile() {
  swap_mb=$(clamp_int "${1:-0}" 0 8192 0)
  swap_prio=$(clamp_signed "${2:--1}" -10 32767 -1)

  swapoff "$SWAP_IMG" 2>/dev/null || true
  detach_loop_by_file "$SWAP_PROP" "$SWAP_IMG"

  if [ "$swap_mb" -eq 0 ]; then
    rm -f "$SWAP_IMG" 2>/dev/null || true
    echo "SWAP_OFF"
    return 0
  fi

  want_bytes=$((swap_mb * 1048576))
  curr_bytes=0
  [ -f "$SWAP_IMG" ] && curr_bytes=$(wc -c < "$SWAP_IMG" 2>/dev/null || echo 0)
  if [ ! -f "$SWAP_IMG" ] || [ "$curr_bytes" -ne "$want_bytes" ]; then
    rm -f "$SWAP_IMG"
    fallocate -l "$want_bytes" "$SWAP_IMG" 2>/dev/null \
      || dd if=/dev/zero of="$SWAP_IMG" bs=1048576 count="$swap_mb" >/dev/null 2>&1 \
      || { echo "SWAP_ALLOC_FAIL"; return 1; }
    chmod 600 "$SWAP_IMG" 2>/dev/null
  fi

  target_dev="$SWAP_IMG"
  loop_dev=$(find_free_loop)
  if [ -n "$loop_dev" ] && losetup "$loop_dev" "$SWAP_IMG" >/dev/null 2>&1; then
    setprop "$SWAP_PROP" "$loop_dev" 2>/dev/null || true
    optimize_loop_queue "$loop_dev"
    target_dev="$loop_dev"
  fi

  mkswap "$target_dev" >/dev/null 2>&1 || { echo "SWAP_MKSWAP_FAIL"; return 1; }
  swapon "$target_dev" -p "$swap_prio" >/dev/null 2>&1 || swapon "$target_dev" >/dev/null 2>&1 || {
    echo "SWAP_ON_FAIL"
    return 1
  }
  echo "SWAP_OK mb=${swap_mb} prio=${swap_prio} dev=${target_dev}"
}

cmd_apply() {
  cmd_vm "${5:-100}" "${6:-100}" "${7:-15}" "${8:-20}"
  cmd_zram "${1:-3072M}" "${2:-zstd}" "${3:-0}" "${4:-1024}"
}

cmd_compact() {
  level="${1:-soft}"
  [ -e /sys/block/zram0/compact ] && echo 1 > /sys/block/zram0/compact 2>/dev/null || true

  if [ -e /sys/block/zram0/backing_dev ]; then
    bd=$(cat /sys/block/zram0/backing_dev 2>/dev/null | tr -d ' \n')
    if [ -n "$bd" ] && [ "$bd" != "none" ]; then
      [ -e /sys/block/zram0/idle ] && echo all > /sys/block/zram0/idle 2>/dev/null || true
      [ -e /sys/block/zram0/writeback ] && echo idle > /sys/block/zram0/writeback 2>/dev/null || true
    fi
  fi

  if [ "$level" = "hard" ]; then
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  fi
  echo "COMPACT_OK"
}

cmd_status() {
  awk '/^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree):/ {
    k=toupper($1); sub(/:/, "", k); print "MEM_" k "=" $2
  }' /proc/meminfo 2>/dev/null

  mm=$(cat /sys/block/zram0/mm_stat 2>/dev/null)
  printf 'MM_STAT=%s\n' "$mm"

  alg_raw=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)
  alg_cur=$(printf '%s' "$alg_raw" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
  printf 'COMP_ALGO=%s\n' "$alg_cur"
  printf 'ALGO_AVAIL=%s\n' "$(printf '%s' "$alg_raw" | tr -d '[]')"
  printf 'DISK_BYTES=%s\n' "$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)"

  if [ -e /sys/block/zram0/backing_dev ]; then
    printf 'WB_SUPPORTED=1\n'
    printf 'BACKING_DEV=%s\n' "$(cat /sys/block/zram0/backing_dev 2>/dev/null | tr -d '\n')"
    printf 'BD_STAT=%s\n' "$(cat /sys/block/zram0/bd_stat 2>/dev/null | tr -s ' ')"
  else
    printf 'WB_SUPPORTED=0\n'
    printf 'BACKING_DEV=none\n'
    printf 'BD_STAT=\n'
  fi

  swap_line=$(grep -v '/zram' /proc/swaps 2>/dev/null | awk 'NR>1 || $1 ~ /\// {if ($1 !~ /^Filename/) {print $1, $3, $4, $5; exit}}')
  printf 'SWAPFILE_LINE=%s\n' "$swap_line"

  printf 'MGLRU=%s\n' "$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null | tr -d '\n')"
  printf 'PSI_MEM=%s\n' "$(head -1 /proc/pressure/memory 2>/dev/null | tr -d '\n')"
  printf 'VM_SWAPPINESS=%s\n' "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
  printf 'VM_VFS_PRESSURE=%s\n' "$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)"
  printf 'VM_WM_SCALE=%s\n' "$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
  printf 'VM_COMP_PROACT=%s\n' "$(cat /proc/sys/vm/compaction_proactiveness 2>/dev/null)"
  printf 'BG_LIMIT=%s\n' "$(getprop ro.sys.fw.bg_apps_limit 2>/dev/null)"
  printf 'FREEZER=%s\n' "$(device_config get activity_manager_native_boot use_freezer 2>/dev/null)"
  printf 'USAP=%s\n' "$(getprop persist.device_config.runtime_native.usap_pool_enabled 2>/dev/null)"
  printf 'ANIM_SCALE=%s\n' "$(settings get global window_animation_scale 2>/dev/null)"

  printf 'PWR_TEMP=%s\n' "$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
  printf 'PWR_CURRENT=%s\n' "$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)"
  printf 'PWR_VOLTAGE=%s\n' "$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)"
  printf 'PWR_STATUS=%s\n' "$(cat /sys/class/power_supply/battery/status 2>/dev/null)"
  printf 'PWR_TYPE=%s\n' "$(cat /sys/class/power_supply/usb/real_type 2>/dev/null)"
  printf 'PWR_CAP=%s\n' "$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)"
  printf 'PWR_CE=%s\n' "$(cat /sys/class/power_supply/battery/charging_enabled 2>/dev/null)"
  printf 'PWR_IS=%s\n' "$(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null)"
}

case "$1" in
  apply) shift; cmd_apply "$@" ;;
  vm) shift; cmd_vm "$@" ;;
  zram) shift; cmd_zram "$@" ;;
  swapfile) shift; cmd_swapfile "$@" ;;
  compact) shift; cmd_compact "$@" ;;
  status) cmd_status ;;
  *) echo "Usage: $0 {apply|vm|zram|swapfile|compact|status}"; exit 1 ;;
esac
