#!/bin/bash
set -e

cd "$GITHUB_WORKSPACE/kernel_source"

ENABLE_KSU="${1:-true}"
ENABLE_SUS="${2:-true}"
SUS_VER="${3:-v2.3.0}"
DEFCONFIG="${4:-vendor/fog-perf_defconfig}"
DEFCONFIG_PATH="arch/arm64/configs/$DEFCONFIG"

if [ "$ENABLE_KSU" = "true" ]; then
    echo "===> Mengintegrasikan ReSukiSU (Native Support untuk Non-GKI 4.19 & SuSFS)..."
    git clone https://github.com/ReSukiSU/ReSukiSU.git "$GITHUB_WORKSPACE/kernel_source/KernelSU"

    rm -rf drivers/kernelsu
    ln -sfn "$GITHUB_WORKSPACE/kernel_source/KernelSU/kernel" drivers/kernelsu
    test -f drivers/kernelsu/Kconfig || { echo "[-] ERROR: drivers/kernelsu/Kconfig does not exist!"; ls -la drivers/kernelsu; exit 1; }
    echo "[+] Verified drivers/kernelsu/Kconfig exists."

    grep -q "kernelsu" drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
    grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig

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
    print('[+] fs/read_write.c hooked!')

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
    print('[+] drivers/input/input.c hooked!')

# 8. security/selinux/selinuxfs.c
with open('security/selinux/selinuxfs.c', 'r') as f:
    c = f.read()
c = c.replace('static const struct file_operations sel_handle_status_ops = {', 'const struct file_operations sel_handle_status_ops = {', 1)
c = c.replace('static const struct file_operations transaction_ops = {', 'const struct file_operations transaction_ops = {', 1)
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

target = 'static int show_map_vma(struct seq_file *m, struct vm_area_struct *vma)'
replacement = '''#ifdef CONFIG_KSU_SUSFS_SUS_MAP
static inline bool susfs_is_vma_sus_map(struct vm_area_struct *vma) {
    struct file *file = vma->vm_file;
    if (file && SUSFS_IS_INODE_SUS_MAP(file_inode(file))) {
        return true;
    }
    return false;
}
#endif

static int show_map_vma(struct seq_file *m, struct vm_area_struct *vma)
{
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
    if (susfs_is_vma_sus_map(vma)) {
        return 0;
    }
#endif'''

if target in c and 'susfs_is_vma_sus_map' not in c:
    c = c.replace(target, replacement, 1)
    with open('fs/proc/task_mmu.c', 'w') as f:
        f.write(c)
    print('show_map_vma hooked for sus_map!')

with open('fs/proc/task_mmu.c', 'r') as f:
    c = f.read()

target_smap = 'static int show_smap(struct seq_file *m, void *v)'
replacement_smap = '''static int show_smap(struct seq_file *m, void *v)
{
    struct vm_area_struct *vma = v;
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
    if (susfs_is_vma_sus_map(vma)) {
        return 0;
    }
#endif'''

if target_smap in c and 'susfs_is_vma_sus_map(vma)' not in c:
    c = c.replace(target_smap, replacement_smap, 1)
    with open('fs/proc/task_mmu.c', 'w') as f:
        f.write(c)
    print('show_smap hooked for sus_map!')
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
