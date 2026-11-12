#!/bin/bash
set -euo pipefail

cd "$GITHUB_WORKSPACE/kernel_source"

ENABLE_NOMOUNT="${1:-true}"
NOMOUNT_REF="${2:-v2.2.0}"
DEFCONFIG="${3:-vendor/fog-perf_defconfig}"
FIRST_DEFCONFIG="$(echo "$DEFCONFIG" | awk '{print $1}')"
DEFCONFIG_PATH="arch/arm64/configs/$FIRST_DEFCONFIG"

if [ "$ENABLE_NOMOUNT" != "true" ]; then
    echo "===> NoMount disabled (ENABLE_NOMOUNT=$ENABLE_NOMOUNT), skipping."
    exit 0
fi

REPO_URL="https://github.com/maxsteeel/nomount.git"
REPO_DIR="$GITHUB_WORKSPACE/kernel_source/NoMount"

echo "===> Mengintegrasikan NoMount ($NOMOUNT_REF) ke Linux 4.19..."
if [ ! -d "$REPO_DIR/.git" ]; then
    rm -rf "$REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
fi

git -C "$REPO_DIR" reset --hard HEAD --quiet
git -C "$REPO_DIR" fetch --all --tags --quiet
git -C "$REPO_DIR" checkout -q "$NOMOUNT_REF"

test -d "$REPO_DIR/kernel/src" || {
    echo "[-] ERROR: $REPO_DIR/kernel/src not found!"
    exit 1
}

rm -rf fs/nomount
ln -sfn "../NoMount/kernel/src" fs/nomount
test -f fs/nomount/Kconfig && test -f fs/nomount/nomount.c || {
    echo "[-] ERROR: fs/nomount symlink broken!"
    exit 1
}

if ! grep -q "nomount/" fs/Makefile; then
    printf "\nobj-\$(CONFIG_NOMOUNT) += nomount/\n" >> fs/Makefile
    echo "[+] Added nomount/ to fs/Makefile"
fi

if ! grep -q 'source "fs/nomount/Kconfig"' fs/Kconfig; then
    awk '
        /^endmenu/ { last_match = NR }
        { lines[NR] = $0 }
        END {
            if (!last_match) {
                print "ERROR: no endmenu found in fs/Kconfig" > "/dev/stderr"
                exit 1
            }
            for (i = 1; i <= NR; i++) {
                if (i == last_match) print "source \"fs/nomount/Kconfig\""
                print lines[i]
            }
        }
    ' fs/Kconfig > fs/Kconfig.tmp && mv fs/Kconfig.tmp fs/Kconfig
    echo "[+] Added fs/nomount/Kconfig to fs/Kconfig"
fi

if [ -f "$DEFCONFIG_PATH" ]; then
    sed -i '/^CONFIG_NOMOUNT=/d;/^# CONFIG_NOMOUNT is not set/d' "$DEFCONFIG_PATH"
    echo "CONFIG_NOMOUNT=y" >> "$DEFCONFIG_PATH"
    echo "[+] Enabled CONFIG_NOMOUNT=y in $DEFCONFIG_PATH"
fi

echo "[+] NoMount ($NOMOUNT_REF) integration complete."
