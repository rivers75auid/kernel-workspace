#!/bin/bash
set -e

cd "$GITHUB_WORKSPACE/kernel_source"

ENABLE_KSU="${1:-true}"
ENABLE_SUS="${2:-true}"
SUS_VER="${3:-v2.3.0}"
DEFCONFIG="${4:-vendor/fog-perf_defconfig}"
DEFCONFIG_PATH="arch/arm64/configs/$DEFCONFIG"

if [ "$ENABLE_KSU" = "true" ]; then
    echo "===> Mengintegrasikan KernelSU-Next (Legacy Branch untuk Non-GKI 4.19)..."
    git clone --depth=1 -b legacy https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/kernel_source/KernelSU-Next"

    rm -rf drivers/kernelsu
    ln -sfn "$GITHUB_WORKSPACE/kernel_source/KernelSU-Next/kernel" drivers/kernelsu
    test -f drivers/kernelsu/Kconfig || { echo "[-] ERROR: drivers/kernelsu/Kconfig does not exist!"; ls -la drivers/kernelsu; exit 1; }
    echo "[+] Verified drivers/kernelsu/Kconfig exists."
    sed -i 's/KSU_VERSION_FALLBACK := 1/KSU_VERSION_FALLBACK := 11998/' "$GITHUB_WORKSPACE/kernel_source/KernelSU-Next/kernel/Kbuild" || true
    sed -i 's/KSU_VERSION_TAG_FALLBACK := v0.0.1/KSU_VERSION_TAG_FALLBACK := v3.4.0/' "$GITHUB_WORKSPACE/kernel_source/KernelSU-Next/kernel/Kbuild" || true

    echo "===> Mengizinkan Multi-Manager (KernelSU-Next + ReSukiSU)..."
    python3 -c "
with open('KernelSU-Next/kernel/manager/apk_sign.c', 'r') as f:
    c = f.read()

target = 'return check_v2_signature(path, EXPECTED_MANAGER_SIZE, EXPECTED_MANAGER_HASH);'
replacement = '''if (check_v2_signature(path, EXPECTED_MANAGER_SIZE, EXPECTED_MANAGER_HASH)) return true;
\t/* ReSukiSU Manager support */
\tif (check_v2_signature(path, 0x377, \"d3469712b6214462764a1d8d3e5cbe1d6819a0b629791b9f4101867821f1df64\")) return true;
\t/* Official KernelSU Manager support */
\tif (check_v2_signature(path, 0x033b, \"c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6\")) return true;
\treturn false;'''

if target in c:
    c = c.replace(target, replacement, 1)
    with open('KernelSU-Next/kernel/manager/apk_sign.c', 'w') as f:
        f.write(c)
    print('[+] Multi-manager signatures patched into KernelSU-Next!')
"

    grep -q "kernelsu" drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
    grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig

    echo "===> Mengaktifkan hook setresuid, prctl, read, dan execve di syscall_table_hook.c..."
    cat > patch_sth.py << 'PYEOF'
with open('KernelSU-Next/kernel/hook/syscall_table_hook.c', 'r') as f:
    c = f.read()

extra_inc = '''#include <linux/cred.h>
#include <linux/syscalls.h>
#include <asm/unistd.h>
#include "hook/setuid_hook.h"
#include "manager/manager_identity.h"
#include "manager/throne_tracker.h"
#include "manager/manager_observer.h"
#include "runtime/ksud_boot.h"
#include "supercall/supercall.h"
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>
#include <linux/susfs_def.h>
#ifndef SUSFS_VARIANT
#define SUSFS_VARIANT "NON-GKI"
#endif
#endif
#ifndef __NR_prctl
#define __NR_prctl 167
#endif
#ifndef __NR_setresuid
#define __NR_setresuid 147
#endif
#ifndef __NR_read
#define __NR_read 63
#endif
extern int ksu_handle_execve_ksud(const char __user *filename_user,
                                  const char __user *const __user *__argv);
'''

if 'manager_identity.h' not in c:
    c = c.replace('#include "runtime/ksud.h"', '#include "runtime/ksud.h"\n' + extra_inc, 1)

