# Index Dokumentasi Kernel Redmi 10C (`fog`)

Dokumentasi lengkap riwayat pengembangan, investigasi bug, katalog fitur, dan log harian build kernel Redmi 10C (Qualcomm SM6225 / Snapdragon 680 / Android 16 / 4GB RAM).

---

## 1. Dokumen Utama

* **[BUGS_TRACKER.md](../BUGS_TRACKER.md)**: Daftar lengkap bug yang ditemukan dan diselesaikan (dicoret/strike `~~...~~`), akar masalah teknis, serta batasan hardware perangkat.
* **[FEATURES.md](../FEATURES.md)**: Katalog seluruh fitur yang diaktifkan, versi komponen, sumber upstream, serta daftar fitur yang dihapus/dinonaktifkan beserta alasan teknisnya.
* **[DEVELOPMENT_LOG.md](../../DEVELOPMENT_LOG.md)**: Rangkuman komprehensif master log dari awal proyek hingga selesai.

---

## 2. Riwayat Log Harian (Daily Progress)

| Tanggal | Dokumen | Fokus Utama |
|---|---|---|
| **2026-09-30** | [2026-09-30.md](2026-09-30.md) | Setup awal KernelSU-Next v3.4.0 legacy, integrasi SuSFS 4.19, perbaikan linker DTC Makefile, dan AnyKernel3 khusus `fog`. |
| **2026-10-01** | [2026-10-01.md](2026-10-01.md) | Perbaikan MemAvailable leak MGLRU (`set_mask_bits`), fix crash YouTube ReVanced (unmount check), dan supercall reboot SuSFS. |
| **2026-10-02** | [2026-10-02.md](2026-10-02.md) | Investigasi deteksi root bank app, perbaikan Zygote lineage timing (`is_child_of_zygote`), resolusi konflik modul BRENE (9-fitur), dan backport `sus_map`. |
| **2026-10-03** | [2026-10-03.md](2026-10-03.md) | Pemecahan akar masalah `execveat` register `envp` di `syscall_table_hook.c`, upgrade compiler ke **ZyC Clang 16 (LLVM Polly)** untuk SDM680, dan verifikasi bank app sukses. |
| **2026-10-04** | [2026-10-04.md](2026-10-04.md) | Penyelesaian tuntas SuSFS `0x55550` via full reboot dispatcher, perbaikan Duck Detector (prctl errno 14 & inode 102450), fix Shamiko version check, dan integrasi bot Telegram. |
| **2026-10-05** | [2026-10-05.md](2026-10-05.md) | Migrasi penuh ke official ReSukiSU v4.2.0-rc3, 8 manual kernel hooks, backport GKI SuSFS 5.10 ke 4.19, resolusi error `0x555b0`/`0x55572`, dan instalasi dev skills. |
