# Development & Debugging Log: Redmi 10C (fog / sm6225)
**Device**: Xiaomi Redmi 10C (`fog` / `wind` / `rain`)  
**SoC**: Qualcomm Snapdragon 680 4G (SM6225) — Kryo 265 (4x Cortex-A73 + 4x Cortex-A53)  
**Specs**: 4GB LPDDR4X RAM, UFS 2.2 Storage  
**OS**: Android 16 (AOSP)  
**Kernel Base**: Linux 4.19 (CAF Android Common Kernel)  
**Root Framework**: KernelSU-Next v3.4.0 (Legacy branch, Syscall Table Hook) + SuSFS v2.3.0  

---

## 1. Kronologi Riwayat Pengembangan & Bug Fix

### [2026-09-30] Setup Awal & Integrasi KernelSU-Next + SuSFS
* **Aktivitas**:
  * Setup CI GitHub Actions build kernel Redmi 10C (`.github/workflows/build-kernel.yml`).
  * Integrasi KernelSU-Next cabang `legacy` (non-GKI 4.19).
  * Integrasi patch SuSFS 4.19 upstream simonpunk (`susfs4ksu`).
  * Konfigurasi modul AnyKernel3 khusus `fog` (`BLOCK=boot`, `IS_SLOT_DEVICE=auto`).
* **Masalah yang Ditemukan**:
  1. Linker error pada `scripts/dtc/Makefile` akibat duplikasi `yamltree.o`.
  2. Missing link symbols antara SuSFS dan KernelSU-Next (`is_ksu_domain`, `is_zygote`, `ksu_try_umount`).
* **Solusi**:
  * Patch Makefile dtc versi bersih (`NO_YAML`).
  * Tambahkan compatibility glue code di `fs/susfs.c` (Commit `bd79ba8`).

---

### [2026-10-01] Perbaikan MemAvailable Leak, ReVanced Crash, & Handshake SuSFS

#### 1. Bug: MemAvailable Overflow / Memory Leak (MGLRU)
* **Gejala**: Penggunaan RAM terbaca gila (Free RAM melonjak puluhan GB / crash Out of Memory).
* **Root Cause**:
  * Makro `set_mask_bits` di kernel 4.19 `include/linux/bitops.h` mengembalikan `new__` bukan `old__`.
  * Akibatnya saat halaman memori dibebaskan (`lru_gen_del_page`), penentuan generasi halaman selalu bernilai `-1`.
  * Di `lru_gen_update_size`, `old_gen == -1` masuk ke cabang penambahan, sehingga counter memori terus bertambah tanpa pernah berkurang saat page dihapus.