# Bridge execve and execveat to ksud_integration to trigger init second_stage and zygote post-fs-data
execve_target = 'const char __user **filename_user =\n\t\t(const char __user **)&PT_REGS_PARM1(regs);\n\tlong adb_ret = 0;\n\n\tif (current->pid != 1 && is_init(current_cred())) {'
execve_repl = 'const char __user **filename_user =\n\t\t(const char __user **)&PT_REGS_PARM1(regs);\n\tlong adb_ret = 0;\n\n\tksu_handle_execve_ksud(*filename_user, (const char __user *const __user *)PT_REGS_PARM2(regs));\n\n\tif (current->pid != 1 && is_init(current_cred())) {'
if 'ksu_handle_execve_ksud(*filename_user, (const char __user *const __user *)PT_REGS_PARM2(regs));' not in c:
    c = c.replace(execve_target, execve_repl, 1)

execveat_target = 'if ((int)PT_REGS_PARM1(regs) == AT_FDCWD &&\n\t    (int)PT_REGS_SYSCALL_PARM4(regs) == 0) {\n\t\tif (current->pid != 1 && is_init(current_cred())) {'
execveat_repl = 'ksu_handle_execve_ksud(*filename_user, (const char __user *const __user *)PT_REGS_PARM3(regs));\n\n\tif ((int)PT_REGS_PARM1(regs) == AT_FDCWD &&\n\t    (int)PT_REGS_SYSCALL_PARM4(regs) == 0) {\n\t\tif (current->pid != 1 && is_init(current_cred())) {'
if 'ksu_handle_execve_ksud(*filename_user, (const char __user *const __user *)PT_REGS_PARM3(regs));' not in c:
    c = c.replace(execveat_target, execveat_repl, 1)

