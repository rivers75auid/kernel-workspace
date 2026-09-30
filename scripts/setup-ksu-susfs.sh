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

        echo "===> Menambahkan glue code SuSFS <-> KernelSU-Next..."
        cat << 'EOF' >> fs/susfs.c

/* ====================================================================
 * KernelSU-Next & SuSFS Compatibility Glue
 * Provides missing link symbols expected by SuSFS and fs/namespace.c
 * ==================================================================== */
#include <linux/syscalls.h>
#include <linux/dcache.h>
#include <linux/limits.h>
#include <linux/err.h>

extern bool is_ksu_domain(void);
extern bool is_zygote(const struct cred *cred);

bool susfs_is_current_ksu_domain(void) {
    return is_ksu_domain();
}

bool susfs_is_current_zygote_domain(void) {
    return is_zygote(current_cred());
}

#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
extern bool susfs_is_mnt_devname_ksu(struct path *path);

static bool ksu_should_umount(struct path *path) {
    if (!path) {
        return false;
    }
#ifdef CONFIG_KSU_SUSFS
    return susfs_is_mnt_devname_ksu(path);
#else
    if (path->mnt && path->mnt->mnt_sb && path->mnt->mnt_sb->s_type) {
        const char *fstype = path->mnt->mnt_sb->s_type->name;
        return strcmp(fstype, "overlay") == 0;
    }
    return false;
#endif
}

static int ksu_umount_mnt(struct path *path, int flags) {
    int err = 0;
    char *mnt_name = kzalloc(PATH_MAX, GFP_KERNEL);
    char *path_name = NULL;
    mm_segment_t old_fs;

    if (!mnt_name) {
        pr_err("ksu_umount_mnt: kmalloc failed\n");
        path_put(path);
        return -ENOMEM;
    }

    path_name = d_path(path, mnt_name, PATH_MAX);
    if (IS_ERR(path_name)) {
        err = PTR_ERR(path_name);
        pr_err("ksu_umount_mnt: d_path failed: %d\n", err);
        goto out;
    }

    old_fs = get_fs();
    set_fs(KERNEL_DS);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 17, 0)
    err = ksys_umount((char __user *)path_name, flags);
#else
    err = sys_umount((char __user *)path_name, flags);
#endif
    set_fs(old_fs);

    if (err) {
        pr_warn("ksu_umount_mnt: sys_umount failed: %d\n", err);
    }

out:
    path_put(path);
    kfree(mnt_name);
    return err;
}

void ksu_try_umount(const char *mnt, bool check_mnt, int flags, uid_t uid) {
    struct path path;
    int err = kern_path(mnt, 0, &path);
    if (err) {
        return;
    }
    if (check_mnt) {
        if (!ksu_should_umount(&path)) {
            path_put(&path);
            return;
        }
    }

#if defined(CONFIG_KSU_SUSFS_ENABLE_LOG)
    if (susfs_is_log_enabled) {
        pr_info("susfs: umounting '%s' for uid: %d\n", mnt, uid);
    }
#endif

    err = ksu_umount_mnt(&path, flags);
    if (err) {
        pr_warn("umount %s failed: %d\n", mnt, err);
    }
}

void susfs_try_umount_all(uid_t uid) {
    susfs_try_umount(uid);
    ksu_try_umount("/system", true, 0, uid);
    ksu_try_umount("/system_ext", true, 0, uid);
    ksu_try_umount("/vendor", true, 0, uid);
    ksu_try_umount("/product", true, 0, uid);
    ksu_try_umount("/odm", true, 0, uid);
    ksu_try_umount("/data/adb/modules", false, MNT_DETACH, uid);
    ksu_try_umount("/debug_ramdisk", true, MNT_DETACH, uid);
}
#endif

void ksu_susfs_enable_sus_su(void) {}
void ksu_susfs_disable_sus_su(void) {}
bool susfs_is_allow_su(void) {
    return is_ksu_domain();
}
EOF

        echo "===> Menyesuaikan KernelSU-Next hook dan rules untuk SuSFS..."
        python3 -c "
with open('KernelSU-Next/kernel/hook/setuid_hook.c', 'r') as f:
    c = f.read()
target = 'ksu_handle_umount(old_uid, new_uid);'
replacement = '''ksu_handle_umount(old_uid, new_uid);
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
    {
        extern void susfs_try_umount_all(uid_t uid);
        susfs_try_umount_all(new_uid);
    }
#endif'''
if target in c and 'susfs_try_umount_all' not in c:
    c = c.replace(target, replacement, 1)
    with open('KernelSU-Next/kernel/hook/setuid_hook.c', 'w') as f:
        f.write(c)
    print('setuid_hook.c patched for SuSFS!')

with open('KernelSU-Next/kernel/selinux/rules.c', 'r') as f:
    c = f.read()
target = 'ksu_allow(db, \"zygote\", \"adb_data_file\", \"dir\", \"search\");'
replacement = '''ksu_allow(db, \"zygote\", \"adb_data_file\", \"dir\", \"search\");
#ifdef CONFIG_KSU_SUSFS
    ksu_allow(db, \"zygote\", \"labeledfs\", \"filesystem\", \"unmount\");
#endif'''
if target in c and 'labeledfs' not in c:
    c = c.replace(target, replacement, 1)
    with open('KernelSU-Next/kernel/selinux/rules.c', 'w') as f:
        f.write(c)
    print('rules.c patched for SuSFS!')
"

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
