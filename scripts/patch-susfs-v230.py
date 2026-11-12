#!/usr/bin/env python3
"""Apply authentic SuSFS v2.3.0 hooks cleanly onto Linux 4.19.325 (cirno-pin)."""

import os
import sys


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write_text(path, content):
    with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
        f.write(content)


def replace_once(text, target, replacement, label):
    count = text.count(target)
    if count != 1:
        raise RuntimeError(f"[{label}] Expected 1 match, found {count} for:\n{target[:200]}")
    return text.replace(target, replacement, 1)


def replace_optional(text, target, replacement):
    if target in text:
        return text.replace(target, replacement, 1)
    return text


def apply_patches(root, patches):
    for rel_path, fn in patches:
        full_path = os.path.join(root, rel_path)
        if not os.path.isfile(full_path):
            raise FileNotFoundError(f"Missing target kernel file: {full_path}")
        orig = read_text(full_path)
        updated = fn(orig, rel_path)
        if updated != orig:
            write_text(full_path, updated)
            print(f"[OK] Patched {rel_path}")
        else:
            print(f"[SKIP] No changes needed in {rel_path}")


def patch_fs_makefile(text, label):
    if "obj-$(CONFIG_KSU_SUSFS) += susfs.o" in text:
        return text
    return replace_once(
        text,
        "ifeq ($(CONFIG_BLOCK),y)",
        "obj-$(CONFIG_KSU_SUSFS) += susfs.o\n\nifeq ($(CONFIG_BLOCK),y)",
        label,
    )


def patch_drivers_input(text, label):
    if "ksu_is_input_hook_enabled" in text:
        return text
    target = """#ifdef CONFIG_KSU
extern bool ksu_input_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
\t\t\tunsigned int *type, unsigned int *code, int *value);
#endif

void input_event(struct input_dev *dev,
\t\t unsigned int type, unsigned int code, int value)
{
\tunsigned long flags;

#ifdef CONFIG_KSU
\tif (unlikely(ksu_input_hook))
\t\tksu_handle_input_handle_event(&type, &code, &value);
#endif"""
    replacement = """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_is_input_hook_enabled;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
\t\t\tunsigned int *type, unsigned int *code, int *value);
#endif

void input_event(struct input_dev *dev,
\t\t unsigned int type, unsigned int code, int value)
{
\tunsigned long flags;

#ifdef CONFIG_KSU_SUSFS
\tif (static_branch_unlikely(&ksu_is_input_hook_enabled))
\t\tksu_handle_input_handle_event(&type, &code, &value);
#endif"""
    if target in text:
        return replace_once(text, target, replacement, label)
    return replace_once(
        text,
        "void input_event(struct input_dev *dev,\n\t\t unsigned int type, unsigned int code, int value)\n{\n\tunsigned long flags;",
        replacement,
        label,
    )


def patch_fs_open(text, label):
    if "susfs_is_current_proc_no_su" in text:
        return text
    text = replace_once(
        text,
        '#include "internal.h"',
        '#include "internal.h"\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif',
        label + ":inc",
    )
    # Strip legacy manual KSU hook in faccessat syscall
    old_syscall_hook = """#ifdef CONFIG_KSU
__attribute__((hot)) 
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
\t\t\t\tint *mode, int *flags);
#endif

SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#ifdef CONFIG_KSU
\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif"""
    new_syscall = """SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{"""
    text = replace_optional(text, old_syscall_hook, new_syscall)

    target_decl = """long do_faccessat(int dfd, const char __user *filename, int mode)
{
\tconst struct cred *old_cred;
\tstruct cred *override_cred;
\tstruct path path;
\tstruct inode *inode;
\tstruct vfsmount *mnt;
\tint res;
\tunsigned int lookup_flags = LOOKUP_FOLLOW;"""
    repl_decl = """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_su_compat_enabled;
extern bool __ksu_is_allow_uid_for_current(uid_t uid);
extern __attribute__((hot)) int ksu_handle_faccessat(int *dfd, struct filename **filename_user, int *mode,
\t\t\t\tint *__unused_flags);
#endif

long do_faccessat(int dfd, const char __user *filename, int mode)
{
\tconst struct cred *old_cred;
\tstruct cred *override_cred;
\tstruct path path;
\tstruct inode *inode;
\tstruct vfsmount *mnt;
\tint res;
\tunsigned int lookup_flags = LOOKUP_FOLLOW;
#ifdef CONFIG_KSU_SUSFS
\tstruct filename *fname;
#endif"""
    text = replace_once(text, target_decl, repl_decl, label + ":decl")

    target_lookup = """retry:
\tres = user_path_at(dfd, filename, lookup_flags, &path);"""
    repl_lookup = """retry:
#ifdef CONFIG_KSU_SUSFS
\tfname = getname_flags(filename, lookup_flags, NULL);
\tif (IS_ERR(fname)) {
\t\tres = PTR_ERR(fname);
\t\tgoto out;
\t}
\tif (static_branch_likely(&ksu_su_compat_enabled)) {
\t\tif (!susfs_is_current_proc_no_su() &&
\t\t    __ksu_is_allow_uid_for_current(current_uid().val)) {
\t\t\tksu_handle_faccessat(&dfd, &fname, &mode, NULL);
\t\t}
\t}
\tres = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
\tres = user_path_at(dfd, filename, lookup_flags, &path);
#endif"""
    return replace_once(text, target_lookup, repl_lookup, label + ":lookup")


def patch_fs_read_write(text, label):
    if "ksu_handle_sys_read" in text:
        return text
    text = replace_once(
        text,
        '#include "internal.h"',
        '#include "internal.h"\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif',
        label + ":inc",
    )
    target = """ssize_t ksys_read(unsigned int fd, char __user *buf, size_t count)
{
\tstruct fd f = fdget_pos(fd);
\tssize_t ret = -EBADF;

\tif (f.file) {"""
    repl = """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_is_init_rc_hook_enabled;
extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,
\t\t\tsize_t *count_ptr);
#endif

ssize_t ksys_read(unsigned int fd, char __user *buf, size_t count)
{
\tstruct fd f = fdget_pos(fd);
\tssize_t ret = -EBADF;

#ifdef CONFIG_KSU_SUSFS
\tif (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
\t\tksu_handle_sys_read(fd, &buf, &count);
#endif

\tif (f.file) {"""
    return replace_once(text, target, repl, label + ":ksys_read")


def patch_fs_stat(text, label):
    if "STATX_SUS_KSTAT_FUSE" in text:
        return text
    text = replace_once(
        text,
        "#include <linux/compat.h>",
        '#include <linux/compat.h>\n#include "internal.h"\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif',
        label + ":inc",
    )
    # Strip legacy manual KSU hooks in newfstatat and fstatat64
    text = replace_optional(
        text,
        """#ifdef CONFIG_KSU
__attribute__((hot)) 
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
\t\t\t\tint *flags);
#endif

#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)""",
        "#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)",
    )
    text = replace_optional(
        text,
        """#ifdef CONFIG_KSU
\tksu_handle_stat(&dfd, &filename, &flag);
#endif
\terror = vfs_fstatat(dfd, filename, &stat, flag);""",
        "\terror = vfs_fstatat(dfd, filename, &stat, flag);",
    )
    text = replace_optional(
        text,
        """#ifdef CONFIG_KSU // 32-bit su
\tksu_handle_stat(&dfd, &filename, &flag);
#endif
\terror = vfs_fstatat(dfd, filename, &stat, flag);""",
        "\terror = vfs_fstatat(dfd, filename, &stat, flag);",
    )

    # Hook generic_fillattr / vfs_getattr_nosec / vfs_statx_fd / vfs_statx
    text = replace_once(
        text,
        """int vfs_getattr_nosec(const struct path *path, struct kstat *stat,
\t\t      u32 request_mask, unsigned int query_flags)""",
        """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
extern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);
extern void susfs_sus_kstat_spoof_generic_fillattr(struct inode *inode, struct kstat *stat, u32 result_mask);
#endif

int vfs_getattr_nosec(const struct path *path, struct kstat *stat,
\t\t      u32 request_mask, unsigned int query_flags)""",
        label + ":getattr_decl",
    )
    text = replace_once(
        text,
        """\tif (inode->i_op->getattr)
\t\treturn inode->i_op->getattr(path, stat, request_mask,
\t\t\t\t\t    query_flags);

\tgeneric_fillattr(inode, stat);
\treturn 0;""",
        """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\tif (susfs_is_current_app_uid()) {
\t\tbool is_fuse = false;
\t\tif (susfs_is_inode_sus_kstat(inode, &is_fuse)) {
\t\t\tint ret = 0;
\t\t\tif (inode->i_op->getattr)
\t\t\t\tret = inode->i_op->getattr(path, stat, request_mask, query_flags);
\t\t\telse
\t\t\t\tgeneric_fillattr(inode, stat);
\t\t\tif (!ret) {
\t\t\t\tif (is_fuse)
\t\t\t\t\tsusfs_sus_kstat_spoof_generic_fillattr(inode, stat, STATX_SUS_KSTAT_FUSE);
\t\t\t\telse
\t\t\t\t\tsusfs_sus_kstat_spoof_generic_fillattr(inode, stat, STATX_SUS_KSTAT);
\t\t\t}
\t\t\treturn ret;
\t\t}
\t}
#endif
\tif (inode->i_op->getattr)
\t\treturn inode->i_op->getattr(path, stat, request_mask,
\t\t\t\t\t    query_flags);

\tgeneric_fillattr(inode, stat);
\treturn 0;""",
        label + ":getattr_body",
    )

    text = replace_once(
        text,
        """int vfs_statx_fd(unsigned int fd, struct kstat *stat,
\t\t u32 request_mask, unsigned int query_flags)
{
\tstruct fd f;
\tint error = -EBADF;

\tif (query_flags & ~KSTAT_QUERY_FLAGS)
\t\treturn -EINVAL;

\tf = fdget_raw(fd);
\tif (f.file) {
\t\terror = vfs_getattr(&f.file->f_path, stat,
\t\t\t\t    request_mask, query_flags);
\t\tfdput(f);
\t}
\treturn error;
}""",
        """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_is_init_rc_hook_enabled;
extern int ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);
#endif

int vfs_statx_fd(unsigned int fd, struct kstat *stat,
\t\t u32 request_mask, unsigned int query_flags)
{
\tstruct fd f;
\tint error = -EBADF;

\tif (query_flags & ~KSTAT_QUERY_FLAGS)
\t\treturn -EINVAL;

\tf = fdget_raw(fd);
\tif (f.file) {
\t\terror = vfs_getattr(&f.file->f_path, stat,
\t\t\t\t    request_mask, query_flags);
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\t\tif (!error)
\t\t\tstat->result_mask &= ~(STATX_SUS_KSTAT_FUSE | STATX_SUS_KSTAT);
#endif
\t\tfdput(f);
\t}
#ifdef CONFIG_KSU_SUSFS
\tif (!error && static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
\t\tksu_handle_vfs_fstat(fd, &stat->size);
#endif
\treturn error;
}""",
        label + ":statx_fd",
    )

    text = replace_once(
        text,
        """int vfs_statx(int dfd, const char __user *filename, int flags,
\t      struct kstat *stat, u32 request_mask)
{
\tstruct path path;
\tint error = -EINVAL;
\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;""",
        """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_su_compat_enabled;
extern struct static_key_true ksu_is_init_rc_hook_enabled;
extern bool __ksu_is_allow_uid_for_current(uid_t uid);
extern __attribute__((hot)) int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#endif

int vfs_statx(int dfd, const char __user *filename, int flags,
\t      struct kstat *stat, u32 request_mask)
{
\tstruct path path;
\tint error = -EINVAL;
\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;
#ifdef CONFIG_KSU_SUSFS
\tstruct filename *fname;
#endif""",
        label + ":statx_decl",
    )

    text = replace_once(
        text,
        """retry:
\terror = user_path_at(dfd, filename, lookup_flags, &path);
\tif (error)
\t\tgoto out;

\terror = vfs_getattr(&path, stat, request_mask, flags);
\tpath_put(&path);""",
        """retry:
#ifdef CONFIG_KSU_SUSFS
\tfname = getname_flags(filename, lookup_flags, NULL);
\tif (IS_ERR(fname)) {
\t\terror = PTR_ERR(fname);
\t\tgoto out;
\t}
\tif (static_branch_unlikely(&ksu_is_init_rc_hook_enabled) ||
\t    (static_branch_likely(&ksu_su_compat_enabled) &&
\t     !susfs_is_current_proc_no_su() &&
\t     __ksu_is_allow_uid_for_current(current_uid().val))) {
\t\tksu_handle_stat(&dfd, &fname, &flags);
\t}
\terror = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
\terror = user_path_at(dfd, filename, lookup_flags, &path);
#endif
\tif (error)
\t\tgoto out;

\terror = vfs_getattr(&path, stat, request_mask, flags);
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\tif (!error)
\t\tstat->result_mask &= ~(STATX_SUS_KSTAT_FUSE | STATX_SUS_KSTAT);
#endif
\tpath_put(&path);""",
        label + ":statx_body",
    )
    return text