# Add setresuid, prctl, and read handlers
handlers = '''
static long ksu_sth_setresuid(const struct pt_regs *regs)
{
	uid_t ruid = (uid_t)PT_REGS_PARM1(regs);
	uid_t euid = (uid_t)PT_REGS_PARM2(regs);
	uid_t suid = (uid_t)PT_REGS_PARM3(regs);

	ksu_handle_setresuid(current_uid().val, ruid);

	return ksu_sth_call_orig(__NR_setresuid, regs);
}

static long ksu_sth_prctl(const struct pt_regs *regs)
{
	int option = (int)PT_REGS_PARM1(regs);
	unsigned long arg2 = (unsigned long)PT_REGS_PARM2(regs);
	unsigned long arg3 = (unsigned long)PT_REGS_PARM3(regs);
	unsigned long arg4 = (unsigned long)PT_REGS_SYSCALL_PARM4(regs);
	unsigned long arg5 = (unsigned long)PT_REGS_PARM5(regs);

	if (unlikely(option == 0xDEADBEEF)) {
		if (!ksu_is_manager_appid_valid()) {
			track_throne(false);
		}
		if (!is_manager() && current_uid().val != 0) {
			return ksu_sth_call_orig(__NR_prctl, regs);
		}
		if (arg2 == 2) {
			int version = KSU_VERSION;
			int flags = 0;
			if (!arg3 || !arg4) {
				return ksu_sth_call_orig(__NR_prctl, regs);
			}
			if (is_manager()) {
				flags |= 0x2; // KSU_GET_INFO_FLAG_MANAGER
			}
			if (copy_to_user((void __user *)arg3, &version, sizeof(version)))
				return -EFAULT;
			if (copy_to_user((void __user *)arg4, &flags, sizeof(flags)))
				return -EFAULT;
			return 0;
		}
		if (is_manager()) {
			ksu_install_fd();
		}
#ifdef CONFIG_KSU_SUSFS
		if (current_uid().val == 0) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
			if (arg2 == CMD_SUSFS_ADD_SUS_PATH) {
				int error = susfs_add_sus_path((struct st_susfs_sus_path __user*)arg3);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
			if (arg2 == CMD_SUSFS_ADD_SUS_MOUNT) {
				int error = susfs_add_sus_mount((struct st_susfs_sus_mount __user*)arg3);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
			if (arg2 == CMD_SUSFS_ADD_SUS_KSTAT || arg2 == CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY) {
				int error = susfs_add_sus_kstat((struct st_susfs_sus_kstat __user*)arg3);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
			if (arg2 == CMD_SUSFS_UPDATE_SUS_KSTAT) {
				int error = susfs_update_sus_kstat((struct st_susfs_sus_kstat __user*)arg3);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
			if (arg2 == CMD_SUSFS_ADD_TRY_UMOUNT) {
				int error = susfs_add_try_umount((struct st_susfs_try_umount __user*)arg3);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
			if (arg2 == CMD_SUSFS_SET_UNAME) {
				int error = susfs_set_uname((struct st_susfs_uname __user*)arg3);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
			if (arg2 == CMD_SUSFS_ENABLE_LOG) {
				int error = 0;
				susfs_set_log(arg3 != 0);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
			if (arg2 == CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG) {
				int error = susfs_set_cmdline_or_bootconfig((char __user*)arg3);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
			if (arg2 == CMD_SUSFS_ADD_OPEN_REDIRECT) {
				int error = susfs_add_open_redirect((struct st_susfs_open_redirect __user*)arg3);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
			if (arg2 == CMD_SUSFS_ADD_SUS_MAP) {
				extern void susfs_add_sus_map(void __user **user_info);
				susfs_add_sus_map((void __user **)arg3);
				return 0;
			}
#endif
			if (arg2 == CMD_SUSFS_SHOW_VERSION) {
				int error = 0;
				int len = strlen(SUSFS_VERSION);
				error = copy_to_user((void __user*)arg3, (void*)SUSFS_VERSION, len + 1);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
			if (arg2 == CMD_SUSFS_SHOW_ENABLED_FEATURES) {
				int error = 0;
				u64 enabled_features = 0;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
				enabled_features |= (1 << 0);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
				enabled_features |= (1 << 1);
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
				enabled_features |= (1 << 2);
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
				enabled_features |= (1 << 3);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
				enabled_features |= (1 << 4);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_OVERLAYFS
				enabled_features |= (1 << 5);
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
				enabled_features |= (1 << 6);
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
				enabled_features |= (1 << 7);
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
				enabled_features |= (1 << 8);
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
				enabled_features |= (1 << 9);
#endif
#ifdef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
				enabled_features |= (1 << 10);
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
				enabled_features |= (1 << 11);
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
				enabled_features |= (1 << 12);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
				enabled_features |= (1 << 13);
#endif
#ifdef CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT
				enabled_features |= (1 << 14);
#endif
				error = copy_to_user((void __user*)arg3, (void*)&enabled_features, sizeof(enabled_features));
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
			if (arg2 == CMD_SUSFS_SHOW_VARIANT) {
				int error = 0;
				int len = strlen(SUSFS_VARIANT);
				error = copy_to_user((void __user*)arg3, (void*)SUSFS_VARIANT, len + 1);
				(void)copy_to_user((void __user*)arg5, &error, sizeof(error));
				return 0;
			}
		}
#endif
	}

	return ksu_sth_call_orig(__NR_prctl, regs);
}

extern bool ksu_init_rc_hook;
extern void ksu_handle_sys_read(unsigned int fd);
static long ksu_sth_read(const struct pt_regs *regs)
{
	if (unlikely(current->pid == 1 && ksu_init_rc_hook)) {
		unsigned int fd = (unsigned int)PT_REGS_PARM1(regs);
		ksu_handle_sys_read(fd);
	}
	return ksu_sth_call_orig(__NR_read, regs);
}
'''
if 'ksu_sth_setresuid' not in c:
    c = c.replace('void __init ksu_syscall_table_hook_init(void)', handlers + '\nvoid __init ksu_syscall_table_hook_init(void)', 1)

hooks_anchor = '{ __NR_newfstatat, ksu_sth_newfstatat },\n#endif'
hooks_repl = '{ __NR_newfstatat, ksu_sth_newfstatat },\n#endif\n\t\t{ __NR_setresuid, ksu_sth_setresuid },\n\t\t{ __NR_prctl, ksu_sth_prctl },\n\t\t{ __NR_read, ksu_sth_read },'
if '{ __NR_setresuid' not in c:
    c = c.replace(hooks_anchor, hooks_repl, 1)

with open('KernelSU-Next/kernel/hook/syscall_table_hook.c', 'w') as f:
    f.write(c)
print('[+] syscall_table_hook.c successfully patched for non-GKI!')
PYEOF
    python3 patch_sth.py && rm -f patch_sth.py

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
        grep -q "susfs_def.h" fs/proc/task_mmu.c || sed -i '1i #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif' fs/proc/task_mmu.c || true

        echo "===> Menambahkan dukungan SUS_MAP ke header SuSFS..."
        cat << 'EOF' >> include/linux/susfs_def.h

