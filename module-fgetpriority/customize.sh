#!/system/bin/sh
SKIPUNZIP=0

# Personal non-GKI build (fog/cirno Kairos). Only 4.19.x kernels may install this.
ui_print "- fgetpriority v0.0.5 (4.19 non-GKI build)"

REL="$(uname -r)"
case "$REL" in
    4.19.*) ui_print "- Kernel $REL: 4.19.x OK" ;;
    *)
        ui_print "! Kernel $REL bukan 4.19.x — install dibatalkan."
        ui_print "! Jika SUSFS uname spoof aktif, matikan dulu lalu install ulang."
        exit 1
        ;;
esac

SRC="$MODPATH/ko/fog-4.19_arm64_fgetpriority.ko"
if [ ! -f "$SRC" ]; then
    ui_print "! ko/fog-4.19_arm64_fgetpriority.ko tidak ada dalam paket!"
    exit 1
fi

cp -f "$SRC" "$MODPATH/ko/fgetpriority.ko" || { ui_print "! Gagal menyiapkan ko."; exit 1; }
rm -f "$MODPATH/ko/fog-4.19_arm64_fgetpriority.ko"
ui_print "- $(uname -r) -> fgetpriority.ko (4.19 non-GKI)"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in "$MODPATH"/*.sh; do chmod 0755 "$f"; done
[ -f "$MODPATH/ko/fgetpriority.ko" ] && chmod 0644 "$MODPATH/ko/fgetpriority.ko"
