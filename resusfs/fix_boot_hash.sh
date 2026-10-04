#!/system/bin/sh
# fix_boot_hash.sh - Spoof AVB/vbmeta abnormal boot state untuk lolos Native Detector
# Jalankan via root shell atau letakkan di /data/adb/service.d/ (chmod 755)

# Tunggu boot selesai
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# Fungsi resetprop aman tanpa audit SELinux
sp() {
    if command -v resetprop >/dev/null 2>&1; then
        resetprop -n "$1" "$2" 2>/dev/null || resetprop "$1" "$2"
    else
        setprop "$1" "$2"
    fi
}

del_prop() {
    if command -v resetprop >/dev/null 2>&1; then
        resetprop -n --delete "$1" 2>/dev/null || resetprop --delete "$1" 2>/dev/null || true
    fi
}

# 1. Hapus indikator abnormal / boot error
del_prop ro.boot.verifiedbooterror
del_prop ro.boot.verifyerrorpart
del_prop ro.boot.vbmeta.device_state_error

# 2. Spoof Bootloader & Verified Boot State ke GREEN / LOCKED
sp ro.boot.verifiedbootstate "green"
sp ro.boot.vbmeta.device_state "locked"
sp ro.boot.flash.locked "1"
sp ro.boot.warranty_bit "0"

# 3. Auto-detect & Spoof AVB vbmeta digest resmi (SHA-256)
# Cari digest asli dari partisi vbmeta jika ada, fallback ke kalkulasi SHA-256 partisi
DIGEST=""
if [ -e "/dev/block/by-name/vbmeta" ]; then
    # Hitung sha256 murni dari partisi vbmeta device sendiri
    DIGEST="$(sha256sum /dev/block/by-name/vbmeta 2>/dev/null | awk '{print $1}')"
elif [ -e "/dev/block/bootdevice/by-name/vbmeta" ]; then
    DIGEST="$(sha256sum /dev/block/bootdevice/by-name/vbmeta 2>/dev/null | awk '{print $1}')"
fi

# Jika tidak terbaca dari block, ambil dari properti sistem saat ini
if [ -z "$DIGEST" ] || [ ${#DIGEST} -ne 64 ]; then
    DIGEST="$(getprop ro.boot.vbmeta.digest)"
fi

# Fallback terakhir jika sistem kosong total: generate 64 hex standar
if [ -z "$DIGEST" ] || [ ${#DIGEST} -ne 64 ]; then
    DIGEST="a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
fi

sp ro.boot.vbmeta.digest "$DIGEST"
sp ro.boot.vbmeta.digest_state "valid"
sp ro.boot.vbmeta.hash_state "valid"

# 4. Spoof cmdline / bootconfig parameter via kernel prop mirror
sp ro.bootmode "normal"
sp ro.boot.mode "normal"
sp ro.boot.bootreason "reboot"

echo "[+] Boot state & vbmeta digest spoofed to normal green/locked"
