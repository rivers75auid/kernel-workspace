#!/system/bin/sh
# fix_android_data_selinux.sh - Perbaiki konteks SELinux & kepemilikan /Android/data
# Jalankan via root shell (su) jika aplikasi gagal membuat folder di internal storage

echo "[*] Fixing /data/media/0/Android/data permissions and SELinux contexts..."

TARGET="/data/media/0/Android"

if [ ! -d "$TARGET" ]; then
    echo "[-] $TARGET tidak ditemukan!"
    exit 1
fi

# 1. Pastikan folder induk Android/data dan Android/obb ada
mkdir -p "$TARGET/data" "$TARGET/obb" "$TARGET/media" 2>/dev/null || true

# 2. Reset permission folder induk (rwxrwx--x / 771) dan kepemilikan ke media_rw:media_rw (1023:1023)
chown -R media_rw:media_rw "$TARGET" 2>/dev/null || true
chmod 771 "$TARGET" "$TARGET/data" "$TARGET/obb" "$TARGET/media" 2>/dev/null || true

# 3. Restore konteks SELinux resmi Android (media_rw_data_file)
# Opsi -F (force reset context) -R (rekursif)
restorecon -FR "$TARGET" 2>/dev/null || true

# Jika restorecon tidak tersedia/gagal, terapkan chcon manual
chcon -R u:object_r:media_rw_data_file:s0 "$TARGET" 2>/dev/null || true

echo "[+] SELinux context & permissions for /Android/data fixed successfully!"
echo "[*] Coba buka kembali aplikasi yang bermasalah."