#ifndef CMD_SUSFS_ADD_SUS_MAP
#define CMD_SUSFS_ADD_SUS_MAP 0x60020
#endif
#ifndef AS_FLAGS_SUS_MAP
#define AS_FLAGS_SUS_MAP 39
#endif
#ifndef SUSFS_IS_INODE_SUS_MAP
#define SUSFS_IS_INODE_SUS_MAP(inode) \
	(inode && inode->i_mapping && \
	unlikely(test_bit(AS_FLAGS_SUS_MAP, &inode->i_mapping->flags)) && \
	(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC))
#endif
EOF

        cat << 'EOF' >> include/linux/susfs.h

#ifdef CONFIG_KSU_SUSFS_SUS_MAP
struct st_susfs_sus_map {
    char target_pathname[256];
    int err;
};
void susfs_add_sus_map(void __user **user_info);
#endif
EOF

        echo "===> Menerapkan hook SUS_MAP ke fs/proc/task_mmu.c..."
        python3 -c "
with open('fs/proc/task_mmu.c', 'r') as f:
    c = f.read()

target1 = 'struct inode *inode = file_inode(vma->vm_file);'
repl1 = target1 + '''
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		if (SUSFS_IS_INODE_SUS_MAP(inode))
			return;
#endif'''
if target1 in c and 'CONFIG_KSU_SUSFS_SUS_MAP' not in c:
    c = c.replace(target1, repl1, 1)

target2 = 'struct vm_area_struct *vma = v;'
repl2 = target2 + '''
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	if (vma->vm_file) {
		if (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
			return 0;
	}
#endif'''
if target2 in c and 'CONFIG_KSU_SUSFS_SUS_MAP' not in c:
    c = c.replace(target2, repl2, 1)

with open('fs/proc/task_mmu.c', 'w') as f:
    f.write(c)
print('task_mmu.c successfully patched for SUS_MAP!')
"

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

#ifdef CONFIG_KSU_SUSFS_SUS_MAP
void susfs_add_sus_map(void __user **user_info) {
	struct st_susfs_sus_map info = {0};
	struct path path;
	struct inode *inode = NULL;

	if (copy_from_user(&info, (struct st_susfs_sus_map __user*)*user_info, sizeof(info))) {
		info.err = -EFAULT;
		goto out_copy_to_user;
	}

	info.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);
	if (info.err) {
		pr_err("susfs: failed opening file '%s'\n", info.target_pathname);
		goto out_copy_to_user;
	}

	inode = d_inode(path.dentry);
	if (!inode || !inode->i_mapping) {
		pr_err("susfs: inode || inode->i_mapping is NULL\n");
		info.err = -ENOENT;
		goto out_path_put_path;
	}
	set_bit(AS_FLAGS_SUS_MAP, &inode->i_mapping->flags);
	pr_info("susfs: pathname: '%s', is flagged as AS_FLAGS_SUS_MAP\n", info.target_pathname);
	info.err = 0;
out_path_put_path:
	path_put(&path);
out_copy_to_user:
	if (copy_to_user(&((struct st_susfs_sus_map __user*)*user_info)->err, &info.err, sizeof(info.err))) {
		info.err = -EFAULT;
	}
	pr_info("susfs: CMD_SUSFS_ADD_SUS_MAP -> ret: %d\n", info.err);
}
#endif

#ifdef CONFIG_KSU_SUSFS
extern bool susfs_is_mnt_devname_ksu(struct path *path);