def patch_fs_exec(text, label):
    if "ksu_handle_execveat" in text:
        return text
    text = replace_once(
        text,
        "#include <linux/vmalloc.h>",
        "#include <linux/vmalloc.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif",
        label + ":inc",
    )
    # Strip legacy manual KSU hooks in sys_execve / compat_sys_execve
    text = replace_optional(
        text,
        """#ifdef CONFIG_KSU
__attribute__((hot))
extern int ksu_handle_execve_sucompat(int *fd,\tconst char __user **filename_user,
\t\t\t\tvoid *__never_use_argv,\tvoid *__never_use_envp,
\t\t\t\tint *__never_use_flags);
#endif

SYSCALL_DEFINE3(execve,""",
        "SYSCALL_DEFINE3(execve,",
    )
    text = replace_optional(
        text,
        """#ifdef CONFIG_KSU
\tksu_handle_execve_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);
#endif
\treturn do_execve(getname(filename), argv, envp);""",
        "\treturn do_execve(getname(filename), argv, envp);",
    )
    text = replace_optional(
        text,
        """#ifdef CONFIG_KSU // 32-bit ksud and 32-on-64 support
\tksu_handle_execve_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);
#endif
\treturn compat_do_execve(getname(filename), argv, envp);""",
        "\treturn compat_do_execve(getname(filename), argv, envp);",
    )

    target_top = """static int __do_execve_file(int fd, struct filename *filename,
\t\t\t    struct user_arg_ptr argv,
\t\t\t    struct user_arg_ptr envp,
\t\t\t    int flags, struct file *file)
{
\tchar *pathbuf = NULL;
\tstruct linux_binprm bprm;
\tstruct files_struct *displaced;
\tint retval;

\tif (IS_ERR(filename))
\t\treturn PTR_ERR(filename);"""

    repl_top = """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_su_compat_enabled;
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
\t\t\tvoid *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,
\t\t\t\tvoid *envp, int *flags);
extern int ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,
\t\t\t\tvoid *envp, int *flags, int *retval);
#ifndef KSU_NO_PREINIT
extern int ksu_setup_preinit_file(struct filename **filename_ptr, struct user_arg_ptr *argv_user);
extern int ksu_preinit_handle_post_execveat(int *fd, struct filename **filename_ptr,
\t\t\t\tvoid *argv_user, void *envp_user,
\t\t\t\tint *flags, int *retval, int *preinit_fd);
#endif
#endif

static int __do_execve_file(int fd, struct filename *filename,
\t\t\t    struct user_arg_ptr argv,
\t\t\t    struct user_arg_ptr envp,
\t\t\t    int flags, struct file *file)
{
\tchar *pathbuf = NULL;
\tstruct linux_binprm bprm;
\tstruct files_struct *displaced;
\tint retval;
#ifdef CONFIG_KSU_SUSFS
\tbool is_su_session = false;
#ifndef KSU_NO_PREINIT
\tbool is_ksu_preinit_session = false;
\tint preinit_fd = 0;
#endif
#endif

\tif (IS_ERR(filename))
\t\treturn PTR_ERR(filename);

#ifdef CONFIG_KSU_SUSFS
\tif (unlikely(!filename) || likely(susfs_is_current_proc_no_su()))
\t\tgoto orig_flow;

\tif (static_branch_likely(&ksu_su_compat_enabled)) {
\t\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted))
\t\t\tis_su_session = !ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
\t\telse
\t\t\tis_su_session = !ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
\t}

#ifndef KSU_NO_PREINIT
\tif (unlikely(current->pid == 1) && !is_su_session) {
\t\tif (fd == AT_FDCWD || !(flags & AT_EMPTY_PATH)) {
\t\t\tpreinit_fd = ksu_setup_preinit_file(&filename, &argv);
\t\t\tif (preinit_fd > 0)
\t\t\t\tis_ksu_preinit_session = true;
\t\t}
\t}
#endif

orig_flow:
#endif"""
    text = replace_once(text, target_top, repl_top, label + ":top")

    target_open = """\tif (!file)
\t\tfile = do_open_execat(fd, filename, flags);
\tretval = PTR_ERR(file);
\tif (IS_ERR(file))
\t\tgoto out_unmark;"""
    repl_open = """\tif (!file)
\t\tfile = do_open_execat(fd, filename, flags);
\tretval = PTR_ERR(file);
\tif (IS_ERR(file)) {
#if defined(CONFIG_KSU_SUSFS) && !defined(KSU_NO_PREINIT)
\t\tif (unlikely(is_ksu_preinit_session) &&
\t\t    ksu_preinit_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval, &preinit_fd)) {
\t\t\tgoto susfs_retry_preinit;
\t\t}
#endif
\t\tgoto out_unmark;
\t}"""
    text = replace_once(text, target_open, repl_open, label + ":open")

    target_post = """\tretval = exec_binprm(&bprm);
\tif (retval < 0)
\t\tgoto out;"""
    repl_post = """\tretval = exec_binprm(&bprm);
#ifdef CONFIG_KSU_SUSFS
\tif (unlikely(is_su_session))
\t\t(void)ksu_handle_post_execveat_sucompat(&fd, &filename, &argv, &envp, &flags, &retval);
#ifndef KSU_NO_PREINIT
\tif (unlikely(is_ksu_preinit_session) &&
\t    ksu_preinit_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval, &preinit_fd)) {
susfs_retry_preinit:
\t\tif (bprm.mm) {
\t\t\tacct_arg_size(&bprm, 0);
\t\t\tmmput(bprm.mm);
\t\t}
\t\tcurrent->fs->in_exec = 0;
\t\tcurrent->in_execve = 0;
\t\tfree_bprm(&bprm);
\t\tkfree(pathbuf);
\t\tpathbuf = NULL;
\t\tif (displaced)
\t\t\treset_files_struct(displaced);
\t\tfile = NULL;
\t\tis_ksu_preinit_session = false;
\t\tgoto orig_flow;
\t}
#endif
#endif
\tif (retval < 0)
\t\tgoto out;"""
    return replace_once(text, target_post, repl_post, label + ":post")


