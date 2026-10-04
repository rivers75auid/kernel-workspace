#!/system/bin/sh
# fix_shell_tmp_inode.sh - Reset /data/local/tmp inode ke 2 lewat native tmpfs
# Taruh di /data/adb/post-fs-data.d/ atau jalankan manual via root shell

TMPDIR="/data/local/tmp"

[ -d "$TMPDIR" ] || exit 0

# Cek jika sudah termount
if grep -q " $TMPDIR tmpfs " /proc/mounts; then
    exit 0
fi

# Native tmpfs: kernel beri inode 2 otomatis (lulus Duck Detector < 10000)
mount -t tmpfs -o mode=0771,uid=2000,gid=2000,nosuid,nodev tmpfs "$TMPDIR"
chcon u:object_r:shell_data_file:s0 "$TMPDIR"
