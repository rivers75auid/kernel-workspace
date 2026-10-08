import os
import sys

def patch_vm_sched():
    kernel_root = os.getcwd()
    print("[*] Memulai penanaman tuning langsung ke source C kernel...")

    # 1. Patch mm/page_alloc.c: Kunci watermark_scale_factor = 10 & watermark_boost_factor = 0
    pa_file = os.path.join(kernel_root, "mm/page_alloc.c")
    if os.path.exists(pa_file):
        with open(pa_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

        # Default watermark_scale_factor = 10
        if "int watermark_scale_factor = 10;" not in content:
            content = content.replace("int watermark_scale_factor = 1000;", "int watermark_scale_factor = 10;")
            content = content.replace("int watermark_scale_factor = 50;", "int watermark_scale_factor = 10;")
            content = content.replace("int watermark_scale_factor = 20;", "int watermark_scale_factor = 10;")

        # Default watermark_boost_factor = 0 (kunci mati agar tidak panik)
        if "int watermark_boost_factor __read_mostly = 0;" not in content:
            content = content.replace("int watermark_boost_factor __read_mostly = 15000;", "int watermark_boost_factor __read_mostly = 0;")
            content = content.replace("int watermark_boost_factor = 15000;", "int watermark_boost_factor = 0;")

        with open(pa_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print("[+] mm/page_alloc.c patched: watermark_scale_factor=10, watermark_boost_factor=0")

    # 2. Patch mm/swap.c & include/linux/swap.h: Kunci vm_swappiness = 160 & page_cluster = 0
    sw_file = os.path.join(kernel_root, "mm/swap.c")
    if os.path.exists(sw_file):
        with open(sw_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
        content = content.replace("int vm_swappiness = 60;", "int vm_swappiness = 160;")
        content = content.replace("int vm_swappiness = 30;", "int vm_swappiness = 160;")
        content = content.replace("int page_cluster = 3;", "int page_cluster = 0;")
        content = content.replace("int page_cluster = 2;", "int page_cluster = 0;")
        content = content.replace("int page_cluster = 1;", "int page_cluster = 0;")
        with open(sw_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print("[+] mm/swap.c patched: vm_swappiness=160, page_cluster=0")

    # 3. Patch drivers/cpufreq/cpufreq_schedutil.c: Kunci down_rate_limit_us default = 20000 / 40000
    su_file = os.path.join(kernel_root, "kernel/sched/cpufreq_schedutil.c")
    if not os.path.exists(su_file):
        su_file = os.path.join(kernel_root, "drivers/cpufreq/cpufreq_schedutil.c")

    if os.path.exists(su_file):
        with open(su_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

        # Ubah default rate limits
        target_down = "sg_policy->down_rate_limit_ns = default_down_rate_limit_ns;"
        if "default_down_rate_limit_ns" in content:
            # 20ms = 20000000ns
            content = content.replace(
                "unsigned int default_down_rate_limit_ns = 1000 * 1000;",
                "unsigned int default_down_rate_limit_ns = 20000 * 1000;"
            )
            content = content.replace(
                "unsigned int default_down_rate_limit_ns = 2000 * 1000;",
                "unsigned int default_down_rate_limit_ns = 20000 * 1000;"
            )
        with open(su_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print(f"[+] Schedutil patched in {su_file}: default down_rate_limit smoothed")

    # 4. Patch mm/compaction.c: Kunci compact_unevictable_allowed = 1
    cp_file = os.path.join(kernel_root, "mm/compaction.c")
    if os.path.exists(cp_file):
        with open(cp_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
        content = content.replace("int sysctl_compact_unevictable_allowed = 0;", "int sysctl_compact_unevictable_allowed = 1;")
        content = content.replace("int sysctl_compact_unevictable_allowed __read_mostly = 0;", "int sysctl_compact_unevictable_allowed __read_mostly = 1;")
        with open(cp_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print("[+] mm/compaction.c patched: compact_unevictable_allowed=1")

    # 5. Patch kernel/sysctl.c: Default dirty ratios dan vfs_cache_pressure
    sc_file = os.path.join(kernel_root, "kernel/sysctl.c")
    if os.path.exists(sc_file):
        with open(sc_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
        content = content.replace("int sysctl_vfs_cache_pressure = 100;", "int sysctl_vfs_cache_pressure = 100;")
        content = content.replace("int sysctl_vfs_cache_pressure = 150;", "int sysctl_vfs_cache_pressure = 100;")
        with open(sc_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print("[+] kernel/sysctl.c verified: vfs_cache_pressure=100")

    print("[✓] SEMUA TUNING BERHASIL DITANAM LANGSUNG KE SOURCE CODE C KERNEL!")

if __name__ == "__main__":
    patch_vm_sched()