static bool ksu_should_umount(struct path *path) {
    if (!path) {
        return false;
    }
    if (susfs_is_mnt_devname_ksu(path)) {
        return true;
    }
    if (path->mnt && path->mnt->mnt_sb && path->mnt->mnt_sb->s_type) {
        const char *fstype = path->mnt->mnt_sb->s_type->name;
        return strcmp(fstype, "overlay") == 0;
    }
    return false;
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
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
    susfs_try_umount(uid);
#endif
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

headers = '''#include <linux/rcupdate.h>
#include <linux/cred.h>
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif
#include \"selinux/selinux.h\"
'''
if 'susfs_def.h' not in c:
    c = headers + c

helper = '''
#ifdef CONFIG_KSU_SUSFS
static inline bool is_child_of_zygote(void)
{
	bool res = false;
	struct task_struct *parent;

	if (is_zygote(current_cred()))
		return true;

	rcu_read_lock();
	parent = rcu_dereference(current->real_parent);
	if (parent) {
		res = is_zygote(__task_cred(parent));
	}
	rcu_read_unlock();

	return res;
}
#endif
'''
if 'is_child_of_zygote' not in c:
    c = c.replace('int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid)', helper + '\\nint ksu_handle_setresuid(uid_t old_uid, uid_t new_uid)', 1)

state_target = '''	} else {
#ifdef KSU_KPROBES_HOOK
		ksu_clear_task_tracepoint_flag_if_needed(current);
#endif
    }'''

state_repl = '''	} else {
#ifdef KSU_KPROBES_HOOK
		ksu_clear_task_tracepoint_flag_if_needed(current);
#endif
#ifdef CONFIG_KSU_SUSFS
		if (is_appuid(new_uid) || is_isolated_process(new_uid)) {
			task_lock(current);
			current->susfs_task_state |= TASK_STRUCT_NON_ROOT_USER_APP_PROC;
			task_unlock(current);
		}
#endif
    }'''

if state_target in c:
    c = c.replace(state_target, state_repl, 1)

target = 'ksu_handle_umount(old_uid, new_uid);'
replacement = '''ksu_handle_umount(old_uid, new_uid);
#ifdef CONFIG_KSU_SUSFS
    if (is_child_of_zygote() && (is_isolated_process(new_uid) || (is_appuid(new_uid) && ksu_uid_should_umount(new_uid)))) {
        extern void susfs_try_umount_all(uid_t uid);
        susfs_try_umount_all(new_uid);
    }
#endif'''
if target in c and 'susfs_try_umount_all' not in c:
    c = c.replace(target, replacement, 1)

with open('KernelSU-Next/kernel/hook/setuid_hook.c', 'w') as f:
    f.write(c)
print('setuid_hook.c patched for SuSFS!')

with open('KernelSU-Next/kernel/feature/kernel_umount.c', 'r') as f:
    kc = f.read()

target_zygote = 'bool is_zygote_child = is_zygote(current_cred());'
repl_zygote = 'bool is_zygote_child = is_zygote(current_cred()) || (current->real_parent && is_zygote(current->real_parent->cred));'

if target_zygote in kc:
    kc = kc.replace(target_zygote, repl_zygote, 1)
    with open('KernelSU-Next/kernel/feature/kernel_umount.c', 'w') as f:
        f.write(kc)
    print('kernel_umount.c patched for zygote child check!')

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

        echo "===> Menambahkan dispatch SUSFS (reboot-based) ke supercall KernelSU-Next..."
        cat > ksu_susfs_dispatch_patch.py << 'PYEOF'
path = 'KernelSU-Next/kernel/supercall/supercall.c'
with open(path, 'r') as f:
    c = f.read()

if 'ksu_handle_susfs_sys_reboot' in c:
    print('[+] supercall.c already patched for SUSFS dispatch')
else:
    inc = '#include <linux/version.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#include <linux/susfs_def.h>\n#include <linux/kernel.h>\n#include <linux/string.h>\n#endif\n'
    c = c.replace('#include <linux/version.h>\n', inc, 1)

    susfs_handler = r'''
#ifdef CONFIG_KSU_SUSFS
#ifndef SUSFS_MAGIC
#define SUSFS_MAGIC 0xFAFAFAFA
#endif
#ifndef SUSFS_MAX_VERSION_BUFSIZE
#define SUSFS_MAX_VERSION_BUFSIZE 16
#endif
#ifndef SUSFS_MAX_VARIANT_BUFSIZE
#define SUSFS_MAX_VARIANT_BUFSIZE 16
#endif
#ifndef SUSFS_ENABLED_FEATURES_SIZE
#define SUSFS_ENABLED_FEATURES_SIZE 8192
#endif
#ifndef SUSFS_VARIANT
#define SUSFS_VARIANT "NON-GKI"
#endif

struct ksu_susfs_version_cmd {
	char version[SUSFS_MAX_VERSION_BUFSIZE];
	int err;
};
struct ksu_susfs_variant_cmd {
	char variant[SUSFS_MAX_VARIANT_BUFSIZE];
	int err;
};
struct ksu_susfs_features_cmd {
	char features[SUSFS_ENABLED_FEATURES_SIZE];
	int err;
};
struct st_susfs_sus_kstat_v2 {
	bool is_statically;
	unsigned long target_ino;
	char target_pathname[SUSFS_MAX_LEN_PATHNAME];
	unsigned long spoofed_ino;
	unsigned long spoofed_dev;
	unsigned int spoofed_nlink;
	long long spoofed_size;
	long spoofed_atime_tv_sec;
	unsigned long spoofed_atime_tv_nsec;
	long spoofed_mtime_tv_sec;
	unsigned long spoofed_mtime_tv_nsec;
	long spoofed_ctime_tv_sec;
	unsigned long spoofed_ctime_tv_nsec;
	long long spoofed_blocks;
	long spoofed_blksize;
	int flags;
	int err;
};

static int ksu_handle_susfs_sys_reboot(unsigned int cmd, void __user **arg)
{
	switch (cmd) {
	case 0x55550: /* CMD_SUSFS_ADD_SUS_PATH */
	case 0x55553: /* CMD_SUSFS_ADD_SUS_PATH_LOOP */ {
		struct {
			char target_pathname[SUSFS_MAX_LEN_PATHNAME];
			int err;
		} info = {0};
		struct path p;

		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;

		if (!kern_path(info.target_pathname, LOOKUP_FOLLOW, &p)) {
			struct inode *inode = d_inode(p.dentry);
			if (inode) {
				spin_lock(&inode->i_lock);
				inode->i_state |= (1 << 24); /* INODE_STATE_SUS_PATH */
				spin_unlock(&inode->i_lock);
			}
			path_put(&p);
		}
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
		{
			struct st_susfs_sus_path k_info = {0};
			strncpy(k_info.target_pathname, info.target_pathname, sizeof(k_info.target_pathname) - 1);
			susfs_add_sus_path((struct st_susfs_sus_path __user *)&k_info);
		}
#endif
		info.err = 0;
		if (copy_to_user((void __user*)*arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	case 0x60020: /* CMD_SUSFS_ADD_SUS_MAP */ {
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		extern void susfs_add_sus_map(void __user **user_info);
		susfs_add_sus_map(arg);
#else
		struct { char target_pathname[SUSFS_MAX_LEN_PATHNAME]; int err; } info = {0};
		if (!copy_from_user(&info, (void __user*)*arg, sizeof(info))) {
			info.err = 0;
			(void)copy_to_user((void __user*)*arg, &info, sizeof(info));
		}
#endif
		return 0;
	}
	case 0x55560: /* CMD_SUSFS_ADD_SUS_MOUNT */ {
		struct {
			char target_pathname[SUSFS_MAX_LEN_PATHNAME];
			unsigned long target_dev;
			int err;
		} info = {0};
		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
		{
			struct st_susfs_sus_mount k_info = {0};
			strncpy(k_info.target_pathname, info.target_pathname, sizeof(k_info.target_pathname) - 1);
			k_info.target_dev = info.target_dev;
			susfs_add_sus_mount((struct st_susfs_sus_mount __user *)&k_info);
		}
#endif
		info.err = 0;
		if (copy_to_user((void __user*)*arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	case 0x55561: /* CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS */
	case 0x60010: /* CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING */ {
		struct {
			unsigned int enabled;
			int err;
		} info = {0};
		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
		info.err = 0;
		if (copy_to_user((void __user*)*arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	case 0x55570: /* CMD_SUSFS_ADD_SUS_KSTAT */
	case 0x55571: /* CMD_SUSFS_UPDATE_SUS_KSTAT */
	case 0x55572: /* CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY */ {
		struct st_susfs_sus_kstat_v2 info = {0};
		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
		{
			struct st_susfs_sus_kstat k_info = {0};
			k_info.is_statically = info.is_statically ? 1 : 0;
			k_info.target_ino = info.target_ino;
			strncpy(k_info.target_pathname, info.target_pathname, sizeof(k_info.target_pathname) - 1);
			k_info.spoofed_ino = info.spoofed_ino;
			k_info.spoofed_dev = info.spoofed_dev;
			k_info.spoofed_nlink = info.spoofed_nlink;
			k_info.spoofed_size = info.spoofed_size;
			k_info.spoofed_atime_tv_sec = info.spoofed_atime_tv_sec;
			k_info.spoofed_atime_tv_nsec = (long)info.spoofed_atime_tv_nsec;
			k_info.spoofed_mtime_tv_sec = info.spoofed_mtime_tv_sec;
			k_info.spoofed_mtime_tv_nsec = (long)info.spoofed_mtime_tv_nsec;
			k_info.spoofed_ctime_tv_sec = info.spoofed_ctime_tv_sec;
			k_info.spoofed_ctime_tv_nsec = (long)info.spoofed_ctime_tv_nsec;
			k_info.spoofed_blksize = (unsigned long)info.spoofed_blksize;
			k_info.spoofed_blocks = (unsigned long long)info.spoofed_blocks;

			if (k_info.target_ino == 0 && strlen(k_info.target_pathname) > 0) {
				struct path p;
				if (!kern_path(k_info.target_pathname, LOOKUP_FOLLOW, &p)) {
					if (d_inode(p.dentry))
						k_info.target_ino = d_inode(p.dentry)->i_ino;
					path_put(&p);
				}
			}
			if (cmd == 0x55571) {
				susfs_update_sus_kstat((struct st_susfs_sus_kstat __user *)&k_info);
			} else {
				susfs_add_sus_kstat((struct st_susfs_sus_kstat __user *)&k_info);
			}
		}
#endif
		info.err = 0;
		if (copy_to_user((void __user*)*arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	case 0x55580: /* CMD_SUSFS_ADD_TRY_UMOUNT */ {
		struct {
			char target_pathname[SUSFS_MAX_LEN_PATHNAME];
			int mnt_mode;
			int err;
		} info = {0};
		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
		{
			struct st_susfs_try_umount k_info = {0};
			strncpy(k_info.target_pathname, info.target_pathname, sizeof(k_info.target_pathname) - 1);
			k_info.mnt_mode = info.mnt_mode;
			susfs_add_try_umount((struct st_susfs_try_umount __user *)&k_info);
		}
#endif
		info.err = 0;
		if (copy_to_user((void __user*)*arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	case 0x555b0: /* CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG */ {
		struct {
			char fake_cmdline_or_bootconfig[SUSFS_FAKE_CMDLINE_OR_BOOTCONFIG_SIZE];
			int err;
		} *info;
		info = kzalloc(sizeof(*info), GFP_KERNEL);
		if (!info)
			return -ENOMEM;
		if (copy_from_user(info, (void __user*)*arg, sizeof(*info))) {
			kfree(info);
			return -EFAULT;
		}
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
		susfs_set_cmdline_or_bootconfig((char __user *)info->fake_cmdline_or_bootconfig);
#endif
		info->err = 0;
		if (copy_to_user((void __user*)*arg, info, sizeof(*info))) {
			kfree(info);
			return -EFAULT;
		}
		kfree(info);
		return 0;
	}
	case 0x555c0: /* CMD_SUSFS_ADD_OPEN_REDIRECT */ {
		struct {
			char target_pathname[SUSFS_MAX_LEN_PATHNAME];
			char redirected_pathname[SUSFS_MAX_LEN_PATHNAME];
			unsigned int uid_scheme;
			int err;
		} info = {0};
		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
		{
			struct st_susfs_open_redirect k_info = {0};
			struct path p;
			strncpy(k_info.target_pathname, info.target_pathname, sizeof(k_info.target_pathname) - 1);
			strncpy(k_info.redirected_pathname, info.redirected_pathname, sizeof(k_info.redirected_pathname) - 1);
			if (!kern_path(info.target_pathname, LOOKUP_FOLLOW, &p)) {
				struct inode *inode = d_inode(p.dentry);
				if (inode) {
					k_info.target_ino = inode->i_ino;
					spin_lock(&inode->i_lock);
					inode->i_state |= (1 << 27); /* INODE_STATE_OPEN_REDIRECT */
					spin_unlock(&inode->i_lock);
				}
				path_put(&p);
			}
			susfs_add_open_redirect((struct st_susfs_open_redirect __user *)&k_info);
		}
#endif
		info.err = 0;
		if (copy_to_user((void __user*)*arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	case 0x55590: /* CMD_SUSFS_SET_UNAME */ {
		struct {
			char release[65];
			char version[65];
			int err;
		} info = {0};
		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
		{
			struct st_susfs_uname k_info = {0};
			strncpy(k_info.release, info.release, sizeof(k_info.release) - 1);
			strncpy(k_info.version, info.version, sizeof(k_info.version) - 1);
			susfs_set_uname((struct st_susfs_uname __user *)&k_info);
		}
#endif
		info.err = 0;
		if (copy_to_user((void __user*)*arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	case 0x555a0: /* CMD_SUSFS_ENABLE_LOG */ {
		struct {
			unsigned int enabled;
			int err;
		} info = {0};
		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
		susfs_set_log(info.enabled != 0);
#endif
		info.err = 0;
		if (copy_to_user((void __user*)*arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	case 0x555d0: /* CMD_SUSFS_RUN_UMOUNT_FOR_CURRENT_MNT_NS */ {
		struct {
			int err;
		} info = {0};
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
		susfs_try_umount(current_uid().val);
#endif
		info.err = 0;
		(void)copy_to_user((void __user*)*arg, &info, sizeof(info));
		return 0;
	}
	case 0x55551:
	case 0x555e1: { /* CMD_SUSFS_SHOW_VERSION */
		struct ksu_susfs_version_cmd v = {0};
		scnprintf(v.version, sizeof(v.version), "%s", SUSFS_VERSION);
		v.err = 0;
		if (copy_to_user((void __user *)*arg, &v, sizeof(v)))
			return -EFAULT;
		return 0;
	}
	case 0x555e3: { /* CMD_SUSFS_SHOW_VARIANT */
		struct ksu_susfs_variant_cmd var = {0};
		scnprintf(var.variant, sizeof(var.variant), "%s", SUSFS_VARIANT);
		var.err = 0;
		if (copy_to_user((void __user *)*arg, &var, sizeof(var)))
			return -EFAULT;
		return 0;
	}
	case 0x55552:
	case 0x555e2: { /* CMD_SUSFS_SHOW_ENABLED_FEATURES */
		struct ksu_susfs_features_cmd *feat;
		char *p;
		size_t remain;
		int n;

		feat = kzalloc(sizeof(*feat), GFP_KERNEL);
		if (!feat)
			return -ENOMEM;
		p = feat->features;
		remain = sizeof(feat->features);
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_SUS_PATH\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_SUS_MOUNT\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_SUS_KSTAT\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_OVERLAYFS
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_SUS_OVERLAYFS\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_TRY_UMOUNT\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_SPOOF_UNAME\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_ENABLE_LOG\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_OPEN_REDIRECT\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_SUS_MAP\n");
		p += n; remain -= n;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_SU
		n = scnprintf(p, remain, "CONFIG_KSU_SUSFS_SUS_SU\n");
		p += n; remain -= n;
#endif
		feat->err = 0;
		if (copy_to_user((void __user *)*arg, feat, sizeof(*feat))) {
			kfree(feat);
			return -EFAULT;
		}
		kfree(feat);
		return 0;
	}
	default:
		return 0;
	}
}
#endif
'''
    c = c.replace('int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,', susfs_handler + '\nint ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,', 1)

    route_anchor = '\tu64 reply = (u64)*arg;\n\n\tif (magic2 == CHANGE_MANAGER_UID) {'
    route_repl = '\tu64 reply = (u64)*arg;\n\n#ifdef CONFIG_KSU_SUSFS\n\tif ((unsigned int)magic2 == 0xFAFAFAFA) {\n\t\treturn ksu_handle_susfs_sys_reboot(cmd, arg);\n\t}\n#endif\n\n\tif (magic2 == CHANGE_MANAGER_UID) {'
    if route_anchor in c:
        c = c.replace(route_anchor, route_repl, 1)
    else:
        print('[WARN] supercall.c SUSFS route anchor not found')

    with open(path, 'w') as f:
        f.write(c)
    print('[+] supercall.c patched for SUSFS dispatch')
PYEOF
        python3 ksu_susfs_dispatch_patch.py && rm -f ksu_susfs_dispatch_patch.py

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

config KSU_SUSFS_SUS_MAP
    bool "Hide suspicious memory maps"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_SU
    bool "SUS SU"
    depends on KSU_SUSFS
    default n
endmenu
EOF
    fi

    if [ "$ENABLE_SUS" = "true" ]; then
        echo "===> Mengaktifkan config KernelSU & SUSFS di defconfig..."
        cat "$GITHUB_WORKSPACE/configs/ksu_susfs.config" >> "$DEFCONFIG_PATH"
    else
        echo "===> Mengaktifkan config KernelSU Vanilla (No-SUSFS) di defconfig..."
        cat "$GITHUB_WORKSPACE/configs/ksu_vanilla.config" >> "$DEFCONFIG_PATH"
    fi
fi