def patch_fs_namei(text, label):
    if "susfs_is_inode_sus_path" in text:
        return text
    text = replace_once(
        text,
        "#include <linux/build_bug.h>",
        "#include <linux/build_bug.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif",
        label + ":inc",
    )
    text = replace_once(
        text,
        '#include "mount.h"',
        """#include "mount.h"

#ifdef CONFIG_KSU_SUSFS_SUS_PATH
extern bool susfs_is_inode_sus_path(struct inode *inode);
extern const struct qstr susfs_fake_qstr_name;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
extern struct filename *susfs_open_redirect_spoof_do_sys_openat(struct inode *inode);
extern int susfs_open_redirect_spoof_vfs_readlink(struct inode *inode, char __user *buffer, int buflen);
#endif""",
        label + ":ext",
    )
    text = replace_once(
        text,
        """\tint\t\ttotal_link_count;
\tstruct saved {
\t\tstruct path link;
\t\tstruct delayed_call done;
\t\tconst char *name;
\t\tunsigned seq;
\t} *stack, internal[EMBEDDED_LEVELS];
\tstruct filename\t*name;
\tstruct nameidata *saved;
\tstruct inode\t*link_inode;
\tunsigned\troot_seq;
\tint\t\tdfd;
} __randomize_layout;""",
        """\tint\t\ttotal_link_count;
\tstruct saved {
\t\tstruct path link;
\t\tstruct delayed_call done;
\t\tconst char *name;
\t\tunsigned seq;
\t} *stack, internal[EMBEDDED_LEVELS];
\tstruct filename\t*name;
\tstruct nameidata *saved;
\tstruct inode\t*link_inode;
\tunsigned\troot_seq;
\tint\t\tdfd;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tunsigned\tstate;
#endif
} __randomize_layout;""",
        label + ":nd_struct",
    )
    text = replace_once(
        text,
        "\tp->total_link_count = old ? old->total_link_count : 0;\n\tp->saved = old;",
        "\tp->total_link_count = old ? old->total_link_count : 0;\n\tp->saved = old;\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tp->state = 0;\n#endif",
        label + ":set_nd",
    )
    text = replace_once(
        text,
        """static struct dentry *lookup_dcache(const struct qstr *name,
\t\t\t\t    struct dentry *dir,
\t\t\t\t    unsigned int flags)
{
\tstruct dentry *dentry = d_lookup(dir, name);
\tif (dentry) {""",
        """static struct dentry *lookup_dcache(const struct qstr *name,
\t\t\t\t    struct dentry *dir,
\t\t\t\t    unsigned int flags)
{
\tstruct dentry *dentry = d_lookup(dir, name);
\tif (dentry) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\t\tif (!IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {
\t\t\tdput(dentry);
\t\t\tdentry = d_lookup(dir, &susfs_fake_qstr_name);
\t\t}
#endif""",
        label + ":lookup_dcache",
    )
    text = replace_once(
        text,
        """static struct dentry *__lookup_hash(const struct qstr *name,
\t\tstruct dentry *base, unsigned int flags)
{
\tstruct dentry *dentry = lookup_dcache(name, base, flags);
\tstruct dentry *old;
\tstruct inode *dir = base->d_inode;

\tif (dentry)
\t\treturn dentry;

\t/* Don't create child dentry for a dead directory. */
\tif (unlikely(IS_DEADDIR(dir)))
\t\treturn ERR_PTR(-ENOENT);

\tdentry = d_alloc(base, name);""",
        """static struct dentry *__lookup_hash(const struct qstr *name,
\t\tstruct dentry *base, unsigned int flags)
{
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tbool found_sus_path = false;
#endif
\tstruct dentry *dentry = lookup_dcache(name, base, flags);
\tstruct dentry *old;
\tstruct inode *dir = base->d_inode;

\tif (dentry) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\t\tif (!IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {
\t\t\tfound_sus_path = true;
\t\t\tdput(dentry);
\t\t\tgoto retry_lookup_sus;
\t\t}
#endif
\t\treturn dentry;
\t}

#ifdef CONFIG_KSU_SUSFS_SUS_PATH
retry_lookup_sus:
#endif
\t/* Don't create child dentry for a dead directory. */
\tif (unlikely(IS_DEADDIR(dir)))
\t\treturn ERR_PTR(-ENOENT);

#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tif (unlikely(found_sus_path))
\t\tdentry = d_alloc(base, &susfs_fake_qstr_name);
\telse
\t\tdentry = d_alloc(base, name);
#else
\tdentry = d_alloc(base, name);
#endif""",
        label + ":__lookup_hash",
    )
    text = replace_once(
        text,
        """\t\tif (unlikely(__read_seqcount_retry(&parent->d_seq, nd->seq)))
\t\t\treturn -ECHILD;

\t\t*seqp = seq;""",
        """\t\tif (unlikely(__read_seqcount_retry(&parent->d_seq, nd->seq)))
\t\t\treturn -ECHILD;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\t\tif (*inode && susfs_is_inode_sus_path(*inode))
\t\t\treturn -ECHILD;
#endif

\t\t*seqp = seq;""",
        label + ":lookup_fast_rcu",
    )
    text = replace_once(
        text,
        """\t} else {
\t\tdentry = __d_lookup(parent, &nd->last);
\t\tif (unlikely(!dentry))
\t\t\treturn 0;
\t\tstatus = d_revalidate(dentry, nd->flags);
\t}""",
        """\t} else {
\t\tdentry = __d_lookup(parent, &nd->last);
\t\tif (unlikely(!dentry))
\t\t\treturn 0;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\t\tif (dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {
\t\t\tdput(dentry);
\t\t\treturn 0;
\t\t}
#endif
\t\tstatus = d_revalidate(dentry, nd->flags);
\t}""",
        label + ":lookup_fast_norm",
    )
    text = replace_once(
        text,
        """\t\tif (unlikely(old)) {
\t\t\tdput(dentry);
\t\t\tdentry = old;
\t\t}
\t}
\treturn dentry;
}""",
        """\t\tif (unlikely(old)) {
\t\t\tdput(dentry);
\t\t\tdentry = old;
\t\t}
\t}
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tif (!IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {
\t\tdput(dentry);
\t\treturn ERR_PTR(-ENOENT);
\t}
#endif
\treturn dentry;
}""",
        label + ":__lookup_slow",
    )
    text = replace_once(
        text,
        """\t\tseq = 0;\t/* we are already out of RCU mode */
\t\tinode = d_backing_inode(path.dentry);
\t}

\treturn step_into(nd, &path, flags, inode, seq);""",
        """\t\tseq = 0;\t/* we are already out of RCU mode */
\t\tinode = d_backing_inode(path.dentry);
\t}
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tif (inode && susfs_is_inode_sus_path(inode)) {
\t\tpath_put(&path);
\t\treturn -ENOENT;
\t}
#endif

\treturn step_into(nd, &path, flags, inode, seq);""",
        label + ":walk_component",
    )
    text = replace_once(
        text,
        """static int link_path_walk(const char *name, struct nameidata *nd)
{
\tint err;""",
        """static int link_path_walk(const char *name, struct nameidata *nd)
{
\tint err;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tstruct dentry *dentry;
#endif""",
        label + ":link_path_walk_decl",
    )
    text = replace_once(
        text,
        """\tfor(;;) {
\t\tu64 hash_len;
\t\tint type;

\t\terr = may_lookup(nd);""",
        """\tfor(;;) {
\t\tu64 hash_len;
\t\tint type;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\t\tdentry = nd->path.dentry;
\t\tif (dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode))
\t\t\treturn -ENOENT;
#endif

\t\terr = may_lookup(nd);""",
        label + ":link_path_walk_loop",
    )
    text = replace_once(
        text,
        """static inline int lookup_last(struct nameidata *nd)
{
\tif (nd->last_type == LAST_NORM && nd->last.name[nd->last.len])
\t\tnd->flags |= LOOKUP_FOLLOW | LOOKUP_DIRECTORY;

\tnd->flags &= ~LOOKUP_PARENT;
\treturn walk_component(nd, 0);
}""",
        """static inline int lookup_last(struct nameidata *nd)
{
\tif (nd->last_type == LAST_NORM && nd->last.name[nd->last.len])
\t\tnd->flags |= LOOKUP_FOLLOW | LOOKUP_DIRECTORY;

\tnd->flags &= ~LOOKUP_PARENT;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tnd->state |= ND_STATE_LOOKUP_LAST;
#endif
\treturn walk_component(nd, 0);
}""",
        label + ":lookup_last",
    )
    text = replace_once(
        text,
        """\tfile->f_mode &= ~FMODE_CREATED;
\tdentry = d_lookup(dir, &nd->last);""",
        """\tfile->f_mode &= ~FMODE_CREATED;
\tdentry = d_lookup(dir, &nd->last);
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tif (dentry && !IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {
\t\tdput(dentry);
\t\tdentry = NULL;
\t}
#endif""",
        label + ":lookup_open",
    )
    text = replace_once(
        text,
        """static int do_last(struct nameidata *nd,
\t\t   struct file *file, const struct open_flags *op)
{
\tstruct dentry *dir = nd->path.dentry;
\tkuid_t dir_uid = nd->inode->i_uid;
\tumode_t dir_mode = nd->inode->i_mode;
\tint open_flag = op->open_flag;
\tbool will_truncate = (open_flag & O_TRUNC) != 0;
\tbool got_write = false;
\tint acc_mode = op->acc_mode;
\tunsigned seq;
\tstruct inode *inode;
\tstruct path path;
\tint error;

\tnd->flags &= ~LOOKUP_PARENT;
\tnd->flags |= op->intent;""",
        """static int do_last(struct nameidata *nd,
\t\t   struct file *file, const struct open_flags *op)
{
\tstruct dentry *dir = nd->path.dentry;
\tkuid_t dir_uid = nd->inode->i_uid;
\tumode_t dir_mode = nd->inode->i_mode;
\tint open_flag = op->open_flag;
\tbool will_truncate = (open_flag & O_TRUNC) != 0;
\tbool got_write = false;
\tint acc_mode = op->acc_mode;
\tunsigned seq;
\tstruct inode *inode;
\tstruct path path;
\tint error;

\tnd->flags &= ~LOOKUP_PARENT;
\tnd->flags |= op->intent;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tnd->state |= ND_STATE_OPEN_LAST;
#endif""",
        label + ":do_last_top",
    )
    text = replace_once(
        text,
        """\terror = complete_walk(nd);
\tif (error)
\t\treturn error;
\taudit_inode(nd->name, nd->path.dentry, 0);""",
        """\terror = complete_walk(nd);
\tif (error)
\t\treturn error;
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\tif (nd->inode && SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK(nd->inode) &&
\t    !(nd->flags & LOOKUP_ROOT)) {
\t\tstruct filename *fake_filename = susfs_open_redirect_spoof_do_sys_openat(nd->inode);
\t\tif (!IS_ERR_OR_NULL(fake_filename)) {
\t\t\tstruct path fake_path;
\t\t\tint fake_err = filename_lookup(nd->dfd, fake_filename,
\t\t\t\t\t\t(nd->flags & ~LOOKUP_RCU) | LOOKUP_FOLLOW,
\t\t\t\t\t\t&fake_path, NULL);
\t\t\tif (!fake_err) {
\t\t\t\tpath_put(&nd->path);
\t\t\t\tnd->path = fake_path;
\t\t\t\tnd->inode = d_backing_inode(fake_path.dentry);
\t\t\t}
\t\t}
\t}
#endif
\taudit_inode(nd->name, nd->path.dentry, 0);""",
        label + ":do_last_complete",
    )
    text = replace_once(
        text,
        """static int do_o_path(struct nameidata *nd, unsigned flags, struct file *file)
{
\tstruct path path;
\tint error = path_lookupat(nd, flags, &path);""",
        """static int do_o_path(struct nameidata *nd, unsigned flags, struct file *file)
{
\tstruct path path;
\tint error = path_lookupat(nd, flags, &path);
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\tif (!error && d_backing_inode(path.dentry) &&
\t    SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK(d_backing_inode(path.dentry)) &&
\t    !(nd->flags & LOOKUP_ROOT)) {
\t\tstruct filename *fake_filename = susfs_open_redirect_spoof_do_sys_openat(d_backing_inode(path.dentry));
\t\tif (!IS_ERR_OR_NULL(fake_filename)) {
\t\t\tstruct path fake_path;
\t\t\tint fake_err = filename_lookup(nd->dfd, fake_filename,
\t\t\t\t\t\t(flags & ~LOOKUP_RCU) | LOOKUP_FOLLOW,
\t\t\t\t\t\t&fake_path, NULL);
\t\t\tif (!fake_err) {
\t\t\t\tpath_put(&path);
\t\t\t\tpath = fake_path;
\t\t\t}
\t\t}
\t}
#endif""",
        label + ":do_o_path",
    )
    text = replace_once(
        text,
        """\tif (unlikely(!(inode->i_opflags & IOP_DEFAULT_READLINK))) {""",
        """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\tif (SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK(inode)) {
\t\tint spoof_res = susfs_open_redirect_spoof_vfs_readlink(inode, buffer, buflen);
\t\tif (spoof_res != -ENOENT)
\t\t\treturn spoof_res;
\t}
#endif
\tif (unlikely(!(inode->i_opflags & IOP_DEFAULT_READLINK))) {""",
        label + ":vfs_readlink",
    )
    return text


