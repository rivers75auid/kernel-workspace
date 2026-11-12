#!/bin/bash
set -euo pipefail

cd "$GITHUB_WORKSPACE/kernel_source"

ENABLE_KSU="${1:-true}"
ENABLE_SUS="${2:-true}"
SUS_VER="${3:-v2.3.0}"
DEFCONFIG="${4:-vendor/fog-perf_defconfig}"
KSU_REF="${5:-516d3e87fbc986ccefdde2c2765f1700612441a9}"
FIRST_DEFCONFIG="$(echo "$DEFCONFIG" | awk '{print $1}')"
DEFCONFIG_PATH="arch/arm64/configs/$FIRST_DEFCONFIG"

if [ "$ENABLE_KSU" != "true" ]; then
    echo "===> ReSukiSU disabled (ENABLE_KSU=$ENABLE_KSU), skipping."
    exit 0
fi

KSU_DIR="$GITHUB_WORKSPACE/kernel_source/KernelSU"
KSU_REPO="https://github.com/ReSukiSU/ReSukiSU.git"

echo "===> Mengintegrasikan ReSukiSU (ref: $KSU_REF)..."
if [ ! -d "$KSU_DIR/.git" ]; then
    rm -rf "$KSU_DIR"
    case "$KSU_REF" in
        *[!0-9a-f]*|"")
            git clone --depth=1 -b "$KSU_REF" "$KSU_REPO" "$KSU_DIR"
            ;;
        *)
            if ! git clone --depth=1 -b "$KSU_REF" "$KSU_REPO" "$KSU_DIR" 2>/dev/null; then
                rm -rf "$KSU_DIR"
                echo "===> KSU_REF is a commit SHA: fetching $KSU_REF directly..."
                git init -q "$KSU_DIR"
                git -C "$KSU_DIR" remote add origin "$KSU_REPO"
                git -C "$KSU_DIR" fetch --depth=1 -q origin "$KSU_REF"
                git -C "$KSU_DIR" checkout -q --detach FETCH_HEAD
            fi
            ;;
    esac
fi

rm -rf drivers/kernelsu
ln -sfn "$KSU_DIR/kernel" drivers/kernelsu
test -f drivers/kernelsu/Kconfig || {
    echo "[-] ERROR: drivers/kernelsu/Kconfig does not exist!"
    ls -la drivers/kernelsu
    exit 1
}
echo "[+] Verified drivers/kernelsu/Kconfig exists."

if ! grep -q "kernelsu/" drivers/Makefile; then
    printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
fi

if ! grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
    awk '
        /^endmenu/ { last_match = NR }
        { lines[NR] = $0 }
        END {
            if (!last_match) {
                print "ERROR: no endmenu found in drivers/Kconfig" > "/dev/stderr"
                exit 1
            }
            for (i = 1; i <= NR; i++) {
                if (i == last_match) print "source \"drivers/kernelsu/Kconfig\""
                print lines[i]
            }
        }
    ' drivers/Kconfig > drivers/Kconfig.tmp && mv drivers/Kconfig.tmp drivers/Kconfig
fi

echo "===> Exporting non-static SELinux helpers for Non-GKI 4.19..."
sed -i 's/^static void security_dump_masked_av/void security_dump_masked_av/' security/selinux/ss/services.c || true
sed -i 's/^static void context_struct_compute_av/void context_struct_compute_av/' security/selinux/ss/services.c || true

if [ "$ENABLE_SUS" = "true" ]; then
    echo "===> Installing genuine SuSFS $SUS_VER backport for Linux 4.19..."
    SUSFS_SRC="$GITHUB_WORKSPACE/scripts/susfs_v230"
    test -f "$SUSFS_SRC/susfs.h" && test -f "$SUSFS_SRC/susfs_def.h" && test -f "$SUSFS_SRC/susfs.c" || {
        echo "[-] ERROR: Missing SuSFS v2.3.0 sources in $SUSFS_SRC"
        exit 1
    }

    cp -f "$SUSFS_SRC/susfs_def.h" include/linux/susfs_def.h
    cp -f "$SUSFS_SRC/susfs.h" include/linux/susfs.h
    cp -f "$SUSFS_SRC/susfs.c" fs/susfs.c
    sed -i "s/^#define SUSFS_VERSION .*/#define SUSFS_VERSION \"$SUS_VER\"/" include/linux/susfs.h

    echo "===> Applying SuSFS v2.3.0 VFS/proc/exec/selinux inline hooks..."
    python3 "$GITHUB_WORKSPACE/scripts/patch-susfs-v230.py" .

    echo "===> Applying SuSFS + ReSukiSU defconfig fragment..."
    cat "$GITHUB_WORKSPACE/configs/ksu_susfs.config" >> "$DEFCONFIG_PATH"
    echo "[+] ReSukiSU + genuine SuSFS $SUS_VER ready (strict inline_hook_check.mk preserved)."
else
    echo "===> Applying vanilla ReSukiSU defconfig fragment..."
    cat "$GITHUB_WORKSPACE/configs/ksu_vanilla.config" >> "$DEFCONFIG_PATH"
fi