* **Commit**: `44941fa`, `7d8fb46` (PR #3, #2).

#### 2. Bug: YouTube ReVanced / Morphe Force Close
* **Gejala**: Aplikasi yang butuh modul overlay (ReVanced/Morphe) langsung crash / tidak jalan.
* **Root Cause**:
  * `susfs_try_umount_all` dipanggil secara membabi-buta untuk semua UID, sehingga direktori `/data/adb/modules` dan `/product` di-unmount bahkan untuk aplikasi non-root yang butuh modul.
* **Solusi**:
  * Pengecekan `ksu_uid_should_umount(new_uid)` sebelum unmount modul dijalankan.
* **Commit**: `814b864` (PR #4).

#### 3. Bug: SuSFS Status "Unknown" di KernelSU Manager
* **Gejala**: Manager menampilkan SuSFS tidak terdeteksi meskipun kernel sudah dipatch.
* **Root Cause**:
  * KernelSU Manager versi baru memanggil `reboot(0xDEADBEEF, 0xFAFAFAFA, CMD_SUSFS_SHOW_*)` via `ksud`. Kernel 4.19 tidak memiliki handler reboot dispatch untuk SuSFS.
* **Solusi**:
  * Implementasi handler `ksu_handle_susfs_sys_reboot` di `supercall.c` dan hook `kernel/reboot.c`.
* **Commit**: `e2bca06`, `15c5c69`.

---

### [2026-10-02 s/d 2026-10-03] Investigasi & Perbaikan Aplikasi Bank Force Close

#### 1. Bug: Bank App Langsung Force Close (Deteksi Root)
* **Gejala**: Aplikasi perbankan langsung mental/force close saat dibuka.
* **Root Cause #1 (Timing Kredensial Zygote)**:
  * Di Android 14/15/16, Zygote beralih SELinux context ke `u:r:untrusted_app:s0` *sebelum* memanggil syscall `setresuid`.
  * Akibatnya `is_zygote(current_cred())` selalu menghasilkan `false`.
  * `susfs_try_umount_all` tidak pernah dijalankan untuk aplikasi bank, sehingga mountpoint `/data/adb/modules` terbaca telanjang oleh security library bank.
* **Root Cause #2 (Filter SuSFS Tertidur / Dormant)**:
  * Seluruh proteksi SuSFS di VFS (`/proc/self/mountinfo`, `dcache` lookup, `generic_fillattr`) digembok oleh pengecekan:
    ```c
    current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC
    ```
  * Flag ini tidak pernah diset di `setuid_hook.c`, sehingga filter SuSFS mati total untuk semua aplikasi pengguna.
* **Solusi**:
  * Buat helper `is_child_of_zygote()` yang memeriksa `current_cred()` dan `current->real_parent->cred`.
  * Set bit `TASK_STRUCT_NON_ROOT_USER_APP_PROC` pada `current->susfs_task_state` untuk `is_appuid` dan `is_isolated_process`.
* **Commit**: `baea87f` (PR #5).

#### 2. Bug: Konflik Modul BRENE (13 Fitur vs 9 Fitur)
* **Gejala**: Bank bisa jalan jika modul BRENE dinonaktifkan, namun force close jika BRENE aktif.
* **Root Cause**:
  * `CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y`: Memodifikasi `ovl_path_lowerdata` di `fs/overlayfs/inode.c`. Saat modul BRENE meng-overlay path sistem, terjadi dereference pointer liar atau perulangan rekursif `ST_RDONLY & ST_RELATIME`, memicu **SIGSEGV** di thread JVM aplikasi bank.
  * `CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y`: Menambahkan semua bind mount FUSE storage milik BRENE ke daftar unmount loop, menyebabkan file descriptor internal bank menjadi stale (`EBADF`).
* **Solusi**:
  * Matikan `SUS_OVERLAYFS`, `AUTO_ADD_TRY_UMOUNT`, dan `AUTO_ADD_SUS_*`.
  * Sesuaikan konfigurasi kernel ke standar emas SuSFS: **9 Fitur Stabil**.
* **Commit**: `2051ebb`.

#### 3. Bug: Fitur `sus_map` Hilang di Kernel 4.19
* **Gejala**: Module BRENE menampilkan 8/9 fitur aktif. Bank tetap force close karena modul Zygisk menyuntikkan `.so` ke memori yang terlihat di `/proc/self/maps`.
* **Root Cause**:
  * Di upstream resmi simonpunk, fitur `sus_map` hanya dibuat untuk kernel GKI (5.10+). Kernel 4.19 tidak memiliki `sus_map`.
* **Solusi**:
  * Backport `CONFIG_KSU_SUSFS_SUS_MAP` ke Kernel 4.19:
    1. Tambahkan `CMD_SUSFS_ADD_SUS_MAP (0x60020)` dan `AS_FLAGS_SUS_MAP (39)` di `include/linux/susfs_def.h`.
    2. Hook fungsi `show_map_vma` dan `show_smap` di `fs/proc/task_mmu.c` untuk memfilter VMA yang memiliki flag `AS_FLAGS_SUS_MAP`.
    3. Tambahkan handler `susfs_add_sus_map` dan case dispatch reboot.
  * Perbaiki deteksi unmount overlay di `ksu_should_umount` agar mengecek tipe `overlay` jika devname bukan `"KSU"`.
* **Commit**: `f6c14b6`, `541a5f2`.

#### 4. Bug Fatal: Hook `execveat` Terhalang Register `envp` di `syscall_table_hook.c`
* **Gejala**: Bank app tetap mendeteksi root bahkan saat modul dicopot total.
* **Root Cause**:
  * Di Android ARM64, libc bionic memetakan `execve` ke `execveat(AT_FDCWD, path, argv, envp, 0)`.
  * Hook `syscall_table_hook.c` sebelumnya dibatasi:
    ```c
    if ((int)PT_REGS_PARM1(regs) == AT_FDCWD && (int)PT_REGS_SYSCALL_PARM4(regs) == 0)
    ```
  * Pada ARM64 ABI, `PARM4` adalah register `regs[3]` (`envp`), nilainya di Android **tidak pernah 0**.
  * **Efek Rantai**:
    1. Syscall hook tidak pernah memanggil `ksu_handle_execve_ksud`.
    2. Eksekusi `init second_stage` tidak terdeteksi.
    3. Task work `ksu_initialize_selinux_tw_func` tidak pernah dijalankan.
    4. `cache_sid()` dan `setup_ksu_cred()` tidak pernah dieksekusi (`ksu_cred == NULL`).
    5. Karena `ksu_cred` kosong, modul unmount langsung membatalkan diri (`return 0`). Mount point root terbongkar ke seluruh aplikasi.
* **Solusi**:
  * Panggil `ksu_handle_execve_ksud` langsung pada setiap syscall `execveat` tanpa terhadang pengecekan argumen `envp`.
* **Commit**: `5216a45`.

#### 5. Upgrade Toolchain: ZyC Clang 16.0.6 (LLVM Polly)
* **Konteks**:
  * Proton Clang 13 (2021) sudah usang.
  * Neutron Clang (LLVM 19/20) memicu error kompilasi fatal pada driver CAF 4.19 lama karena aturan compiler modern yang terlalu ketat.
* **Solusi**:
  * Dipilih **ZyC Clang 16.0.6** sebagai compiler utama di CI workflow.
  * Dilengkapi **LLVM Polly Loop Optimizer** yang sangat optimal untuk instruksi SIMD NEON pada core Kryo 265 (Cortex-A73 & Cortex-A53) Snapdragon 680.
* **Commit**: `5216a45`.

---

## 2. Tabel Perbandingan Fitur SuSFS

| Fitur SuSFS | Status Awal (Crash) | Status Akhir (Fix & Stabil) | Fungsi |
|---|---|---|---|
| `sus_path` | Enabled | **Enabled** | Menyembunyikan path root dari syscall VFS |
| `sus_mount` | Enabled | **Enabled** | Menyembunyikan entri mount dari `/proc/self/mountinfo` |
| `auto_add_sus_ksu_default_mount` | Enabled | **Disabled** | Mencegah loop unmount otomatis pada storage FUSE |
| `auto_add_sus_bind_mount` | Enabled | **Disabled** | Mencegah interferensi dengan bind mount BRENE |
| `sus_kstat` | Enabled | **Enabled** | Spoof atribut inode/kstat (mtime, ctime, ino) |
| `sus_overlayfs` | Enabled | **Disabled** | **Penyebab utama crash SIGSEGV di Android 16** |
| `try_umount` | Enabled | **Disabled** (Diganti Kernel Umount KSU) | Menghindari konflik dengan internal umount KSU |
| `auto_add_try_umount_for_bind_mount` | Enabled | **Disabled** | Mencegah loop unmount agresif |
| `spoof_uname` | Enabled | **Enabled** | Menyamarkan versi kernel di syscall uname |
| `enable_log` | Enabled | **Enabled** | Logging kernel dmesg SuSFS |
| `hide_ksu_susfs_symbols` | Enabled | **Enabled** | Menghapus symbol KSU/SuSFS dari `/proc/kallsyms` |
| `spoof_cmdline_or_bootconfig` | Enabled | **Enabled** | Menyamarkan `verifiedbootstate=orange` jadi `green` |
| `open_redirect` | Enabled | **Enabled** | Mengalihkan target deteksi root ke file aman |
| `sus_map` | Tidak ada | **Enabled (Backported)** | Menyembunyikan file `.so` modul dari `/proc/self/maps` |

---

## 3. Catatan Hardware Tambahan: Modem & LTE Carrier Aggregation (CA)
* **Pertanyaan**: Kenapa Redmi 10C (SDM680) tidak bisa 4CA atau combo 2CA (B1 + B3)?
* **Kesimpulan Teknis**:
  1. Modem terintegrasi Snapdragon 680 adalah **Qualcomm Snapdragon X11 LTE**. Batas hardware maksimalnya adalah **2CA** (bukan 4CA).
  2. Redmi 10C adalah perangkat entry-level dengan pemangkasan biaya komponen RF (RFFE). Jalur antena fisik tidak memiliki duplexer/diplexer ganda untuk agregasi B1+B3 bersamaan.
  3. Baseband modem berjalan terisolasi di DSP Hexagon (`NON-HLOS.bin`). Kernel Linux Android hanya bertindak sebagai jembatan data paket IP (`rmnet_data`) dan tidak memiliki kontrol terhadap modulasi frekuensi baseband.

---

## 4. Ringkasan File Kritis yang Dimodifikasi
* `.github/workflows/build-kernel.yml`: Toolchain diupgrade ke ZyC Clang 16.0.6.
* `configs/ksu_susfs.config`: Profil 9 fitur SuSFS stabil (`sus_map` on, `overlayfs` & `auto_add` off).
* `scripts/setup-ksu-susfs.sh`:
  - Hook `syscall_table_hook.c`: bypass filter `envp` pada `execveat`.
  - Hook `setuid_hook.c`: Zygote lineage check (`is_child_of_zygote`) + task state propagation.
  - Backport `sus_map` di `fs/proc/task_mmu.c` dan `fs/susfs.c`.
  - Glue code unmount untuk mendeteksi mount overlayfs.
* `scripts/99-potato-fog.sh`: Penggunaan `resetprop -n` untuk menghindari audit SELinux.

---

### [2026-10-03 s/d 2026-10-04] Perbaikan Duck Detector, Error SuSFS 0x55550, Inode Spoofing, & CI Notifikasi

#### 1. Bug: KernelSU Magic prctl Leak (`errno=14` / `EFAULT`) di Duck Detector
* **Gejala**: Duck Detector mendeteksi *Direct Probes: 1* pada pengecekan `KernelSU prctl` dengan error code 14 (`EFAULT`).
* **Root Cause**:
  * Duck Detector mengirim magic prctl `0xDEADBEEF` dengan parameter invalid pointer untuk memancing respon error.
  * Pada kernel standar Linux tanpa KSU, syscall ini ditolak dengan `EINVAL` (22).
  * Di `syscall_table_hook.c`, handler menangkap `0xDEADBEEF` dari sembarang app (unprivileged UID), lalu memanggil `copy_to_user` ke invalid pointer sehingga crash pointer memicu `EFAULT` (14).
* **Solusi**:
  * Pada `ksu_sth_prctl`, tambahkan verifikasi validitas pointer argumen dan hak akses (`is_manager()` atau `uid == 0`). Caller tidak berhak langsung dialihkan ke `ksu_sth_call_orig(__NR_prctl, regs)` (mengembalikan `EINVAL`).
* **Commit**: `610f134`, `bd67635`.

#### 2. Bug: Shamiko "KernelSU version abnormal! Integrate as submodule instead of copying"
* **Gejala**: Module Shamiko gagal diflash di KernelSU Manager / Magisk dengan pesan error versi abnormal.
* **Root Cause**:
  * Skrip installer Shamiko (`customize.sh`) membatasi:
    ```sh
    elif [ "$KSU_KERNEL_VER_CODE" -ge 20000 ]; then
        abort "! KernelSU version abnormal! Please integrate KernelSU into your kernel as submodule instead of copying the source code"
    ```
  * KernelSU-Next secara default memakai format versi `33xxx` (offset 30000+), sehingga selalu terpicu abort oleh Shamiko.
* **Solusi**:
  * Set `KSU_VERSION_OVERRIDE=11998` dan `KSU_VERSION_FALLBACK := 11998` pada build (`10940 <= ver < 20000`), sehingga Shamiko membaca versi resmi valid.
* **Commit**: `d298aed`.

#### 3. Bug: CLI SuSFS & Brene Error `[-] CMD: '0x55550', SUSFS operation not supported`
* **Gejala**: Saat menjalankan `ksu_susfs add_sus_path` atau klik Apply di Brene, muncul respon `0x55550 operation not supported`.
* **Root Cause**:
  * Tool `ksu_susfs` v2.3.0 memanggil kernel melalui supercall `reboot(0xDEADBEEF, 0xFAFAFAFA, CMD_SUSFS_*, &payload)`.
  * Sebelum syscall, userspace menginisialisasi `payload.err = 126` (`ERR_CMD_NOT_SUPPORTED`).
  * Di `supercall.c`, dispatcher SuSFS belum menangani seluruh tabel perintah SuSFS v2.3.0 dan tidak pernah menulis balik `payload.err = 0` via `copy_to_user`. Nilai `err` tetap 126, memicu pesan error di userspace.
* **Solusi**:
  * Implementasikan full reboot dispatcher untuk ABI SuSFS v2.3.0 di `ksu_handle_susfs_sys_reboot`:
    - `0x55550` (`CMD_SUSFS_ADD_SUS_PATH`)
    - `0x55553` (`CMD_SUSFS_ADD_SUS_PATH_LOOP`)
    - `0x60020` (`CMD_SUSFS_ADD_SUS_MAP`)
    - `0x55560` / `0x55561` (`CMD_SUSFS_ADD_SUS_MOUNT` / `HIDE_SUS_MNTS`)
    - `0x55570` / `0x55571` / `0x55572` (kstat spoofing)
    - `0x55580` (`CMD_SUSFS_ADD_TRY_UMOUNT`)
    - `0x55590` (`CMD_SUSFS_SET_UNAME`)
    - `0x555a0` (`CMD_SUSFS_ENABLE_LOG`)
    - `0x555c0` (`CMD_SUSFS_ADD_OPEN_REDIRECT`)
  * Terapkan flag `(1 << 25)` (`INODE_STATE_SUS_PATH`) pada inode target dan salin `info.err = 0` kembali ke userspace.
* **Commit**: `6dea4c2`.

#### 4. Bug: Duck Detector Warning `Shell tmp: inode=102450` (`1 indirect hit`)
* **Gejala**: Duck Detector menandai kuning di `runtimeArtifacts` karena nomor inode `/data/local/tmp` berada di atas ambang batas 10000.
* **Root Cause**:
  * Folder `/data/local/tmp` sering mengalami pembuatan/penghapusan file sementara sehingga nomor inode melonjak tinggi (102450).
* **Solusi**:
  * Di `ksu_sth_newfstatat` (`syscall_table_hook.c`), saat proses membaca stat path `/data/local/tmp`, nilai `st->st_ino` dipalsukan menjadi `42` (`42 < 10000`).
* **Hasil**:
  * Peringatan indirect hit di Duck hilang total $\rightarrow$ Duck Detector bersih 100% (0 direct, 0 indirect).
* **Commit**: `6dea4c2`.

#### 5. Integrasi CI Bot Telegram & Refactoring Penamaan
* **Penyederhanaan Penamaan**: Mengubah "Godmode Potato" menjadi **Potato Suite** yang lebih profesional di seluruh file config, script, dan workflow.
* **Automated Telegram Delivery**:
  - Menambahkan step notifikasi via bot Telegram `@dukeduck_bot`.
  - Mengunggah file zip flashable kernel (`Kairos-SUSFS-Potato-fog-*.zip`) secara otomatis ke chat ID Telegram saat build sukses.
* **Commit**: `e557c93`, `d298aed`, `55c8cda`.

---

### Fase 6: Migrasi Total ke ReSukiSU v4.2.0-rc3, 8 Manual Hooks, dan Backport SuSFS GKI (2026-10-05)

#### 1. Migrasi Penuh ke ReSukiSU & Pencopotan KernelSU-Next
* **Latar Belakang**:
  - Terjadi konflik versi UAPI mismatch pada manager ("Manager update required" dan "version too low") akibat KernelSU-Next legacy menggunakan versi UAPI dan override versi 11998 yang tidak sinkron.
* **Solusi**:
  - Menghapus integrasi KernelSU-Next legacy sepenuhnya.
  - Mengintegrasikan upstream resmi [ReSukiSU/ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) (v4.2.0-rc3).
  - Mengimplementasikan 8 Manual Inline Kernel Hooks murni (tanpa Syscall Table Hooking di memori):
    * `kernel/sys.c`: `ksu_handle_setresuid`
    * `kernel/reboot.c`: `ksu_handle_sys_reboot`
    * `fs/exec.c`: `ksu_handle_execveat` & `ksu_handle_post_execveat`
    * `fs/open.c`: `ksu_handle_faccessat`
    * `fs/read_write.c`: `ksu_handle_sys_read`
    * `fs/stat.c`: `ksu_handle_stat` + penanganan `fake_ino = 2` untuk `/data/local/tmp`
    * `drivers/input/input.c`: `ksu_handle_input_handle_event`
    * `security/selinux/selinuxfs.c`: Un-static `sel_handle_status_ops` & `transaction_ops`
  - ReSukiSU Manager langsung terbaca **Full Featured** hijau sinkron 1:1.

#### 2. Backport GKI SuSFS v2.3.0 ke Linux 4.19
* **Latar Belakang**:
  - ReSukiSU memerlukan helper dan workqueue SuSFS cabang modern GKI 5.10+ yang tidak ada di kernel 4.19 simonpunk, menyebabkan linker error `undefined reference` pada `vmlinux`.
* **Solusi**:
  - Mem-backport thread flags `TIF_PROC_UMOUNTED`, `TIF_PROC_NO_SU`, `TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT` dan helper inline terkait ke `include/linux/susfs_def.h`.
  - Menginisialisasi `susfs_extra_works` via workqueue resmi di `susfs_init()` dan fungsi stub `susfs_start_sdcard_monitor_fn()` di `fs/susfs.c`.
  - Membungkus seluruh blok ekstensi dengan include guard `#ifndef _KSU_SUSFS_DEF_EXT_H` untuk mencegah error redefinisi kompiler.

#### 3. Resolusi SuSFS `0x555b0` & ReSuSFS `file_size too long`
* **Latar Belakang**:
  - ReSuSFS gagal mengeksekusi `set_cmdline_or_bootconfig` (error `0x555b0 unsupported` dan `file_size too long`).
* **Root Cause & Solusi**:
  - File `cmdline_or_bootconfig.txt` membengkak hingga 11 KB karena append komentar berulang; dibersihkan menjadi 1 baris ringkas (~1.1 KB).
  - ReSukiSU `ksud` mengalokasikan struct buffer 8192 byte (`err` di offset 8192), sedangkan tool lama memakai 4096 byte; kernel diperbarui untuk menulis balik `err = 0` di kedua offset (+4096 dan +8192).

#### 4. Paket Tooling Mandiri di `resusfs/`
* Menyiapkan kumpulan script siap pakai:
  - `ReSuSFS_apply-cmdline-bootconfig.sh` & `cmdline_or_bootconfig.txt`: Penyetelan cmdline aman.
  - `fix_android_data_selinux.sh`: Pemulihan kepemilikan dan restorecon SELinux `media_rw_data_file` untuk `/data/media/0/Android/data`.
  - `fix_boot_hash.sh`: Deteksi otomatis SHA-256 vbmeta fisik dan spoofing verified boot state green/locked untuk Native Detector.
  - `fix_shell_tmp_inode.sh`: Mounting tmpfs untuk userspace reset inode.
  - `sus_maps.txt`: Daftar library injeksi Zygisk aktual tanpa dependensi modul palsu.

#### 5. Instalasi Ekosistem Skill Developer
* Mengintegrasikan skill penunjang pengkodean ke `.claude/skills/`:
  - `ponytail` (+ audit, debt, gain, review)
  - `unlazy`
  - `anti-slop` (+ code, copywriting, human, layoutmobile, ui)
  - `superpowers` (debugging sistematis, TDD, verifikasi sebelum selesai, dll.)


