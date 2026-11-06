#!/usr/bin/env python3
import sys
import os

def patch_file(filepath, target, replacement, desc):
    if not os.path.exists(filepath):
        print(f"[-] ERROR: File {filepath} not found!")
        sys.exit(1)

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    if replacement.strip() in content:
        print(f"[+] {desc} already applied in {filepath}")
        return

    if target not in content:
        print(f"[*] Target string for {desc} not found in {filepath}, skipping (already clean/updated in upstream).")
        return

    content = content.replace(target, replacement, 1)
    with open(filepath, 'w', encoding='utf-8', newline='\n') as f:
        f.write(content)
    print(f"[+] Successfully applied: {desc} in {filepath}")

def patch_bitops(filepath):
    if not os.path.exists(filepath):
        print(f"[-] ERROR: File {filepath} not found!")
        sys.exit(1)

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    idx_def = content.find('#define set_mask_bits')
    if idx_def == -1:
        print(f"[*] #define set_mask_bits not found in {filepath}, skipping.")
        return

    idx_end = content.find('#endif', idx_def)
    block = content[idx_def:idx_end]

    if 'old__;' in block and 'new__;' not in block:
        print(f"[+] set_mask_bits return old__ already applied in {filepath}")
        return

    idx_last_new = block.rfind('new__;')
    if idx_last_new == -1:
        print(f"[*] last new__; not found in set_mask_bits block in {filepath}, skipping.")
        return

    block_fixed = block[:idx_last_new] + 'old__;' + block[idx_last_new + len('new__;'):]
    content_fixed = content[:idx_def] + block_fixed + content[idx_end:]

    with open(filepath, 'w', encoding='utf-8', newline='\n') as f:
        f.write(content_fixed)
    print(f"[+] Successfully fixed set_mask_bits return value in {filepath}")

def main():
    print("===> Menjalankan patch MemAvailable dan MGLRU counter fix...")

    # 1. Fix include/linux/bitops.h (set_mask_bits must return old__ instead of new__)
    patch_bitops('include/linux/bitops.h')

    # 2. Fix include/linux/mm_inline.h (preserve page generation in lru_gen_del_page if legacy pattern)
    target_del = 'gen = ((flags & LRU_GEN_MASK) >> LRU_GEN_PGOFF) - 1;'
    repl_del = '/* keep gen from page_lru_gen */'
    patch_file('include/linux/mm_inline.h', target_del, repl_del, 'Preserve gen in lru_gen_del_page')

    # 3. Patch mm/page_alloc.c (clamp si_mem_available to totalram_pages)
    target_page_alloc = '\tif (available < 0)\n\t\tavailable = 0;\n\treturn available;'
    repl_page_alloc = '\tif (available < 0)\n\t\tavailable = 0;\n\tif (available > totalram_pages)\n\t\tavailable = totalram_pages;\n\treturn available;'
    patch_file('mm/page_alloc.c', target_page_alloc, repl_page_alloc, 'Clamp si_mem_available to totalram_pages')

    # 4. Patch fs/proc/meminfo.c (clamp MemAvailable in /proc/meminfo to totalram)
    target_meminfo = '\tavailable = si_mem_available();\n\tsreclaimable = global_node_page_state(NR_SLAB_RECLAIMABLE);'
    repl_meminfo = '''\tavailable = si_mem_available();
\tif (available < 0)
\t\tavailable = 0;
\tif (available > i.totalram)
\t\tavailable = i.totalram;
\tsreclaimable = global_node_page_state(NR_SLAB_RECLAIMABLE);'''
    patch_file('fs/proc/meminfo.c', target_meminfo, repl_meminfo, 'Clamp MemAvailable in /proc/meminfo')

    print("[+] Semua patch MemAvailable dan MGLRU berhasil diperiksa dan diterapkan.")

if __name__ == '__main__':
    main()
