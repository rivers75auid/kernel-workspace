#!/bin/bash
set -e

cd "$GITHUB_WORKSPACE/kernel_source"

ENABLE_KSU="${1:-true}"
ENABLE_SUS="${2:-true}"
SUS_VER="${3:-v2.3.0}"
DEFCONFIG="${4:-vendor/fog-perf_defconfig}"
KSU_REF="${5:-v4.2.0-rc3}"
FIRST_DEFCONFIG=$(echo "$DEFCONFIG" | awk '{print $1}')
DEFCONFIG_PATH="arch/arm64/configs/$FIRST_DEFCONFIG"

if [ "$ENABLE_KSU" = "true" ]; then
    echo "===> Mengintegrasikan ReSukiSU (Native Support untuk Non-GKI 4.19 & SuSFS)..."
    case "$KSU_REF" in
      *[!0-9a-f]*|"" )
        git clone --depth=1 -b "$KSU_REF" https://github.com/ReSukiSU/ReSukiSU.git "$GITHUB_WORKSPACE/kernel_source/KernelSU"
        ;;
      * )
        if ! git clone --depth=1 -b "$KSU_REF" https://github.com/ReSukiSU/ReSukiSU.git "$GITHUB_WORKSPACE/kernel_source/KernelSU" 2>/dev/null; then
          rm -rf "$GITHUB_WORKSPACE/kernel_source/KernelSU"
          echo "===> KSU_REF is a commit SHA: fetching $KSU_REF directly..."
          git init -q "$GITHUB_WORKSPACE/kernel_source/KernelSU"
          git -C "$GITHUB_WORKSPACE/kernel_source/KernelSU" remote add origin https://github.com/ReSukiSU/ReSukiSU.git
          git -C "$GITHUB_WORKSPACE/kernel_source/KernelSU" fetch --depth=1 -q origin "$KSU_REF"
          git -C "$GITHUB_WORKSPACE/kernel_source/KernelSU" checkout -q --detach FETCH_HEAD
        fi
        ;;
    esac

    rm -rf drivers/kernelsu
    ln -sfn "$GITHUB_WORKSPACE/kernel_source/KernelSU/kernel" drivers/kernelsu
    test -f drivers/kernelsu/Kconfig || { echo "[-] ERROR: drivers/kernelsu/Kconfig does not exist!"; ls -la drivers/kernelsu; exit 1; }
    echo "[+] Verified drivers/kernelsu/Kconfig exists."

    grep -q "kernelsu" drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
    grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig

    echo "===> Un-static SELinux functions for ReSukiSU/BakaSU..."
    sed -i 's/^static void security_dump_masked_av/void security_dump_masked_av/' security/selinux/ss/services.c || true
    sed -i 's/^static void context_struct_compute_av/void context_struct_compute_av/' security/selinux/ss/services.c || true

    echo "===> Disarming artificial abort checks in KernelSU tools..."
    sed -i 's/\$(error/\$(warning/g' KernelSU/kernel/tools/*.mk 2>/dev/null || true

    echo "===> Menyesuaikan ReSukiSU sucompat untuk Linux 4.19..."
    python3 -c "
with open('KernelSU/kernel/feature/sucompat.h', 'r') as f:
    h = f.read()

target_h = '''#ifdef CONFIG_KSU_SUSFS
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#else'''

repl_h = '''#ifdef CONFIG_KSU_SUSFS
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#else
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif
#else'''

if target_h in h:
    h = h.replace(target_h, repl_h, 1)
    with open('KernelSU/kernel/feature/sucompat.h', 'w') as f:
        f.write(h)
    print('[+] sucompat.h successfully patched for 4.19!')

with open('KernelSU/kernel/feature/sucompat.c', 'r') as f:
    c = f.read()

t1 = '#ifdef CONFIG_KSU_SUSFS\nint ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)'
r1 = '#if defined(CONFIG_KSU_SUSFS) && LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\nint ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)'

t2 = '#ifdef CONFIG_KSU_SUSFS\nint ksu_handle_stat(int *dfd, struct filename **filename, int *flags)'
r2 = '#if defined(CONFIG_KSU_SUSFS) && LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\nint ksu_handle_stat(int *dfd, struct filename **filename, int *flags)'

if t1 in c and t2 in c:
    c = c.replace(t1, r1, 1).replace(t2, r2, 1)
    with open('KernelSU/kernel/feature/sucompat.c', 'w') as f:
        f.write(c)
    print('[+] sucompat.c successfully patched for 4.19!')
"

    echo "===> Menyesuaikan ReSukiSU supercall dispatch untuk SuSFS 4.19..."
    cat > patch_dispatch.py << 'PYEOF'
path = 'KernelSU/kernel/supercall/dispatch.c'
with open(path, 'r') as f:
    dc = f.read()

dc = dc.replace('#include <linux/susfs_def.h>', '#include <linux/susfs.h>\n#include <linux/susfs_def.h>')

pos_start = dc.find('#ifdef CONFIG_KSU_SUSFS\nint ksu_handle_susfs_cmd')
pos_end = dc.find('#ifdef CONFIG_KSU_TOOLKIT_SUPPORT', pos_start)

if pos_start != -1 and pos_end != -1:
    susfs_cmd_handler = r'''#ifdef CONFIG_KSU_SUSFS
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

int ksu_handle_susfs_cmd(unsigned int cmd, void __user **arg)
{
	switch (cmd) {
	case 0x55550: /* CMD_SUSFS_ADD_SUS_PATH */
	case 0x55553: /* CMD_SUSFS_ADD_SUS_PATH_LOOP */ {
		struct {
			char target_pathname[SUSFS_MAX_LEN_PATHNAME];
			int err;
		} info = {0};
		struct path p;
		mm_segment_t old_fs;

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
			old_fs = get_fs();
			set_fs(KERNEL_DS);
			susfs_add_sus_path((struct st_susfs_sus_path __user *)&k_info);
			set_fs(old_fs);
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
		mm_segment_t old_fs;

		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
		{
			struct st_susfs_sus_mount k_info = {0};
			strncpy(k_info.target_pathname, info.target_pathname, sizeof(k_info.target_pathname) - 1);
			k_info.target_dev = info.target_dev;
			old_fs = get_fs();
			set_fs(KERNEL_DS);
			susfs_add_sus_mount((struct st_susfs_sus_mount __user *)&k_info);
			set_fs(old_fs);
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
		mm_segment_t old_fs;

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
			old_fs = get_fs();
			set_fs(KERNEL_DS);
			if (cmd == 0x55571) {
				susfs_update_sus_kstat((struct st_susfs_sus_kstat __user *)&k_info);
			} else {
				susfs_add_sus_kstat((struct st_susfs_sus_kstat __user *)&k_info);
			}
			set_fs(old_fs);
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
		mm_segment_t old_fs;

		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
		{
			struct st_susfs_try_umount k_info = {0};
			strncpy(k_info.target_pathname, info.target_pathname, sizeof(k_info.target_pathname) - 1);
			k_info.mnt_mode = info.mnt_mode;
			old_fs = get_fs();
			set_fs(KERNEL_DS);
			susfs_add_try_umount((struct st_susfs_try_umount __user *)&k_info);
			set_fs(old_fs);
		}
#endif
		info.err = 0;
		if (copy_to_user((void __user*)*arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	case 0x555b0: /* CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG */ {
		int err = 0;
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
		susfs_set_cmdline_or_bootconfig((char __user*)*arg);
#endif
		/* ReSukiSU ksud uses 8192 buffer, simonpunk uses 4096; write 0 to both offsets */
		(void)copy_to_user((void __user*)(*arg + 4096), &err, sizeof(err));
		(void)copy_to_user((void __user*)(*arg + 8192), &err, sizeof(err));
		return 0;
	}
	case 0x555c0: /* CMD_SUSFS_ADD_OPEN_REDIRECT */ {
		struct {
			char target_pathname[SUSFS_MAX_LEN_PATHNAME];
			char redirected_pathname[SUSFS_MAX_LEN_PATHNAME];
			unsigned int uid_scheme;
			int err;
		} info = {0};
		mm_segment_t old_fs;

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
			old_fs = get_fs();
			set_fs(KERNEL_DS);
			susfs_add_open_redirect((struct st_susfs_open_redirect __user *)&k_info);
			set_fs(old_fs);
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
		mm_segment_t old_fs;

		if (copy_from_user(&info, (void __user*)*arg, sizeof(info)))
			return -EFAULT;
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
		{
			struct st_susfs_uname k_info = {0};
			strncpy(k_info.release, info.release, sizeof(k_info.release) - 1);
			strncpy(k_info.version, info.version, sizeof(k_info.version) - 1);
			old_fs = get_fs();
			set_fs(KERNEL_DS);
			susfs_set_uname((struct st_susfs_uname __user *)&k_info);
			set_fs(old_fs);
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
	case 0x555e4: /* CMD_SUSFS_SHOW_SUS_SU_WORKING_MODE */ {
		struct { int mode; int err; } info = { .mode = 0, .err = 0 };
		(void)copy_to_user((void __user*)*arg, &info, sizeof(info));
		return 0;
	}
	case 0x555f0: /* CMD_SUSFS_IS_SUS_SU_READY */ {
		struct { bool ready; int err; } info = { .ready = false, .err = 0 };
		(void)copy_to_user((void __user*)*arg, &info, sizeof(info));
		return 0;
	}
	case 0x60000: /* CMD_SUSFS_SUS_SU */ {
		struct { int mode; int err; } info = { .mode = 0, .err = 0 };
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
#endif'''

    dc = dc[:pos_start] + susfs_cmd_handler + '\n' + dc[pos_end:]
    with open(path, 'w') as f:
        f.write(dc)
    print('[+] ReSukiSU dispatch.c successfully wired to SuSFS 4.19!')
PYEOF
    python3 patch_dispatch.py && rm -f patch_dispatch.py

    echo "===> Membersihkan hook usang backslashxx di fs/exec.c (ReSukiSU memakai hook resmi do_execveat_common)..."
    python3 -c "
import re
with open('fs/exec.c', 'r') as f:
    c = f.read()

# 1. Hapus deklarasi extern ksu_handle_execve_sucompat / ksu_handle_execveat_sucompat
c = re.sub(r'#ifdef CONFIG_KSU\s+__attribute__\(\(hot\)\)\s+extern int ksu_handle_execve[^\)]*\);\s*#endif\s*', '', c, flags=re.DOTALL)
c = re.sub(r'extern int ksu_handle_execve(?:at)?_sucompat[^\n;]*;\s*', '', c)

# 2. Hapus panggilan hook lama di SYSCALL_DEFINE3(execve) dan COMPAT_SYSCALL_DEFINE3(execve)
c = re.sub(r'#ifdef CONFIG_KSU[^\n]*?\n\s*ksu_handle_execve.*?#endif\s*', '', c, flags=re.DOTALL)
c = re.sub(r'ksu_handle_execve(?:at)?_sucompat[^\n;]*;\s*', '', c)

with open('fs/exec.c', 'w') as f:
    f.write(c)
print('[+] fs/exec.c: hook usang ksu_handle_execve_sucompat berhasil dibersihkan!')
"

    echo "===> Menerapkan 8 Manual Kernel Hooks untuk ReSukiSU..."
    python3 -c "
# 1. kernel/sys.c
with open('kernel/sys.c', 'r') as f:
    c = f.read()
target_sys = 'long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)\n{\n'
hook_sys = '''\
#ifdef CONFIG_KSU
	extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
	ksu_handle_setresuid(ruid, euid, suid);
#endif
'''
if target_sys in c and 'ksu_handle_setresuid' not in c:
    c = c.replace(target_sys, target_sys + hook_sys, 1)
    with open('kernel/sys.c', 'w') as f:
        f.write(c)
    print('[+] kernel/sys.c hooked!')

# 2. kernel/reboot.c
with open('kernel/reboot.c', 'r') as f:
    c = f.read()
target_reboot = '\t/* We only trust the superuser with rebooting the system. */'
hook_reboot = '''\
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
		ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
		if (magic1 == 0xDEADBEEF)
			return 0;
	}
#endif
'''
if target_reboot in c and 'ksu_handle_sys_reboot' not in c:
    c = c.replace(target_reboot, hook_reboot + target_reboot, 1)
    with open('kernel/reboot.c', 'w') as f:
        f.write(c)
    print('[+] kernel/reboot.c hooked!')

# 3. fs/exec.c
with open('fs/exec.c', 'r') as f:
    c = f.read()
target_exec_hdr = 'static int do_execveat_common(int fd, struct filename *filename,'
hook_exec_hdr = '''\
#ifdef CONFIG_KSU
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags, int *retval);
#endif
'''
target_exec_body = '\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);'
hook_exec_body = '''\
#ifdef CONFIG_KSU
	int retval;
	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
	retval = __do_execve_file(fd, filename, argv, envp, flags, NULL);
	ksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);
	return retval;
#else
	return __do_execve_file(fd, filename, argv, envp, flags, NULL);
#endif
'''
if target_exec_hdr in c and 'ksu_handle_execveat' not in c:
    c = c.replace(target_exec_hdr, hook_exec_hdr + target_exec_hdr, 1)
    c = c.replace(target_exec_body, hook_exec_body, 1)
    with open('fs/exec.c', 'w') as f:
        f.write(c)
    print('[+] fs/exec.c hooked!')

# 4. fs/open.c
with open('fs/open.c', 'r') as f:
    c = f.read()
target_open = 'long do_faccessat(int dfd, const char __user *filename, int mode)\n{\n'
hook_open = '''\
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);
		ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
	}
#endif
'''
if target_open in c and 'ksu_handle_faccessat' not in c:
    c = c.replace(target_open, target_open + hook_open, 1)
    with open('fs/open.c', 'w') as f:
        f.write(c)
    print('[+] fs/open.c hooked!')

# 5. fs/read_write.c
with open('fs/read_write.c', 'r') as f:
    c = f.read()
# Clean up legacy ksu_vfs_read_hook from afterimage base
c = c.replace('extern bool ksu_vfs_read_hook __read_mostly;\n', '')
c = c.replace('extern bool ksu_vfs_read_hook __read_mostly;', '')
c = c.replace('if (unlikely(ksu_vfs_read_hook))\n\t\t', '')
c = c.replace('if (unlikely(ksu_vfs_read_hook)) ', '')
c = c.replace('ksu_vfs_read_hook', '1')

target_rw = 'SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n'
hook_rw = '''\
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
		ksu_handle_sys_read(fd, &buf, &count);
	}
#endif
'''
if target_rw in c and 'ksu_handle_sys_read' not in c:
    c = c.replace(target_rw, target_rw + hook_rw, 1)
with open('fs/read_write.c', 'w') as f:
    f.write(c)
print('[+] fs/read_write.c hooked and legacy ksu_vfs_read_hook cleaned!')

# 6. fs/stat.c (with native fake_ino=2 for Duck Detector)
with open('fs/stat.c', 'r') as f:
    c = f.read()
target_stat = 'SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,\n\t\tstruct stat __user *, statbuf, int, flag)\n{\n\tstruct kstat stat;\n\tint error;\n\n'
hook_stat = '''\
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
		ksu_handle_stat(&dfd, &filename, &flag);
	}
#endif
'''
stat_err_check = 'if (error)\n\t\treturn error;\n'
hook_spoof_ino = '''if (error)
		return error;
#ifdef CONFIG_KSU
	if (filename) {
		char pbuf[32];
		if (strncpy_from_user_nofault(pbuf, filename, sizeof(pbuf)) > 0) {
			if (!strcmp(pbuf, "/data/local/tmp") || !strcmp(pbuf, "/data/local/tmp/")) {
				stat.ino = 2;
			}
		}
	}
#endif
'''
if target_stat in c and 'ksu_handle_stat' not in c:
    c = c.replace(target_stat, target_stat + hook_stat, 1)
    c = c.replace(stat_err_check, hook_spoof_ino, 1)
    with open('fs/stat.c', 'w') as f:
        f.write(c)
    print('[+] fs/stat.c hooked!')

# 7. drivers/input/input.c
with open('drivers/input/input.c', 'r') as f:
    c = f.read()
# Clean up legacy ksu_input_hook from afterimage base
c = c.replace('extern bool ksu_input_hook __read_mostly;\n', '')
c = c.replace('extern bool ksu_input_hook __read_mostly;', '')
c = c.replace('if (unlikely(ksu_input_hook))\n\t\t', '')
c = c.replace('if (unlikely(ksu_input_hook)) ', '')
c = c.replace('ksu_input_hook', '1')

target_input = 'static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{\n'
hook_input = '''\
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
		ksu_handle_input_handle_event(&type, &code, &value);
	}
#endif
'''
if target_input in c and 'ksu_handle_input_handle_event' not in c:
    c = c.replace(target_input, target_input + hook_input, 1)
with open('drivers/input/input.c', 'w') as f:
    f.write(c)
print('[+] drivers/input/input.c hooked and legacy ksu_input_hook cleaned!')

# 8. security/selinux/selinuxfs.c
with open('security/selinux/selinuxfs.c', 'r') as f:
    c = f.read()
c = c.replace('static const struct file_operations sel_handle_status_ops = {', 'const struct file_operations sel_handle_status_ops = {', 1)
c = c.replace('static const struct file_operations transaction_ops = {', 'const struct file_operations transaction_ops = {', 1)
c = c.replace('static ssize_t (*const write_op[])', 'ssize_t (*const write_op[])', 1)
with open('security/selinux/selinuxfs.c', 'w') as f:
    f.write(c)
print('[+] security/selinux/selinuxfs.c un-static OK!')
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

        echo "===> Memperbaiki rejected hunks SuSFS di mount.h, sched.h, dan namespace.c..."
        python3 -c "
# 1. include/linux/mount.h
with open('include/linux/mount.h', 'r') as f:
    mh = f.read()
if 'susfs_mnt_id_backup' not in mh:
    mh = mh.replace('ANDROID_KABI_RESERVE(4);', '''#ifdef CONFIG_KSU_SUSFS
	u64 susfs_mnt_id_backup;
#endif
	ANDROID_KABI_RESERVE(4);''', 1)
    with open('include/linux/mount.h', 'w') as f:
        f.write(mh)
    print('[+] include/linux/mount.h patched for SuSFS!')

# 2. include/linux/sched.h
with open('include/linux/sched.h', 'r') as f:
    sh = f.read()
if 'susfs_last_fake_mnt_id' not in sh:
    sh = sh.replace('ANDROID_KABI_RESERVE(8);', '''#ifdef CONFIG_KSU_SUSFS
	u64 susfs_last_fake_mnt_id;
#endif
	ANDROID_KABI_RESERVE(8);''', 1)
    with open('include/linux/sched.h', 'w') as f:
        f.write(sh)
    print('[+] include/linux/sched.h patched for SuSFS!')

# 3. fs/namespace.c
with open('fs/namespace.c', 'r') as f:
    ns = f.read()
if 'DEFINE_IDA(susfs_mnt_id_ida)' not in ns:
    target_ns = '#include \"internal.h\"\n'
    repl_ns = '''#include \"internal.h\"

#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)
#include <linux/susfs_def.h>
#endif

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_current_zygote_domain(void);

static DEFINE_IDA(susfs_mnt_id_ida);
static DEFINE_IDA(susfs_mnt_group_ida);

#define CL_ZYGOTE_COPY_MNT_NS BIT(24) /* used by copy_mnt_ns() */
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
#endif

#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
extern void susfs_auto_add_sus_ksu_default_mount(const char __user *to_pathname);
bool susfs_is_auto_add_sus_ksu_default_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
extern int susfs_auto_add_sus_bind_mount(const char *pathname, struct path *path_target);
bool susfs_is_auto_add_sus_bind_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
extern void susfs_auto_add_try_umount_for_bind_mount(struct path *path);
bool susfs_is_auto_add_try_umount_for_bind_mount_enabled = true;
#endif
'''
    ns = ns.replace(target_ns, repl_ns, 1)

# Fix alloc_vfsmnt in vfs_create_mount()
vfs_create_orig = 'mnt = alloc_vfsmnt(fc->source ?: \"none\");'
vfs_create_repl = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (unlikely(susfs_is_current_ksu_domain())) {
\t\tmnt = alloc_vfsmnt(fc->source ?: \"none\", true, 0);
\t\tgoto bypass_orig_flow;
\t}
\tmnt = alloc_vfsmnt(fc->source ?: \"none\", false, 0);
bypass_orig_flow:
#else
\tmnt = alloc_vfsmnt(fc->source ?: \"none\");
#endif'''
if vfs_create_orig in ns:
    ns = ns.replace(vfs_create_orig, vfs_create_repl, 1)

# Add zygote fake_mnt_id in vfs_create_mount()
vfs_parent = 'mnt->mnt_parent\t\t= mnt;'
vfs_parent_repl = '''mnt->mnt_parent\t\t= mnt;

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (susfs_is_current_zygote_domain()) {
\t\tmnt->mnt.susfs_mnt_id_backup = mnt->mnt_id;
\t\tmnt->mnt_id = current->susfs_last_fake_mnt_id++;
\t}
#endif'''
if vfs_parent in ns and 'susfs_last_fake_mnt_id' not in ns:
    ns = ns.replace(vfs_parent, vfs_parent_repl, 1)

# Fix alloc_vfsmnt in clone_mnt()
clone_orig = 'mnt = alloc_vfsmnt(old->mnt_devname);'
clone_repl = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tbool is_current_ksu_domain = susfs_is_current_ksu_domain();
\tbool is_current_zygote_domain = susfs_is_current_zygote_domain();

\tif (unlikely(is_current_ksu_domain)) {
\t\tif (!(flag & CL_COPY_MNT_NS)) {
\t\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, 0);
\t\t\tgoto bypass_orig_flow_clone;
\t\t}
\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, old->mnt_id);
\t\tif (mnt) {
\t\t\tmnt->mnt.susfs_mnt_id_backup = DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE;
\t\t}
\t\tgoto bypass_orig_flow_clone;
\t}
\tif (likely(is_current_zygote_domain) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {
\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, 0);
\t\tgoto bypass_orig_flow_clone;
\t}
\tif ((flag & CL_COPY_MNT_NS) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {
\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, 0);
\t\tgoto bypass_orig_flow_clone;
\t}
\tmnt = alloc_vfsmnt(old->mnt_devname, false, 0);
bypass_orig_flow_clone:
#else
\tmnt = alloc_vfsmnt(old->mnt_devname);
#endif'''
if clone_orig in ns:
    ns = ns.replace(clone_orig, clone_repl, 1)

with open('fs/namespace.c', 'w') as f:
    f.write(ns)
print('[+] fs/namespace.c patched for SuSFS!')

# 4. kernel/sys.c (uname spoofing)
with open('kernel/sys.c', 'r') as f:
    sys_c = f.read()
if 'susfs_spoof_uname' not in sys_c:
    uname_target = 'SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)'
    uname_repl = '''#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
extern void susfs_spoof_uname(struct new_utsname* tmp);
#endif
SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)'''
    sys_c = sys_c.replace(uname_target, uname_repl, 1)
    
    memcpy_target = 'memcpy(&tmp, utsname(), sizeof(tmp));'
    memcpy_repl = '''memcpy(&tmp, utsname(), sizeof(tmp));
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\tsusfs_spoof_uname(&tmp);
#endif'''
    sys_c = sys_c.replace(memcpy_target, memcpy_repl, 1)
    with open('kernel/sys.c', 'w') as f:
        f.write(sys_c)
    print('[+] kernel/sys.c patched for SuSFS uname spoofing!')
"

        echo "===> Menambahkan susfs_extra_works dan sdcard monitor ke fs/susfs.c..."
        python3 -c "
with open('fs/susfs.c', 'r') as f:
    c = f.read()

target = '/* susfs_init */\nvoid susfs_init(void) {\n\tspin_lock_init(&susfs_spin_lock);'
repl = '''struct work_struct susfs_extra_works;
static void susfs_run_extra_works(struct work_struct *work) {}
void susfs_start_sdcard_monitor_fn(void) {}

/* susfs_init */
void susfs_init(void) {
	INIT_WORK(&susfs_extra_works, susfs_run_extra_works);
	spin_lock_init(&susfs_spin_lock);'''

if target in c:
    c = c.replace(target, repl, 1)
    with open('fs/susfs.c', 'w') as f:
        f.write(c)
    print('[+] fs/susfs.c extra works added!')
"

        echo "===> Memastikan header susfs_def.h terpasang di fs.h dan task_mmu.c..."
        sed -i '/#define _LINUX_FS_H/a #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif' include/linux/fs.h || true
        grep -q "susfs_def.h" fs/proc/task_mmu.c || sed -i '1i #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif' fs/proc/task_mmu.c || true

        echo "===> Menambahkan dukungan SUS_MAP, SUSFS_MAGIC, dan GKI SuSFS helpers ke header SuSFS..."
        cat << 'EOF' >> include/linux/susfs_def.h

#ifndef _KSU_SUSFS_DEF_EXT_H
#define _KSU_SUSFS_DEF_EXT_H

#ifndef SUSFS_MAGIC
#define SUSFS_MAGIC 0xFAFAFAFA
#endif
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

#include <linux/thread_info.h>
#ifndef TIF_PROC_UMOUNTED
#define TIF_PROC_UMOUNTED 33
#endif
#ifndef TIF_PROC_NO_SU
#define TIF_PROC_NO_SU 34
#endif
#ifndef TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT
#define TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT 35
#endif

static inline bool susfs_is_current_proc_umounted(void) {
	return (likely(test_thread_flag(TIF_PROC_UMOUNTED)));
}

static inline void susfs_set_current_proc_umounted(void) {
	set_thread_flag(TIF_PROC_UMOUNTED);
}

static inline void susfs_clear_current_proc_umounted(void) {
	clear_thread_flag(TIF_PROC_UMOUNTED);
}

static inline bool susfs_is_current_proc_umounted_for_zygote_next(void) {
	return (likely(test_thread_flag(TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT)));
}

static inline void susfs_set_current_proc_umounted_for_zygote_next(void) {
	set_thread_flag(TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT);
}

static inline void susfs_clear_current_proc_umounted_for_zygote_next(void) {
	clear_thread_flag(TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT);
}

static inline bool susfs_is_current_proc_no_su(void) {
	return (likely(test_thread_flag(TIF_PROC_NO_SU)));
}

static inline void susfs_set_current_proc_no_su(void) {
	set_thread_flag(TIF_PROC_NO_SU);
}

static inline void susfs_clear_current_proc_no_su(void) {
	clear_thread_flag(TIF_PROC_NO_SU);
}
#endif /* _KSU_SUSFS_DEF_EXT_H */
EOF

        cat << 'EOF' >> include/linux/susfs.h

#ifndef _KSU_SUSFS_EXT_H
#define _KSU_SUSFS_EXT_H
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
struct st_susfs_sus_map {
    char target_pathname[256];
    int err;
};
void susfs_add_sus_map(void __user **user_info);
#endif
#endif /* _KSU_SUSFS_EXT_H */
EOF

        echo "===> Menerapkan hook SUS_MAP ke fs/proc/task_mmu.c..."
        python3 -c "
with open('fs/proc/task_mmu.c', 'r') as f:
    c = f.read()

target_vma = 'static void\nshow_map_vma(struct seq_file *m, struct vm_area_struct *vma)\n{\n'
repl_vma = '''#ifdef CONFIG_KSU_SUSFS_SUS_MAP
static inline bool susfs_is_vma_sus_map(struct vm_area_struct *vma) {
    struct file *file = vma->vm_file;
    if (file && SUSFS_IS_INODE_SUS_MAP(file_inode(file))) {
        return true;
    }
    return false;
}
#endif

static void
show_map_vma(struct seq_file *m, struct vm_area_struct *vma)
{
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
    if (susfs_is_vma_sus_map(vma)) {
        return;
    }
#endif
'''

if target_vma in c and 'susfs_is_vma_sus_map' not in c:
    c = c.replace(target_vma, repl_vma, 1)
    print('show_map_vma hooked for sus_map!')

target_smap = 'static int show_smap(struct seq_file *m, void *v)\n{\n\tstruct vm_area_struct *vma = v;\n\tstruct mem_size_stats mss;\n'
repl_smap = '''static int show_smap(struct seq_file *m, void *v)
{
	struct vm_area_struct *vma = v;
	struct mem_size_stats mss;
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	if (susfs_is_vma_sus_map(vma)) {
		return 0;
	}
#endif
'''

if target_smap in c and 'susfs_is_vma_sus_map(vma)' not in c:
    c = c.replace(target_smap, repl_smap, 1)
    print('show_smap hooked for sus_map!')

with open('fs/proc/task_mmu.c', 'w') as f:
    f.write(c)
"

        echo "===> Menambahkan implementasi susfs_add_sus_map ke fs/susfs.c..."
        cat << 'EOF' >> fs/susfs.c

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
EOF
    fi

    echo "===> Menerapkan konfigurasi KSU dan SUSFS..."
    cat "$GITHUB_WORKSPACE/configs/ksu_susfs.config" >> "$DEFCONFIG_PATH"
    echo "[+] Konfigurasi KernelSU dan SUSFS berhasil disatukan."
fi