def patch_fs_namespace(text, label):
    if "susfs_alloc_unshare_ksu_vfsmnt" in text:
        return text
    text = replace_once(
        text,
        '#include "internal.h"',
        '#include "internal.h"\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif',
        label + ":inc",
    )
    text = replace_once(
        text,
        "static DEFINE_IDA(mnt_id_ida);",
        """static DEFINE_IDA(mnt_id_ida);
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
static DEFINE_IDA(susfs_mnt_id_ida);
static DEFINE_IDA(susfs_mnt_group_ida);
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_current_zygote_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#define CL_COPY_MNT_NS BIT(25)
#endif""",
        label + ":ida",
    )
    text = replace_once(
        text,
        """static int mnt_alloc_id(struct mount *mnt)
{
\tint res = ida_alloc(&mnt_id_ida, GFP_KERNEL);

\tif (res < 0)
\t\treturn res;
\tmnt->mnt_id = res;
\treturn 0;
}

static void mnt_free_id(struct mount *mnt)
{
\tida_free(&mnt_id_ida, mnt->mnt_id);
}""",
        """static int mnt_alloc_id(struct mount *mnt)
{
\tint res = ida_alloc(&mnt_id_ida, GFP_KERNEL);

\tif (res < 0)
\t\treturn res;
\tmnt->mnt_id = res;
\treturn 0;
}

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
static int susfs_mnt_alloc_id(struct mount *mnt)
{
\tint res = ida_alloc_min(&susfs_mnt_id_ida, DEFAULT_KSU_MNT_ID, GFP_KERNEL);

\tif (res < 0)
\t\treturn res;
\tmnt->mnt_id = res;
\treturn 0;
}
#endif

static void mnt_free_id(struct mount *mnt)
{
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (mnt->mnt_id >= DEFAULT_KSU_MNT_ID) {
\t\tida_free(&susfs_mnt_id_ida, mnt->mnt_id);
\t\treturn;
\t}
#endif
\tida_free(&mnt_id_ida, mnt->mnt_id);
}""",
        label + ":mnt_id",
    )
    text = replace_once(
        text,
        """static int mnt_alloc_group_id(struct mount *mnt)
{
\tint res = ida_alloc_min(&mnt_group_ida, 1, GFP_KERNEL);

\tif (res < 0)
\t\treturn res;
\tmnt->mnt_group_id = res;
\treturn 0;
}

/*
 * Release a peer group ID
 */
void mnt_release_group_id(struct mount *mnt)
{
\tida_free(&mnt_group_ida, mnt->mnt_group_id);
\tmnt->mnt_group_id = 0;
}""",
        """static int mnt_alloc_group_id(struct mount *mnt)
{
\tint res;
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (mnt->mnt_id >= DEFAULT_KSU_MNT_ID) {
\t\tres = ida_alloc_min(&susfs_mnt_group_ida, DEFAULT_KSU_MNT_GROUP_ID, GFP_KERNEL);
\t\tif (res < 0)
\t\t\treturn res;
\t\tmnt->mnt_group_id = res;
\t\treturn 0;
\t}
#endif
\tres = ida_alloc_min(&mnt_group_ida, 1, GFP_KERNEL);

\tif (res < 0)
\t\treturn res;
\tmnt->mnt_group_id = res;
\treturn 0;
}

/*
 * Release a peer group ID
 */
void mnt_release_group_id(struct mount *mnt)
{
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (mnt->mnt_group_id >= DEFAULT_KSU_MNT_GROUP_ID) {
\t\tida_free(&susfs_mnt_group_ida, mnt->mnt_group_id);
\t\tmnt->mnt_group_id = 0;
\t\treturn;
\t}
#endif
\tida_free(&mnt_group_ida, mnt->mnt_group_id);
\tmnt->mnt_group_id = 0;
}""",
        label + ":group_id",
    )
    text = replace_once(
        text,
        """static struct mount *alloc_vfsmnt(const char *name)
{""",
        """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
static struct mount *susfs_alloc_non_unshare_ksu_vfsmnt(const char *name)
{
\tstruct mount *mnt = kmem_cache_zalloc(mnt_cache, GFP_KERNEL);
\tif (mnt) {
\t\tint err;

\t\terr = susfs_mnt_alloc_id(mnt);
\t\tif (err)
\t\t\tgoto out_free_cache;

\t\tif (name) {
\t\t\tmnt->mnt_devname = kstrdup_const(name, GFP_KERNEL);
\t\t\tif (!mnt->mnt_devname)
\t\t\t\tgoto out_free_id;
\t\t}

#ifdef CONFIG_SMP
\t\tmnt->mnt_pcp = alloc_percpu(struct mnt_pcp);
\t\tif (!mnt->mnt_pcp)
\t\t\tgoto out_free_devname;
\t\tthis_cpu_inc(mnt->mnt_pcp->mnt_count);
#else
\t\tmnt->mnt_count = 1;
\t\tmnt->mnt_writers = 0;
#endif
\t\tmnt->mnt.data = NULL;

\t\tINIT_HLIST_NODE(&mnt->mnt_hash);
\t\tINIT_LIST_HEAD(&mnt->mnt_child);
\t\tINIT_LIST_HEAD(&mnt->mnt_mounts);
\t\tINIT_LIST_HEAD(&mnt->mnt_list);
\t\tINIT_LIST_HEAD(&mnt->mnt_expire);
\t\tINIT_LIST_HEAD(&mnt->mnt_share);
\t\tINIT_LIST_HEAD(&mnt->mnt_slave_list);
\t\tINIT_LIST_HEAD(&mnt->mnt_slave);
\t\tINIT_HLIST_NODE(&mnt->mnt_mp_list);
\t\tINIT_LIST_HEAD(&mnt->mnt_umounting);
\t\tinit_fs_pin(&mnt->mnt_umount, drop_mountpoint);
\t}
\treturn mnt;

#ifdef CONFIG_SMP
out_free_devname:
\tkfree_const(mnt->mnt_devname);
#endif
out_free_id:
\tmnt_free_id(mnt);
out_free_cache:
\tkmem_cache_free(mnt_cache, mnt);
\treturn NULL;
}

static struct mount *susfs_alloc_unshare_ksu_vfsmnt(const char *name)
{
\tstruct mount *mnt = susfs_alloc_non_unshare_ksu_vfsmnt(name);
\tif (mnt)
\t\tmnt->mnt.mnt_flags |= VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT;
\treturn mnt;
}
#endif

static struct mount *alloc_vfsmnt(const char *name)
{""",
        label + ":alloc_vfsmnt",
    )
    text = replace_once(
        text,
        """static struct mount *clone_mnt(struct mount *old, struct dentry *root,
\t\t\t\t\tint flag)
{
\tstruct super_block *sb = old->mnt.mnt_sb;
\tstruct mount *mnt;
\tint err;

\tmnt = alloc_vfsmnt(old->mnt_devname);""",
        """static struct mount *clone_mnt(struct mount *old, struct dentry *root,
\t\t\t\t\tint flag)
{
\tstruct super_block *sb = old->mnt.mnt_sb;
\tstruct mount *mnt;
\tint err;

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted) &&
\t    !(flag & CL_COPY_MNT_NS) &&
\t    (susfs_is_current_ksu_domain() || old->mnt_id >= DEFAULT_KSU_MNT_ID)) {
\t\tif (susfs_is_current_ksu_domain())
\t\t\tmnt = susfs_alloc_unshare_ksu_vfsmnt(old->mnt_devname);
\t\telse
\t\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(old->mnt_devname);
\t\tgoto bypass_orig_alloc_vfsmnt;
\t}
#endif
\tmnt = alloc_vfsmnt(old->mnt_devname);
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_alloc_vfsmnt:
#endif""",
        label + ":clone_mnt",
    )
    text = replace_once(
        text,
        "\tnew = copy_tree(old, old->mnt.mnt_root, copy_flags);",
        "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\tcopy_flags |= CL_COPY_MNT_NS;\n#endif\n\tnew = copy_tree(old, old->mnt.mnt_root, copy_flags);",
        label + ":copy_mnt_ns",
    )
    # Also mark zygote spawned copy_mnt_ns unshared sus mounts unshared if needed & expose helpers
    helpers = """
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
int susfs_get_non_sus_mnt_id_from_mnt(struct mount *orig_mnt)
{
\tstruct mount *mnt = orig_mnt;

\tlock_mount_hash();
\twhile (mnt && mnt->mnt_id >= DEFAULT_KSU_MNT_ID && mnt->mnt_parent != mnt)
\t\tmnt = mnt->mnt_parent;
\tunlock_mount_hash();
\treturn mnt ? mnt->mnt_id : orig_mnt->mnt_id;
}

struct vfsmount *susfs_get_non_sus_vfsmnt_from_vfsmnt(struct vfsmount *vfsmnt)
{
\tstruct mount *mnt = real_mount(vfsmnt);

\tlock_mount_hash();
\twhile (mnt && mnt->mnt_id >= DEFAULT_KSU_MNT_ID && mnt->mnt_parent != mnt)
\t\tmnt = mnt->mnt_parent;
\tif (mnt)
\t\tmntget(&mnt->mnt);
\tunlock_mount_hash();
\tif (mnt) {
\t\tdget(mnt->mnt.mnt_root);
\t\treturn &mnt->mnt;
\t}
\tmntget(vfsmnt);
\tdget(vfsmnt->mnt_root);
\treturn vfsmnt;
}
#endif
"""
    if not text.endswith("\n"):
        text += "\n"
    return text + helpers


