#!/bin/bash
set -e

cd "$GITHUB_WORKSPACE/kernel_source"

ENABLE_KSU="${1:-true}"
ENABLE_SUS="${2:-true}"
SUS_VER="${3:-v2.3.0}"
DEFCONFIG="${4:-vendor/fog-perf_defconfig}"
DEFCONFIG_PATH="arch/arm64/configs/$DEFCONFIG"

if [ "$ENABLE_KSU" = "true" ]; then
    echo "===> Mengintegrasikan KernelSU-Next (Legacy Branch v3.4.0 untuk Non-GKI 4.19)..."
    git clone --depth=1 -b v3.4.0-legacy https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/kernel_source/KernelSU-Next"

    rm -rf drivers/kernelsu
    ln -sfn "$GITHUB_WORKSPACE/kernel_source/KernelSU-Next/kernel" drivers/kernelsu
    test -f drivers/kernelsu/Kconfig || { echo "[-] ERROR: drivers/kernelsu/Kconfig does not exist!"; ls -la drivers/kernelsu; exit 1; }
    echo "[+] Verified drivers/kernelsu/Kconfig exists."
    grep -q "kernelsu" drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
    grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig

    echo "===> Menerapkan hook reboot.c untuk handshake KernelSU..."
    python3 -c "
with open('kernel/reboot.c', 'r') as f:
    c = f.read()
hook = '''
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
		ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
		if (magic1 == 0xDEADBEEF)
			return 0;
	}
#endif
'''
target = '\t/* We only trust the superuser with rebooting the system. */'
if target in c and 'ksu_handle_sys_reboot' not in c:
    c = c.replace(target, hook + '\n' + target, 1)
    with open('kernel/reboot.c', 'w') as f:
        f.write(c)
    print('reboot.c hooked!')
"

    if [ "$ENABLE_SUS" = "true" ]; then
        echo "===> Mengambil Patch SUSFS 4.19 (Upstream simonpunk)..."
        git clone --depth=1 -b kernel-4.19 https://gitlab.com/simonpunk/susfs4ksu.git "$GITHUB_WORKSPACE/susfs4ksu"

        echo "===> Menyesuaikan versi SUSFS Header ke $SUS_VER..."
        sed -i "s/#define SUSFS_VERSION .*/#define SUSFS_VERSION \"$SUS_VER\"/" "$GITHUB_WORKSPACE/susfs4ksu/kernel_patches/include/linux/susfs.h"

        echo "===> Menerapkan source code SUSFS ke kernel..."
        cp -r "$GITHUB_WORKSPACE/susfs4ksu/kernel_patches/fs"/* fs/
        cp -r "$GITHUB_WORKSPACE/susfs4ksu/kernel_patches/include/linux"/* include/linux/

        echo "===> Menerapkan patch SUSFS ke kernel tree..."
        patch -p1 --forward < "$GITHUB_WORKSPACE/susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch" || echo "[WARN] Sebagian patch kernel mungkin sudah terpasang"

        echo "===> Memastikan header susfs_def.h terpasang di fs.h dan task_mmu.c..."
        sed -i '/#define _LINUX_FS_H/a #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif' include/linux/fs.h || true
        grep -q "susfs_def.h" fs/proc/task_mmu.c || sed -i '1i #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif' fs/proc/task_mmu.c || true

        echo "===> Menyiapkan inisialisasi SUSFS..."
        sed -i 's/void susfs_init(void) {/late_initcall(susfs_init);\nvoid susfs_init(void) {/' fs/susfs.c || true

        echo "===> Menambahkan definisi Kconfig SuSFS..."
        cat << 'EOF' >> KernelSU-Next/kernel/Kconfig

menu "KernelSU - SUSFS"
config KSU_SUSFS
    bool "KernelSU addon - SUSFS"
    depends on KSU
    default y

config KSU_SUSFS_HAS_MAGIC_MOUNT
    bool "Magic mount support"
    depends on KSU
    default y

config KSU_SUSFS_SUS_PATH
    bool "Hide suspicious path"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_MOUNT
    bool "Hide suspicious mounts"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
    bool "Auto add KSU default mount"
    depends on KSU_SUSFS_SUS_MOUNT
    default y

config KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
    bool "Auto add bind mount"
    depends on KSU_SUSFS_SUS_MOUNT
    default y

config KSU_SUSFS_SUS_KSTAT
    bool "Spoof kstat"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_OVERLAYFS
    bool "Spoof overlayfs"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_TRY_UMOUNT
    bool "Try umount"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
    bool "Auto add try umount for bind mount"
    depends on KSU_SUSFS_TRY_UMOUNT
    default y

config KSU_SUSFS_SPOOF_UNAME
    bool "Spoof uname"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_ENABLE_LOG
    bool "Enable log"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
    bool "Hide symbols"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    bool "Spoof cmdline"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_OPEN_REDIRECT
    bool "Open redirect"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_SU
    bool "SUS SU"
    depends on KSU_SUSFS
    default n
endmenu
EOF
    fi

    echo "===> Mengaktifkan config KernelSU & SUSFS di defconfig..."
    cat "$GITHUB_WORKSPACE/configs/ksu_susfs.config" >> "$DEFCONFIG_PATH"
fi
