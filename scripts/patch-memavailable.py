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
        print(f"[-] ERROR: Target string for {desc} not found in {filepath}!")
        sys.exit(1)

    content = content.replace(target, replacement, 1)
    with open(filepath, 'w', encoding='utf-8', newline='\n') as f:
        f.write(content)
    print(f"[+] Successfully applied: {desc} in {filepath}")

def main():
    print("===> Menjalankan patch MemAvailable dan MGLRU counter fix...")

    # 1. Patch mm/page_alloc.c (clamp si_mem_available to totalram_pages)
    target_page_alloc = '	if (available < 0)\n\t\tavailable = 0;\n\treturn available;'
    repl_page_alloc = '	if (available < 0)\n\t\tavailable = 0;\n\tif (available > totalram_pages)\n\t\tavailable = totalram_pages;\n\treturn available;'
    patch_file('mm/page_alloc.c', target_page_alloc, repl_page_alloc, 'Clamp si_mem_available to totalram_pages')

    # 2. Patch fs/proc/meminfo.c (clamp MemAvailable in /proc/meminfo to totalram)
    target_meminfo = '	available = si_mem_available();\n\tsreclaimable = global_node_page_state(NR_SLAB_RECLAIMABLE);'
    repl_meminfo = '''	available = si_mem_available();
	if (available < 0)
		available = 0;
	if (available > i.totalram)
		available = i.totalram;
	sreclaimable = global_node_page_state(NR_SLAB_RECLAIMABLE);'''
    patch_file('fs/proc/meminfo.c', target_meminfo, repl_meminfo, 'Clamp MemAvailable in /proc/meminfo')

    # 3. Patch include/linux/mm_inline.h (fix MGLRU active page counter drift)
    target_mm_inline = '''	/* addition */
	if (old_gen < 0) {
		if (lru_gen_is_active(lruvec, new_gen))
			lru += LRU_ACTIVE;
		update_lru_size(lruvec, lru, zone, delta);
		return;
	}

	/* deletion */
	if (new_gen < 0) {
		if (lru_gen_is_active(lruvec, old_gen))
			lru += LRU_ACTIVE;
		update_lru_size(lruvec, lru, zone, -delta);
		return;
	}

	/* promotion */
	if (!lru_gen_is_active(lruvec, old_gen) && lru_gen_is_active(lruvec, new_gen)) {
		update_lru_size(lruvec, lru, zone, -delta);
		update_lru_size(lruvec, lru + LRU_ACTIVE, zone, delta);
	}

	/* demotion requires isolation, e.g., lru_deactivate_fn() */
	VM_WARN_ON_ONCE(lru_gen_is_active(lruvec, old_gen) && !lru_gen_is_active(lruvec, new_gen));
}'''
    repl_mm_inline = '''	/* promotion */
	if (old_gen != -1 && new_gen != -1)
		return;

	if (old_gen >= 0)
		delta = -delta;

	update_lru_size(lruvec, lru, zone, delta);
}'''
    patch_file('include/linux/mm_inline.h', target_mm_inline, repl_mm_inline, 'MGLRU active counter leak fix')

    print("[+] Semua patch MemAvailable dan MGLRU berhasil diterapkan tanpa error.")

if __name__ == '__main__':
    main()