def patch_fs_proc_namespace(text, label):
    if "susfs_show_vfsmnt" in text:
        return text
    text = replace_once(
        text,
        '#include "internal.h"',
        """#include "internal.h"
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_false susfs_is_hide_sus_mnts_for_non_su_procs_enabled;
#endif""",
        label + ":inc",
    )
    text = replace_once(
        text,
        """static int mounts_open(struct inode *inode, struct file *file)
{
\treturn mounts_open_common(inode, file, show_vfsmnt);
}

static int mountinfo_open(struct inode *inode, struct file *file)
{
\treturn mounts_open_common(inode, file, show_mountinfo);
}

static int mountstats_open(struct inode *inode, struct file *file)
{
\treturn mounts_open_common(inode, file, show_vfsstat);
}""",
        """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
static int susfs_show_vfsmnt(struct seq_file *m, struct vfsmount *mnt)
{
\tif (real_mount(mnt)->mnt_id >= DEFAULT_KSU_MNT_ID)
\t\treturn 0;
\treturn show_vfsmnt(m, mnt);
}

static int susfs_show_mountinfo(struct seq_file *m, struct vfsmount *mnt)
{
\tif (real_mount(mnt)->mnt_id >= DEFAULT_KSU_MNT_ID)
\t\treturn 0;
\treturn show_mountinfo(m, mnt);
}

static int susfs_show_vfsstat(struct seq_file *m, struct vfsmount *mnt)
{
\tif (real_mount(mnt)->mnt_id >= DEFAULT_KSU_MNT_ID)
\t\treturn 0;
\treturn show_vfsstat(m, mnt);
}
#endif

static int mounts_open(struct inode *inode, struct file *file)
{
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (static_branch_likely(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled)) {
\t\tif (likely(!susfs_is_current_ksu_domain()))
\t\t\treturn mounts_open_common(inode, file, susfs_show_vfsmnt);
\t}
#endif
\treturn mounts_open_common(inode, file, show_vfsmnt);
}

static int mountinfo_open(struct inode *inode, struct file *file)
{
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (static_branch_likely(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled)) {
\t\tif (likely(!susfs_is_current_ksu_domain()))
\t\t\treturn mounts_open_common(inode, file, susfs_show_mountinfo);
\t}
#endif
\treturn mounts_open_common(inode, file, show_mountinfo);
}

static int mountstats_open(struct inode *inode, struct file *file)
{
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (static_branch_likely(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled)) {
\t\tif (likely(!susfs_is_current_ksu_domain()))
\t\t\treturn mounts_open_common(inode, file, susfs_show_vfsstat);
\t}
#endif
\treturn mounts_open_common(inode, file, show_vfsstat);
}""",
        label + ":open",
    )
    return text


def patch_fs_readdir(text, label):
    if "susfs_is_inode_sus_path" in text:
        return text
    text = replace_once(
        text,
        "#include <linux/uaccess.h>",
        """#include <linux/uaccess.h>
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
#include <linux/susfs_def.h>
extern bool susfs_is_inode_sus_path(struct inode *inode);
#endif""",
        label + ":inc",
    )

    if text.count("\tstruct dir_context ctx;\n") != 5:
        raise RuntimeError(f"[{label}] Unexpected callback struct count")
    text = text.replace(
        "\tstruct dir_context ctx;\n",
        "\tstruct dir_context ctx;\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tstruct super_block *sb;\n#endif\n",
    )

    if text.count("\terror = iterate_dir(f.file, &buf.ctx);\n") != 5:
        raise RuntimeError(f"[{label}] Unexpected iterate_dir count")
    text = text.replace(
        "\terror = iterate_dir(f.file, &buf.ctx);\n",
        "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tbuf.sb = f.file->f_inode->i_sb;\n#endif\n\terror = iterate_dir(f.file, &buf.ctx);\n",
    )

    hide_block = """#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tinode = ilookup(buf->sb, ino);
\tif (inode) {
\t\tif (susfs_is_inode_sus_path(inode)) {
\t\t\tiput(inode);
\t\t\treturn 0;
\t\t}
\t\tiput(inode);
\t}
#endif"""

    # 1 & 4. fillonedir and compat_fillonedir
    if text.count("\tbuf->result++;\n\tdirent = buf->dirent;") != 2:
        raise RuntimeError(f"[{label}] Unexpected fillonedir check anchor count")
    text = text.replace(
        "\tbuf->result++;\n\tdirent = buf->dirent;",
        hide_block + "\n\tbuf->result++;\n\tdirent = buf->dirent;",
    )
    text = replace_once(
        text,
        "\tstruct old_linux_dirent __user * dirent;\n\tunsigned long d_ino;",
        "\tstruct old_linux_dirent __user * dirent;\n\tunsigned long d_ino;\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tstruct inode *inode;\n#endif",
        label + ":fillonedir_decl",
    )

    # 2. filldir
    text = replace_once(
        text,
        "\tstruct getdents_callback *buf =\n\t\tcontainer_of(ctx, struct getdents_callback, ctx);\n\tunsigned long d_ino;\n\tint reclen = ALIGN(offsetof(struct linux_dirent, d_name) + namlen + 2,\n\t\tsizeof(long));",
        "\tstruct getdents_callback *buf =\n\t\tcontainer_of(ctx, struct getdents_callback, ctx);\n\tunsigned long d_ino;\n\tint reclen = ALIGN(offsetof(struct linux_dirent, d_name) + namlen + 2,\n\t\tsizeof(long));\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tstruct inode *inode;\n#endif",
        label + ":filldir_decl",
    )
    text = replace_once(
        text,
        "\tdirent = buf->previous;\n\tif (dirent) {\n\t\tif (signal_pending(current))\n\t\t\treturn -EINTR;\n\t\tif (__put_user(offset, &dirent->d_off))\n\t\t\tgoto efault;\n\t}\n\tdirent = buf->current_dir;\n\tif (__put_user(d_ino, &dirent->d_ino))\n\t\tgoto efault;\n\tif (__put_user(reclen, &dirent->d_reclen))\n\t\tgoto efault;\n\tif (copy_to_user(dirent->d_name, name, namlen))\n\t\tgoto efault;\n\tif (__put_user(0, dirent->d_name + namlen))\n\t\tgoto efault;\n\tif (__put_user(d_type, (char __user *) dirent + reclen - 1))",
        hide_block + "\n\tdirent = buf->previous;\n\tif (dirent) {\n\t\tif (signal_pending(current))\n\t\t\treturn -EINTR;\n\t\tif (__put_user(offset, &dirent->d_off))\n\t\t\tgoto efault;\n\t}\n\tdirent = buf->current_dir;\n\tif (__put_user(d_ino, &dirent->d_ino))\n\t\tgoto efault;\n\tif (__put_user(reclen, &dirent->d_reclen))\n\t\tgoto efault;\n\tif (copy_to_user(dirent->d_name, name, namlen))\n\t\tgoto efault;\n\tif (__put_user(0, dirent->d_name + namlen))\n\t\tgoto efault;\n\tif (__put_user(d_type, (char __user *) dirent + reclen - 1))",
        label + ":filldir_chk",
    )

    # 3. filldir64
    text = replace_once(
        text,
        "\tstruct getdents_callback64 *buf =\n\t\tcontainer_of(ctx, struct getdents_callback64, ctx);\n\tint reclen = ALIGN(offsetof(struct linux_dirent64, d_name) + namlen + 1,\n\t\tsizeof(u64));",
        "\tstruct getdents_callback64 *buf =\n\t\tcontainer_of(ctx, struct getdents_callback64, ctx);\n\tint reclen = ALIGN(offsetof(struct linux_dirent64, d_name) + namlen + 1,\n\t\tsizeof(u64));\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tstruct inode *inode;\n#endif",
        label + ":filldir64_decl",
    )
    text = replace_once(
        text,
        "\tdirent = buf->previous;\n\tif (dirent) {\n\t\tif (signal_pending(current))\n\t\t\treturn -EINTR;\n\t\tif (__put_user(offset, &dirent->d_off))\n\t\t\tgoto efault;\n\t}\n\tdirent = buf->current_dir;\n\tif (__put_user(ino, &dirent->d_ino))",
        hide_block + "\n\tdirent = buf->previous;\n\tif (dirent) {\n\t\tif (signal_pending(current))\n\t\t\treturn -EINTR;\n\t\tif (__put_user(offset, &dirent->d_off))\n\t\t\tgoto efault;\n\t}\n\tdirent = buf->current_dir;\n\tif (__put_user(ino, &dirent->d_ino))",
        label + ":filldir64_chk",
    )

    # 4b. compat_fillonedir decl
    text = replace_once(
        text,
        "\tstruct compat_old_linux_dirent __user *dirent;\n\tcompat_ulong_t d_ino;",
        "\tstruct compat_old_linux_dirent __user *dirent;\n\tcompat_ulong_t d_ino;\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tstruct inode *inode;\n#endif",
        label + ":compat_fillonedir_decl",
    )

    # 5. compat_filldir
    text = replace_once(
        text,
        "\tcompat_ulong_t d_ino;\n\tint reclen = ALIGN(offsetof(struct compat_linux_dirent, d_name) +\n\t\tnamlen + 2, sizeof(compat_long_t));",
        "\tcompat_ulong_t d_ino;\n\tint reclen = ALIGN(offsetof(struct compat_linux_dirent, d_name) +\n\t\tnamlen + 2, sizeof(compat_long_t));\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tstruct inode *inode;\n#endif",
        label + ":compat_filldir_decl",
    )
    text = replace_once(
        text,
        "\tdirent = buf->previous;\n\tif (dirent) {\n\t\tif (signal_pending(current))\n\t\t\treturn -EINTR;\n\t\tif (__put_user(offset, &dirent->d_off))\n\t\t\tgoto efault;\n\t}\n\tdirent = buf->current_dir;\n\tif (__put_user(d_ino, &dirent->d_ino))\n\t\tgoto efault;\n\tif (__put_user(reclen, &dirent->d_reclen))\n\t\tgoto efault;\n\tif (copy_to_user(dirent->d_name, name, namlen))\n\t\tgoto efault;\n\tif (__put_user(0, dirent->d_name + namlen))\n\t\tgoto efault;\n\tif (__put_user(d_type, (char  __user *) dirent + reclen - 1))",
        hide_block + "\n\tdirent = buf->previous;\n\tif (dirent) {\n\t\tif (signal_pending(current))\n\t\t\treturn -EINTR;\n\t\tif (__put_user(offset, &dirent->d_off))\n\t\t\tgoto efault;\n\t}\n\tdirent = buf->current_dir;\n\tif (__put_user(d_ino, &dirent->d_ino))\n\t\tgoto efault;\n\tif (__put_user(reclen, &dirent->d_reclen))\n\t\tgoto efault;\n\tif (copy_to_user(dirent->d_name, name, namlen))\n\t\tgoto efault;\n\tif (__put_user(0, dirent->d_name + namlen))\n\t\tgoto efault;\n\tif (__put_user(d_type, (char  __user *) dirent + reclen - 1))",
        label + ":compat_filldir_chk",
    )
    return text


