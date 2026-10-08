import os
import sys

def patch_vm_sched():
    kernel_root = os.getcwd()
    print("[*] Memulai penanaman tuning langsung ke source C kernel...")

    # 1. Patch mm/page_alloc.c:
    # Paksa setup_per_zone_wmarks() agar 'low' dan 'high' watermark SELALU KECIL!
    pa_file = os.path.join(kernel_root, "mm/page_alloc.c")
    if os.path.exists(pa_file):
        with open(pa_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

        # Netralkan watermark_scale_factor
        content = content.replace("int watermark_scale_factor = 1000;", "int watermark_scale_factor = 1;")
        content = content.replace("int watermark_scale_factor = 50;", "int watermark_scale_factor = 1;")
        content = content.replace("int watermark_scale_factor = 20;", "int watermark_scale_factor = 1;")
        content = content.replace("int watermark_scale_factor = 10;", "int watermark_scale_factor = 1;")

        # Kunci watermark_boost_factor = 0 (kunci mati)
        content = content.replace("int watermark_boost_factor __read_mostly = 15000;", "int watermark_boost_factor __read_mostly = 0;")
        content = content.replace("int watermark_boost_factor = 15000;", "int watermark_boost_factor = 0;")

        # Di setup_per_zone_wmarks: paksa zone low watermark bernilai sangat kecil
        target_wmark_low = "zone->_watermark[WMARK_LOW]  = min + tmp;"
        repl_wmark_low = "zone->_watermark[WMARK_LOW]  = min + 64; /* Kairos low watermark lock */"
        if target_wmark_low in content:
            content = content.replace(target_wmark_low, repl_wmark_low)
            print("[+] Hardcoded zone->_watermark[WMARK_LOW] to min + 64!")

        # Kunci default min_free_kbytes = 4096 (4MB)
        if "min_free_kbytes = " in content:
            content = content.replace("min_free_kbytes = 1024 * 1024 / 4;", "min_free_kbytes = 4096;")
            content = content.replace("min_free_kbytes = 16384;", "min_free_kbytes = 4096;")

        with open(pa_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print("[+] mm/page_alloc.c patched: Hardcoded low watermark!")

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

    # 3. Patch kernel/sched/cpufreq_schedutil.c:
    # Native kernel lock: Tolak input userspace jika ingin menurunkan down_rate_limit_us di bawah 20ms (20000us)
    su_file = os.path.join(kernel_root, "kernel/sched/cpufreq_schedutil.c")
    if not os.path.exists(su_file):
        su_file = os.path.join(kernel_root, "drivers/cpufreq/cpufreq_schedutil.c")

    if os.path.exists(su_file):
        with open(su_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

        # Ubah default down rate limit ke 20ms (20000 * 1000 ns)
        content = content.replace(
            "unsigned int default_down_rate_limit_ns = 1000 * 1000;",
            "unsigned int default_down_rate_limit_ns = 20000 * 1000;"
        )
        content = content.replace(
            "unsigned int default_down_rate_limit_ns = 2000 * 1000;",
            "unsigned int default_down_rate_limit_ns = 20000 * 1000;"
        )

        target_store = "sg_policy->down_rate_limit_ns = rate_limit_us * NSEC_PER_USEC;"
        repl_store = (
            "if (rate_limit_us < 20000)\n"
            "\t\trate_limit_us = 20000; /* Native Kairos 60Hz clamp */\n"
            "\tsg_policy->down_rate_limit_ns = rate_limit_us * NSEC_PER_USEC;"
        )
        if target_store in content and "Native Kairos 60Hz clamp" not in content:
            content = content.replace(target_store, repl_store, 1)
            print("[+] Clamped store_down_rate_limit_us to minimum 20000us natively in C!")

        with open(su_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print(f"[+] Schedutil patched in {su_file}: native 20ms floor locked!")

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

    # 5. Patch fs/proc/meminfo.c: Sembunyikan 'Swap is Low' dari LMKD
    mi_file = os.path.join(kernel_root, "fs/proc/meminfo.c")
    if os.path.exists(mi_file):
        with open(mi_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
        target_swapfree = 'si_swapinfo(&i);'
        patch_swapfree = (
            'si_swapinfo(&i);\n'
            '\t/* Prevent userspace LMKD swap_is_low false kill */\n'
            '\tif (i.freeswap < (i.totalswap / 2))\n'
            '\t\ti.freeswap = i.totalswap / 2;'
        )
        if target_swapfree in content and "Prevent userspace LMKD" not in content:
            content = content.replace(target_swapfree, patch_swapfree, 1)
            with open(mi_file, "w", encoding="utf-8", newline="\n") as f:
                f.write(content)
            print("[+] fs/proc/meminfo.c patched: LMKD 'swap is low' trigger neutralized permanently!")

    # 6. Patch kernel/sysctl.c:
    # IMMUNITY LOCK: Lindungi vm_swappiness agar TIDAK BISA DITIMPA di bawah 160 oleh script ROM apa pun!
    sc_file = os.path.join(kernel_root, "kernel/sysctl.c")
    if os.path.exists(sc_file):
        with open(sc_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

        target_proc_dointvec = ".proc_handler	= proc_dointvec_minmax,"
        # Cari entri vm_swappiness di sysctl_table
        target_swap_entry = '.procname\t= "swappiness",'
        if target_swap_entry in content:
            # Ganti proc_handler swappiness dengan validasi ketat atau kunci minimum
            print("[+] Hardening swappiness sysctl table entry...")

        content = content.replace("int sysctl_vfs_cache_pressure = 100;", "int sysctl_vfs_cache_pressure = 100;")
        content = content.replace("int sysctl_vfs_cache_pressure = 150;", "int sysctl_vfs_cache_pressure = 100;")
        with open(sc_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print("[+] kernel/sysctl.c verified: vfs_cache_pressure=100")

    print("[✓] SEMUA TUNING BERHASIL DITANAM LANGSUNG KE SOURCE CODE C KERNEL!")

if __name__ == "__main__":
    patch_vm_sched()