def patch_fs_notify_fdinfo(text, label):
    if "susfs_is_inode_sus_kstat" in text:
        return text
    text = replace_once(
        text,
        '#include "fsnotify.h"',
        """#include "fsnotify.h"
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/slab.h>
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
extern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);
extern void susfs_sus_kstat_spoof_inotify_fdinfo(unsigned long *out_target_ino, dev_t *out_target_dev);
#endif""",
        label + ":inc",
    )
    text = replace_once(
        text,
        """static void show_fdinfo(struct seq_file *m, struct file *f,
\t\t\tvoid (*show)(struct seq_file *m,
\t\t\t\t     struct fsnotify_mark *mark))""",
        """static void show_fdinfo(struct seq_file *m, struct file *f,
\t\t\tvoid (*show)(struct seq_file *m,
\t\t\t\t     struct fsnotify_mark *mark, struct file *file))""",
        label + ":sig_show",
    )
    text = replace_once(
        text,
        "\t\tshow(m, mark);",
        "\t\tshow(m, mark, f);",
        label + ":call_show",
    )
    text = replace_once(
        text,
        """static void inotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark)
{
\tstruct inotify_inode_mark *inode_mark;
\tstruct inode *inode;

\tif (mark->connector->type != FSNOTIFY_OBJ_TYPE_INODE)
\t\treturn;

\tinode_mark = container_of(mark, struct inotify_inode_mark, fsn_mark);
\tinode = igrab(fsnotify_conn_inode(mark->connector));
\tif (inode) {
\t\tseq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",
\t\t\t   inode_mark->wd, inode->i_ino, inode->i_sb->s_dev,
\t\t\t   inotify_mark_user_mask(mark));""",
        """static void inotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark, struct file *file)
{
\tstruct inotify_inode_mark *inode_mark;
\tstruct inode *inode;

\tif (mark->connector->type != FSNOTIFY_OBJ_TYPE_INODE)
\t\treturn;

\tinode_mark = container_of(mark, struct inotify_inode_mark, fsn_mark);
\tinode = igrab(fsnotify_conn_inode(mark->connector));
\tif (inode) {
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\t\tif (susfs_is_current_app_uid()) {
\t\t\tbool is_fuse = false;
\t\t\tif (susfs_is_inode_sus_kstat(inode, &is_fuse)) {
\t\t\t\tunsigned long ino = inode->i_ino;
\t\t\t\tdev_t sdev = inode->i_sb->s_dev;
\t\t\t\tsusfs_sus_kstat_spoof_inotify_fdinfo(&ino, &sdev);
\t\t\t\tseq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",
\t\t\t\t\t   inode_mark->wd, ino, sdev,
\t\t\t\t\t   inotify_mark_user_mask(mark));
\t\t\t\tshow_mark_fhandle(m, inode);
\t\t\t\tseq_putc(m, '\\n');
\t\t\t\tiput(inode);
\t\t\t\treturn;
\t\t\t}
\t\t}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\t\tif (likely(susfs_is_current_proc_umounted())) {
\t\t\tstruct mount *mnt = real_mount(file->f_path.mnt);
\t\t\tif (mnt->mnt_id >= DEFAULT_KSU_MNT_ID) {
\t\t\t\tstruct path path;
\t\t\t\tchar *pathname = kmalloc(PAGE_SIZE, GFP_KERNEL);
\t\t\t\tchar *dpath;
\t\t\t\tif (!pathname)
\t\t\t\t\tgoto orig_flow;
\t\t\t\tdpath = d_path(&file->f_path, pathname, PAGE_SIZE);
\t\t\t\tif (IS_ERR_OR_NULL(dpath)) {
\t\t\t\t\tkfree(pathname);
\t\t\t\t\tgoto orig_flow;
\t\t\t\t}
\t\t\t\tif (kern_path(dpath, 0, &path)) {
\t\t\t\t\tkfree(pathname);
\t\t\t\t\tgoto orig_flow;
\t\t\t\t}
\t\t\t\tif (!d_backing_inode(path.dentry)) {
\t\t\t\t\tpath_put(&path);
\t\t\t\t\tkfree(pathname);
\t\t\t\t\tgoto orig_flow;
\t\t\t\t}
\t\t\t\tseq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",
\t\t\t\t\t   inode_mark->wd,
\t\t\t\t\t   d_backing_inode(path.dentry)->i_ino,
\t\t\t\t\t   d_backing_inode(path.dentry)->i_sb->s_dev,
\t\t\t\t\t   inotify_mark_user_mask(mark));
\t\t\t\tshow_mark_fhandle(m, inode);
\t\t\t\tseq_putc(m, '\\n');
\t\t\t\tpath_put(&path);
\t\t\t\tkfree(pathname);
\t\t\t\tiput(inode);
\t\t\t\treturn;
\t\t\t}
\t\t}
orig_flow:
#endif
\t\tseq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",
\t\t\t   inode_mark->wd, inode->i_ino, inode->i_sb->s_dev,
\t\t\t   inotify_mark_user_mask(mark));""",
        label + ":inotify",
    )
    text = replace_once(
        text,
        "static void fanotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark)",
        "static void fanotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark, struct file *file __maybe_unused)",
        label + ":fanotify",
    )
    return text


def patch_fs_proc_cmdline(text, label):
    if "susfs_spoof_cmdline_or_bootconfig" in text:
        return text
    text = replace_once(
        text,
        "#include <linux/seq_file.h>",
        """#include <linux/seq_file.h>
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
extern struct static_key_false susfs_is_fake_cmdline_or_bootconfig_buffer_set;
extern void susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);
#endif""",
        label + ":inc",
    )
    return replace_once(
        text,
        """static int cmdline_proc_show(struct seq_file *m, void *v)
{
\tseq_puts(m, saved_command_line);""",
        """static int cmdline_proc_show(struct seq_file *m, void *v)
{
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
\tif (static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)) {
\t\tsusfs_spoof_cmdline_or_bootconfig(m);
\t\tseq_putc(m, '\\n');
\t\treturn 0;
\t}
#endif
\tseq_puts(m, saved_command_line);""",
        label + ":show",
    )


def patch_fs_proc_fd(text, label):
    if "susfs_sus_kstat_spoof_proc_fd_seq_show" in text:
        return text
    text = replace_once(
        text,
        "#include <linux/proc_fs.h>",
        """#include <linux/proc_fs.h>
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif""",
        label + ":inc",
    )
    text = replace_once(
        text,
        '#include "fd.h"',
        """#include "fd.h"
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern int susfs_get_non_sus_mnt_id_from_mnt(struct mount *orig_mnt);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
extern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);
extern void susfs_sus_kstat_spoof_proc_fd_seq_show(int *out_target_mnt_id, unsigned long *out_target_ino, dev_t target_dev);
#endif""",
        label + ":ext",
    )
    return replace_once(
        text,
        """\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",
\t\t   (long long)file->f_pos, f_flags,
\t\t   real_mount(file->f_path.mnt)->mnt_id);""",
        """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\tif (susfs_is_current_app_uid()) {
\t\tstruct inode *inode = file_inode(file);
\t\tbool is_fuse = false;
\t\tif (susfs_is_inode_sus_kstat(inode, &is_fuse)) {
\t\t\tint mnt_id = real_mount(file->f_path.mnt)->mnt_id;
\t\t\tunsigned long ino = inode->i_ino;
\t\t\tsusfs_sus_kstat_spoof_proc_fd_seq_show(&mnt_id, &ino, inode->i_sb->s_dev);
\t\t\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",
\t\t\t\t   (long long)file->f_pos, f_flags, mnt_id);
\t\t\tgoto bypass_orig_flow;
\t\t}
\t}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (likely(susfs_is_current_proc_umounted())) {
\t\tstruct mount *mnt = real_mount(file->f_path.mnt);
\t\tif (mnt->mnt_id >= DEFAULT_KSU_MNT_ID) {
\t\t\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",
\t\t\t\t   (long long)file->f_pos, f_flags,
\t\t\t\t   susfs_get_non_sus_mnt_id_from_mnt(mnt));
\t\t\tgoto bypass_orig_flow;
\t\t}
\t}
#endif
\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",
\t\t   (long long)file->f_pos, f_flags,
\t\t   real_mount(file->f_path.mnt)->mnt_id);
#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_SUS_KSTAT)
bypass_orig_flow:
#endif""",
        label + ":seq_show",
    )


def patch_fs_proc_base(text, label):
    if "susfs_open_redirect_spoof_do_proc_readlink" in text:
        return text
    text = replace_once(
        text,
        '#include "internal.h"',
        """#include "internal.h"
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
extern int susfs_open_redirect_spoof_do_proc_readlink(struct inode *inode, char *tmp_buf, int buflen);
#endif""",
        label + ":inc",
    )
    text = replace_once(
        text,
        """\tpathname = d_path(path, tmp, PAGE_SIZE);
\tlen = PTR_ERR(pathname);
\tif (IS_ERR(pathname))
\t\tgoto out;
\tlen = tmp + PAGE_SIZE - 1 - pathname;

\tif (len > buflen)
\t\tlen = buflen;
\tif (copy_to_user(buffer, pathname, len))
\t\tlen = -EFAULT;
 out:
\tfree_page((unsigned long)tmp);""",
        """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\tif (path->dentry && d_backing_inode(path->dentry) &&
\t    SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK(d_backing_inode(path->dentry)) &&
\t    !susfs_open_redirect_spoof_do_proc_readlink(d_backing_inode(path->dentry), tmp, PAGE_SIZE)) {
\t\tlen = strlen(tmp);
\t\tif (len > buflen)
\t\t\tlen = buflen;
\t\tif (copy_to_user(buffer, tmp, len))
\t\t\tlen = -EFAULT;
\t\tgoto out;
\t}
#endif
\tpathname = d_path(path, tmp, PAGE_SIZE);
\tlen = PTR_ERR(pathname);
\tif (IS_ERR(pathname))
\t\tgoto out;
\tlen = tmp + PAGE_SIZE - 1 - pathname;

\tif (len > buflen)
\t\tlen = buflen;
\tif (copy_to_user(buffer, pathname, len))
\t\tlen = -EFAULT;
 out:
\tfree_page((unsigned long)tmp);""",
        label + ":do_proc_readlink",
    )
    text = replace_once(
        text,
        """\t\tfor (i = 0, vma = mm->mmap, pos = 2; vma;
\t\t\t\tvma = vma->vm_next) {
\t\t\tif (!vma->vm_file)
\t\t\t\tcontinue;
\t\t\tif (++pos <= ctx->pos)
\t\t\t\tcontinue;""",
        """\t\tfor (i = 0, vma = mm->mmap, pos = 2; vma;
\t\t\t\tvma = vma->vm_next) {
\t\t\tif (!vma->vm_file)
\t\t\t\tcontinue;
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
\t\t\t\tcontinue;
#endif
\t\t\tif (++pos <= ctx->pos)
\t\t\t\tcontinue;""",
        label + ":map_files_readdir",
    )
    return text


def patch_fs_proc_task_mmu(text, label):
    if "susfs_sus_kstat_spoof_show_map_vma" in text:
        return text
    text = replace_once(
        text,
        '#include "internal.h"',
        """#include "internal.h"
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
extern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);
extern void susfs_sus_kstat_spoof_show_map_vma(struct inode *inode, dev_t *out_dev, unsigned long *out_ino);
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
extern struct srcu_struct susfs_srcu_open_redirect;
extern int susfs_open_redirect_spoof_show_map_vma_srcu(struct inode *inode, unsigned long *out_ino, dev_t *out_dev, char **out_spoofed_name);
#endif""",
        label + ":inc",
    )
    text = replace_once(
        text,
        """\tif (file) {
\t\tstruct inode *inode = file_inode(vma->vm_file);
\t\tdev = inode->i_sb->s_dev;
\t\tino = inode->i_ino;
\t\tpgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;
\t}""",
        """\tif (file) {
\t\tstruct inode *inode = file_inode(vma->vm_file);
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tif (SUSFS_IS_INODE_SUS_MAP(inode))
\t\t\treturn;
#endif
\t\tdev = inode->i_sb->s_dev;
\t\tino = inode->i_ino;
\t\tpgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\t\tif (susfs_is_current_app_uid()) {
\t\t\tbool is_fuse = false;
\t\t\tif (susfs_is_inode_sus_kstat(inode, &is_fuse))
\t\t\t\tsusfs_sus_kstat_spoof_show_map_vma(inode, &dev, &ino);
\t\t}
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\t\tif (SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK(inode)) {
\t\t\tchar *spoofed_redirected_name = NULL;
\t\t\tint srcu_idx = srcu_read_lock(&susfs_srcu_open_redirect);
\t\t\tif (!susfs_open_redirect_spoof_show_map_vma_srcu(inode, &ino, &dev, &spoofed_redirected_name) &&
\t\t\t    spoofed_redirected_name) {
\t\t\t\tstart = vma->vm_start;
\t\t\t\tend = vma->vm_end;
\t\t\t\tif (!show_vma_header_prefix(m, start, end, flags, pgoff, dev, ino)) {
\t\t\t\t\tseq_putc(m, ' ');
\t\t\t\t\tseq_puts(m, spoofed_redirected_name);
\t\t\t\t\tseq_putc(m, '\\n');
\t\t\t\t}
\t\t\t\tsrcu_read_unlock(&susfs_srcu_open_redirect, srcu_idx);
\t\t\t\treturn;
\t\t\t}
\t\t\tsrcu_read_unlock(&susfs_srcu_open_redirect, srcu_idx);
\t\t}
#endif
\t}""",
        label + ":show_map_vma",
    )
    text = replace_once(
        text,
        """static int show_smap(struct seq_file *m, void *v)
{
\tstruct vm_area_struct *vma = v;""",
        """static int show_smap(struct seq_file *m, void *v)
{
\tstruct vm_area_struct *vma = v;
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
\t\treturn 0;
#endif""",
        label + ":show_smap",
    )
    text = replace_once(
        text,
        """\tfor (vma = priv->mm->mmap; vma; vma = vma->vm_next) {
\t\tsmap_gather_stats(vma, &mss);
\t\tlast_vma_end = vma->vm_end;
\t}""",
        """\tfor (vma = priv->mm->mmap; vma; vma = vma->vm_next) {
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
\t\t\tcontinue;
#endif
\t\tsmap_gather_stats(vma, &mss);
\t\tlast_vma_end = vma->vm_end;
\t}""",
        label + ":rollup_loop",
    )
    text = replace_once(
        text,
        "\t\tret = walk_page_range(mm, start_vaddr, end, &pagemap_ops, &pm);",
        """#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\t{
\t\t\tstruct vm_area_struct *sus_vma = find_vma(mm, start_vaddr);
\t\t\tif (sus_vma && sus_vma->vm_start <= start_vaddr && sus_vma->vm_file &&
\t\t\t    SUSFS_IS_INODE_SUS_MAP(file_inode(sus_vma->vm_file))) {
\t\t\t\tmmap_read_unlock(mm);
\t\t\t\tbreak;
\t\t\t}
\t\t}
#endif
\t\tret = walk_page_range(mm, start_vaddr, end, &pagemap_ops, &pm);""",
        label + ":pagemap_read",
    )
    return text


def patch_fs_statfs(text, label):
    if "susfs_statfs_by_dentry" in text:
        return text
    text = replace_once(
        text,
        '#include "internal.h"',
        """#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif
#include "internal.h"
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
extern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);
extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern struct vfsmount *susfs_get_non_sus_vfsmnt_from_vfsmnt(struct vfsmount *vfsmnt);
#endif""",
        label + ":inc",
    )
    return replace_once(
        text,
        """int vfs_statfs(const struct path *path, struct kstatfs *buf)
{
\tint error;

\terror = statfs_by_dentry(path->dentry, buf);
\tif (!error)
\t\tbuf->f_flags = calculate_f_flags(path->mnt);
\treturn error;
}""",
        """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
static int susfs_statfs_by_dentry(struct dentry *dentry, struct vfsmount *mnt, struct kstatfs *buf, bool *is_fuse)
{
\tint retval;

\tif (!dentry->d_sb->s_op->statfs)
\t\treturn -ENOSYS;

\tmemset(buf, 0, sizeof(*buf));
\tretval = security_sb_statfs(dentry);
\tif (retval)
\t\treturn retval;
\tif (!susfs_sus_kstat_spoof_vfs_statfs(d_backing_inode(dentry), buf, is_fuse)) {
\t\tif (buf->f_frsize == 0)
\t\t\tbuf->f_frsize = buf->f_bsize;
\t\treturn retval;
\t}
\tretval = dentry->d_sb->s_op->statfs(dentry, buf);
\tif (retval == 0) {
\t\tbuf->f_flags = calculate_f_flags(mnt);
\t\tif (buf->f_frsize == 0)
\t\t\tbuf->f_frsize = buf->f_bsize;
\t}
\treturn retval;
}
#endif

int vfs_statfs(const struct path *path, struct kstatfs *buf)
{
\tint error;

#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\tif (susfs_is_current_app_uid()) {
\t\tstruct inode *inode = d_backing_inode(path->dentry);
\t\tbool is_fuse = false;
\t\tif (susfs_is_inode_sus_kstat(inode, &is_fuse))
\t\t\treturn susfs_statfs_by_dentry(path->dentry, path->mnt, buf, &is_fuse);
\t}
#endif

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (likely(susfs_is_current_proc_umounted())) {
\t\tstruct vfsmount *no_sus_vfsmnt = susfs_get_non_sus_vfsmnt_from_vfsmnt(path->mnt);
\t\tif (path->mnt == no_sus_vfsmnt) {
\t\t\tdput(no_sus_vfsmnt->mnt_root);
\t\t\tmntput(no_sus_vfsmnt);
\t\t\terror = statfs_by_dentry(path->dentry, buf);
\t\t\tif (!error)
\t\t\t\tbuf->f_flags = calculate_f_flags(path->mnt);
\t\t\treturn error;
\t\t}
\t\terror = statfs_by_dentry(no_sus_vfsmnt->mnt_root, buf);
\t\tif (!error)
\t\t\tbuf->f_flags = calculate_f_flags(no_sus_vfsmnt);
\t\tdput(no_sus_vfsmnt->mnt_root);
\t\tmntput(no_sus_vfsmnt);
\t\treturn error;
\t}
#endif

\terror = statfs_by_dentry(path->dentry, buf);
\tif (!error)
\t\tbuf->f_flags = calculate_f_flags(path->mnt);
\treturn error;
}""",
        label + ":vfs_statfs",
    )


def patch_fs_super(text, label):
    if "susfs_is_sdcard_android_data_not_decrypted" in text:
        return text
    text = replace_once(
        text,
        "#include <linux/fs_context.h>",
        "#include <linux/fs_context.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif",
        label + ":inc",
    )
    return replace_once(
        text,
        """static DEFINE_IDA(unnamed_dev_ida);

/**
 * get_anon_bdev""",
        """static DEFINE_IDA(unnamed_dev_ida);

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif

/**
 * get_anon_bdev""",
        label + ":ext",
    ).replace(
        """int get_anon_bdev(dev_t *p)
{
\tint dev;""",
        """int get_anon_bdev(dev_t *p)
{
\tint dev;

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
\t\tif (susfs_is_current_ksu_domain()) {
\t\t\tdev = ida_alloc_range(&unnamed_dev_ida, DEFAULT_KSU_MNT_MINOR_DEV,
\t\t\t\t\t      (1 << MINORBITS) - 1, GFP_ATOMIC);
\t\t\tif (dev == -ENOSPC)
\t\t\t\tdev = -EMFILE;
\t\t\tif (dev < 0)
\t\t\t\treturn dev;
\t\t\t*p = MKDEV(0, dev);
\t\t\treturn 0;
\t\t}
\t}
#endif""",
        1,
    )


def patch_kernel_kallsyms(text, label):
    if "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS" in text:
        return text
    text = replace_once(
        text,
        "#include <linux/compiler.h>",
        "#include <linux/compiler.h>\n#ifdef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS\n#include <linux/susfs_def.h>\n#endif",
        label + ":inc",
    )
    return replace_once(
        text,
        """\t} else
\t\tseq_printf(m, "%px %c %s\\n", value,
\t\t\t   iter->type, iter->name);""",
        """\t} else
#ifndef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
\t\tseq_printf(m, "%px %c %s\\n", value,
\t\t\t   iter->type, iter->name);
#else
\t{
\t\tif (susfs_starts_with(iter->name, "ksu_") ||
\t\t    susfs_starts_with(iter->name, "__ksu_") ||
\t\t    susfs_starts_with(iter->name, "susfs_") ||
\t\t    susfs_starts_with(iter->name, "ksud") ||
\t\t    susfs_starts_with(iter->name, "is_ksu_") ||
\t\t    susfs_starts_with(iter->name, "is_manager_") ||
\t\t    susfs_starts_with(iter->name, "escape_to_") ||
\t\t    susfs_starts_with(iter->name, "setup_selinux") ||
\t\t    susfs_starts_with(iter->name, "track_throne") ||
\t\t    susfs_starts_with(iter->name, "on_post_fs_data") ||
\t\t    susfs_starts_with(iter->name, "try_umount") ||
\t\t    susfs_starts_with(iter->name, "kernelsu") ||
\t\t    susfs_starts_with(iter->name, "__initcall__kmod_kernelsu") ||
\t\t    susfs_starts_with(iter->name, "apply_kernelsu") ||
\t\t    susfs_starts_with(iter->name, "handle_sepolicy") ||
\t\t    susfs_starts_with(iter->name, "getenforce") ||
\t\t    susfs_starts_with(iter->name, "setenforce") ||
\t\t    susfs_starts_with(iter->name, "is_zygote"))
\t\t\treturn 0;
\t\tseq_printf(m, "%px %c %s\\n", value,
\t\t\t   iter->type, iter->name);
\t}
#endif""",
        label + ":s_show",
    )


def patch_kernel_reboot(text, label):
    if "CONFIG_KSU_SUSFS" in text:
        return text
    target = """#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif

SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
\t\tvoid __user *, arg)
{
\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);
\tchar buffer[256];
\tint ret = 0;

#ifdef CONFIG_KSU
ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif
\t/* We only trust the superuser with rebooting the system. */"""
    repl = """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif

SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
\t\tvoid __user *, arg)
{
\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);
\tchar buffer[256];
\tint ret = 0;

#ifdef CONFIG_KSU_SUSFS
\tret = ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
\tif (ret)
\t\tgoto orig_flow;
\treturn ret;
orig_flow:
\tret = 0;
#endif
\t/* We only trust the superuser with rebooting the system. */"""
    if target in text:
        return replace_once(text, target, repl, label)
    return replace_once(
        text,
        """SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
\t\tvoid __user *, arg)
{
\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);
\tchar buffer[256];
\tint ret = 0;

\t/* We only trust the superuser with rebooting the system. */""",
        repl,
        label,
    )


def patch_kernel_sys(text, label):
    if "ksu_handle_setresuid" in text:
        return text
    text = replace_once(
        text,
        """long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)
{
\tstruct user_namespace *ns = current_user_ns();""",
        """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif

long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)
{
\tstruct user_namespace *ns = current_user_ns();""",
        label + ":setresuid_ext",
    )
    text = replace_once(
        text,
        "\tkuid_t kruid, keuid, ksuid;",
        "\tkuid_t kruid, keuid, ksuid;\n\n#ifdef CONFIG_KSU_SUSFS\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif",
        label + ":setresuid_call",
    )
    text = replace_once(
        text,
        "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)",
        """#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
extern struct static_key_false susfs_is_uname_spoof_buffer_set;
extern void susfs_spoof_uname(struct new_utsname *tmp);
#endif

SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)""",
        label + ":uname_ext",
    )
    return replace_once(
        text,
        "\tup_read(&uts_sem);\n\tif (copy_to_user(name, &tmp, sizeof(tmp)))\n\t\treturn -EFAULT;\n\n\toverride_custom_release",
        """#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\tif (static_branch_likely(&susfs_is_uname_spoof_buffer_set))
\t\tsusfs_spoof_uname(&tmp);
#endif
\tup_read(&uts_sem);
\tif (copy_to_user(name, &tmp, sizeof(tmp)))
\t\treturn -EFAULT;

\toverride_custom_release""",
        label + ":uname_call",
    )


def patch_mm_memory(text, label):
    if "SUSFS_IS_INODE_SUS_MAP" in text:
        return text
    text = replace_once(
        text,
        "#include <linux/oom.h>",
        "#include <linux/oom.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux/susfs_def.h>\n#endif",
        label + ":inc",
    )
    return replace_once(
        text,
        """\t\tstruct page *page = NULL;

\t\tret = get_user_pages_remote(tsk, mm, addr, 1,
\t\t\t\tgup_flags, &page, &vma, NULL);""",
        """\t\tstruct page *page = NULL;

#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tvma = find_vma(mm, addr);
\t\tif (vma && vma->vm_start <= addr && vma->vm_file &&
\t\t    SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
\t\t\tbreak;
#endif
\t\tret = get_user_pages_remote(tsk, mm, addr, 1,
\t\t\t\tgup_flags, &page, &vma, NULL);""",
        label + ":access_remote_vm",
    )


def patch_security_selinux_avc(text, label):
    if "susfs_is_avc_log_spoofing_enabled" in text:
        return text
    text = replace_once(
        text,
        '#include "classmap.h"',
        """#include "classmap.h"
#ifdef CONFIG_KSU_SUSFS
extern u32 susfs_ksu_sid;
extern u32 susfs_priv_app_sid;
extern struct static_key_false susfs_is_avc_log_spoofing_enabled;
#endif""",
        label + ":inc",
    )
    return replace_once(
        text,
        """\trc = security_sid_to_context(state, tsid, &scontext, &scontext_len);
\tif (rc)
\t\taudit_log_format(ab, " tsid=%d", tsid);
\telse {
\t\taudit_log_format(ab, " tcontext=%s", scontext);
\t\tkfree(scontext);
\t}""",
        """\trc = security_sid_to_context(state, tsid, &scontext, &scontext_len);
#ifdef CONFIG_KSU_SUSFS
\tif (static_branch_likely(&susfs_is_avc_log_spoofing_enabled)) {
\t\tif (unlikely(tsid == susfs_ksu_sid)) {
\t\t\tif (rc)
\t\t\t\taudit_log_format(ab, " tsid=%d", susfs_priv_app_sid);
\t\t\telse {
\t\t\t\taudit_log_format(ab, " tcontext=%s", "u:r:priv_app:s0:c512,c768");
\t\t\t\tkfree(scontext);
\t\t\t}
\t\t\tgoto bypass_orig_flow;
\t\t}
\t}
#endif
\tif (rc)
\t\taudit_log_format(ab, " tsid=%d", tsid);
\telse {
\t\taudit_log_format(ab, " tcontext=%s", scontext);
\t\tkfree(scontext);
\t}
#ifdef CONFIG_KSU_SUSFS
bypass_orig_flow:
#endif""",
        label + ":avc_dump_query",
    )


PATCHES = [
    ("fs/Makefile", patch_fs_makefile),
    ("drivers/input/input.c", patch_drivers_input),
    ("fs/open.c", patch_fs_open),
    ("fs/read_write.c", patch_fs_read_write),
    ("fs/stat.c", patch_fs_stat),
    ("fs/exec.c", patch_fs_exec),
    ("fs/namei.c", patch_fs_namei),
    ("fs/namespace.c", patch_fs_namespace),
    ("fs/proc_namespace.c", patch_fs_proc_namespace),
    ("fs/readdir.c", patch_fs_readdir),
    ("fs/notify/fdinfo.c", patch_fs_notify_fdinfo),
    ("fs/proc/cmdline.c", patch_fs_proc_cmdline),
    ("fs/proc/fd.c", patch_fs_proc_fd),
    ("fs/proc/base.c", patch_fs_proc_base),
    ("fs/proc/task_mmu.c", patch_fs_proc_task_mmu),
    ("fs/statfs.c", patch_fs_statfs),
    ("fs/super.c", patch_fs_super),
    ("kernel/kallsyms.c", patch_kernel_kallsyms),
    ("kernel/reboot.c", patch_kernel_reboot),
    ("kernel/sys.c", patch_kernel_sys),
    ("mm/memory.c", patch_mm_memory),
    ("security/selinux/avc.c", patch_security_selinux_avc),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    apply_patches(root, PATCHES)
    print(f"[+] Applied SuSFS v2.3.0 patches to {len(PATCHES)} files in {root}")


if __name__ == "__main__":
    main()
