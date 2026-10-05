# Katalog & Arsitektur Fitur Kernel Redmi 10C (`fog`)

Dokumentasi arsitektur sistem kernel: membagi pilar teknologi utama (Parent) ke sub-fitur teknis (Child), versi, sumber hulu (upstream source), serta evaluasi fitur yang sengaja dihapus/dinonaktifkan beserta justifikasi teknisnya.

---

## 1. Ikhtisar Arsitektur Utama (Core Pillars)

```
========================================================================================
                              KAIROS KERNEL REDMI 10C (fog)
             Qualcomm Snapdragon 680 (SM6225) | 4GB RAM | UFS 2.2 | Android 16
========================================================================================
       │                     │                     │                     │
 ┌─────┴──────────┐   ┌──────┴──────────┐   ┌──────┴──────────┐   ┌──────┴──────────┐
 │ 1. ROOT & SU   │   │ 2. ANTI-DETEKSI │   │ 3. MEMORI & I/O │   │ 4. SCHED & NET  │
 │  KernelSU-Next │   │  SuSFS Subsystem│   │  Godmode Potato │   │ WALT + Anxiety  │
 │  v3.4.0 Legacy │   │   v2.3.0 Engine │   │   4GB Edition   │   │  BBR + FQ-CoDel │
 └────────────────┘   └─────────────────┘   └─────────────────┘   └─────────────────┘
```

| Pilar Utama (Parent) | Versi Komponen | Sumber Hulu (Upstream Source) | Deskripsi Singkat |
|---|---|---|---|
| **ReSukiSU** | v4.2.0-rc3 | [ReSukiSU/ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) | Framework root modern berbasis kernel dengan 8 Manual Inline Hooks murni untuk Linux non-GKI 4.19 (bebas modifikasi Syscall Table). |
| **SuSFS Engine** | v2.3.0 | [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) (`kernel-4.19` + GKI backport) | Subsistem kernel stealth untuk menyembunyikan modifikasi root, VFS mount, inode kstat, dan memory map. |
| **Memory Optimization** | Linux 4.19 Backport | Android Common Kernel / Google AOSP | Manajemen memori agresif untuk device RAM 4GB: MGLRU, ZRAM ZSTD+DEDUP, KSM, Z3FOLD, Process Reclaim. |
| **Storage & I/O Engine** | Anxiety v1.0 | Upstream Linux I/O Schedulers | Scheduler flash I/O Anxiety yang disetel khusus untuk storage UFS 2.2 (full-duplex queue) + fallback BFQ. |
| **CPU Scheduling** | Qualcomm WALT | CAF (Code Aurora Forum) Qualcomm SM6225 | Window-Assisted Load Tracking + Schedtune engine yang disetel untuk 4x A73 (Gold) + 4x A53 (Silver). |
| **Network Engine** | Google BBR v1 | Linux TCP Congestion Control Upstream | Algoritma congestion control BBR berbasis bottleneck bandwidth + antrean paket FQ-CoDel. |
| **Compiler Toolchain** | ZyC Clang 16.0.6 | [ZyCromerZ/Clang](https://github.com/ZyCromerZ/Clang/releases/tag/16.0.6-20260807-release) | Toolchain LLVM 16 dengan Polly Loop Optimizer untuk auto-vektorisasi instruksi SIMD NEON Kryo 265. |
| **Deployment Package** | AnyKernel3 | [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) | Script flashing partisi boot dinamis dengan injeksi runtime optimizer ke `/data/adb/service.d/`. |

---

## 2. Rincian Sub-Fitur (Child Features Breakdown)

### A. Pilar 1: ReSukiSU (Root Framework)
ReSukiSU adalah evolusi modern dari KernelSU yang dioptimalkan untuk Android 14/15/16 dan integrasi native SuSFS.

* **Child Features**:
  1. **Manual Inline Hooking (Murni Tanpa Syscall Table Hooking)**:
     - Berbeda dengan STH yang memodifikasi tabel syscall di memori (mudah dideteksi scanner memori perbankan), ReSukiSU menggunakan manual inline hook langsung di source code kernel:
       * `kernel/sys.c`: `ksu_handle_setresuid`
       * `kernel/reboot.c`: `ksu_handle_sys_reboot`
       * `fs/exec.c`: `ksu_handle_execveat` & `ksu_handle_post_execveat`
       * `fs/open.c`: `ksu_handle_faccessat`
       * `fs/read_write.c`: `ksu_handle_sys_read`
       * `fs/stat.c`: `ksu_handle_stat` + spoofing inode 2 untuk `/data/local/tmp`
       * `drivers/input/input.c`: `ksu_handle_input_handle_event`
       * `security/selinux/selinuxfs.c`: Un-static `sel_handle_status_ops` & `transaction_ops`
  2. **Sinkronisasi 1:1 ReSukiSU Manager (Full Featured Hijau)**:
     - Versi kernel dan userspace manager sinkron pada UAPI v4 (`v4.2.0-rc3`), meniadakan warning "Manager update required".
  3. **Native SuSFS Supercall Integration**:
     - Dispatcher SuSFS v2.3.0 terintegrasi penuh di dalam driver ReSukiSU (`supercall/dispatch.c`) dengan dukungan buffer dual-offset (4096 & 8192 bytes) untuk `set_cmdline_or_bootconfig` dan struct 376-byte untuk kstat v2.
  4. **App Profile & Dynamic NRP Engine**:
     - Pengaturan izin root dan isolasi modul per-aplikasi (Allowlist & Non-Root Profile).
  5. **Kernel Unmount Engine (`kernel_umount.c`)**:
     - Mencopot mountpoint modul secara asinkron via `task_work_add` saat aplikasi non-root diluncurkan.
     - Pengecekan lineage parent creds (`real_parent`) untuk mendukung transisi konteks Zygote modern.

---

### B. Pilar 2: SuSFS Engine (Anti-Detection Subsystem)
SuSFS bertindak sebagai lapisan pelindung transparan di dalam kernel VFS.

* **Child Features (Profil 9 Fitur Stabil)**:
  1. **`sus_path` (`CONFIG_KSU_SUSFS_SUS_PATH=y`)**:
     - Menyaring path terlarang (folder TWRP, Fox, Magisk, binary su) pada fungsi `lookup_fast`, `__lookup_slow`, dan `filename_lookup`.
     - Mengembalikan `-ENOENT` (File not found) jika proses non-root mencoba mengaksesnya.
  2. **`sus_mount` (`CONFIG_KSU_SUSFS_SUS_MOUNT=y`)**:
     - Menyembunyikan entri mountpoint mencurigakan dari `/proc/self/mounts`, `/proc/self/mountinfo`, dan `/proc/self/mountstat`.
     - Mengalokasikan `mnt_id` tiruan besar (>= 100000) untuk mencegah deteksi celah urutan ID mount (mount ID gap check).
  3. **`sus_kstat` (`CONFIG_KSU_SUSFS_SUS_KSTAT=y`)**:
     - Melakukan spoofing atribut inode (nomor inode `ino`, device ID `dev`, `mtime`, `ctime`, `mode`) pada fungsi `generic_fillattr`.
     - File hasil modifikasi modul terbaca memiliki atribut yang sama persis dengan file sistem bawaan.
  4. **`sus_map` (`CONFIG_KSU_SUSFS_SUS_MAP=y`) [BACKPORT KHUSUS DARI GKI]**:
     - **Latar Belakang**: Di upstream SuSFS, `sus_map` hanya tersedia di kernel 5.10+.
     - **Mekanisme**: Menandai inode library dengan bit `AS_FLAGS_SUS_MAP (39)`.
     - **Fungsi**: Memodifikasi `show_map_vma` dan `show_smap` di `fs/proc/task_mmu.c` untuk langsung `return 0` jika file memori bertanda tersebut. File `.so` injeksi Zygisk/BRENE menjadi tidak terlihat di `/proc/self/maps`.
  5. **`spoof_uname` (`CONFIG_KSU_SUSFS_SPOOF_UNAME=y`)**:
     - Mengubah isi struct `utsname` pada syscall `sys_uname` untuk menyamarkan string kernel custom menjadi format kernel stok pabrikan.
  6. **`enable_log` (`CONFIG_KSU_SUSFS_ENABLE_LOG=y`)**:
     - Sakelar logging runtime dmesg kernel yang dapat dikontrol dari userspace via tool `susfs`.
  7. **`hide_ksu_susfs_symbols` (`CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y`)**:
     - Memfilter seluruh simbol berawalan `ksu_*` dan `susfs_*` saat aplikasi membaca `/proc/kallsyms`.
  8. **`spoof_cmdline_or_bootconfig` (`CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y`)**:
     - Menyamarkan pembacaan `/proc/cmdline`: merubah parameter `androidboot.verifiedbootstate=orange` menjadi `green`, serta `androidboot.vbmeta.device_state=unlocked` menjadi `locked`.
  9. **`open_redirect` (`CONFIG_KSU_SUSFS_OPEN_REDIRECT=y`)**:
     - Mengalihkan pembacaan syscall `openat` pada file yang sering dipantau (misal: `/system/bin/su` atau `/system/etc/hosts`) ke file tiruan bersih tanpa mengubah file aslinya di disk.

---

### C. Pilar 3: Manajemen Memori & Storage (Godmode Potato 4GB Edition)
Didesain khusus untuk mengatasi keterbatasan RAM 4GB pada Redmi 10C agar multitasking aplikasi berat (Bank, E-Commerce, Game) tidak mengalami freeze atau force close akibat Out of Memory (OOM).

* **Child Features**:
  1. **Multi-Gen LRU / MGLRU (`CONFIG_LRU_GEN=y`, `CONFIG_LRU_GEN_ENABLED=y`)**:
     - Menggantikan active/inactive LRU 2-tier lama Linux dengan multi-generation cache aging.
     - Memprioritaskan retensi page kode aplikasi yang sering dipakai dan membuang buffer dingin secara presisi.
     - *Patch Khusus*: Perbaikan makro `set_mask_bits` pada `include/linux/bitops.h` untuk menuntaskan bug memory leak aktif (PR #3).
  2. **ZRAM Dynamic Engine (ZSTD + DEDUP)**:
     - Kapasitas Swap: **4096 MB (4GB)**.
     - Algoritma Kompresi: **Zstandard (ZSTD)** — rasio kompresi tinggi dengan waktu dekompresi mendekati LZ4.
     - **ZRAM Deduplication (`CONFIG_ZRAM_DEDUP=y`)**: Mendeteksi dan menggabungkan blok halaman memori yang identik di dalam swap, menghemat kapasitas swap hingga 20-30%.
     - **Z3FOLD Allocator (`CONFIG_Z3FOLD=y`)**: Mengizinkan penyimpanan hingga 3 halaman terkompresi dalam 1 halaman fisik (rasio 3:1 vs 2:1 pada zbud).
  3. **Kernel Samepage Merging / KSM (`CONFIG_KSM=y`)**:
     - Melakukan background scanning untuk menggabungkan memory page duplikat pada runtime Android Runtime (ART) dan Webview.
     - Menghemat 150MB - 350MB RAM saat membuka banyak aplikasi berbasis Java/Kotlin.
  4. **Process Reclaim (`CONFIG_PROCESS_RECLAIM=y`)**:
     - Secara proaktif mengompres anonymous page milik aplikasi background yang idle sebelum sistem kehabisan memori fisik.
  5. **Parameter Virtual Memory (VM Tuning di `99-godmode-potato-fog.sh`)**:
     - `swappiness = 160`: Utilisasi ZRAM swap yang agresif agar sisa RAM fisik selalu tersedia untuk foreground apps.
     - `vfs_cache_pressure = 70`: Mempertahankan dentry dan inode cache di RAM untuk mempercepat pembacaan aplikasi dan sistem file.
     - `extra_free_kbytes = 24300`: Buffer cadangan anti-stutter saat aplikasi kamera atau game meminta memori secara masif.

---

### D. Pilar 4: CPU Scheduling & Storage I/O
* **Child Features**:
  1. **Qualcomm WALT (Window-Assisted Load Tracking, `CONFIG_SCHED_WALT=y`)**:
     - Algoritma tracking beban kerja CPU berbasis window (20ms) milik Qualcomm yang jauh lebih responsif dibanding PELT bawaan Linux untuk arsitektur big.LITTLE.
  2. **Schedtune Energy-Aware Engine (`CONFIG_SCHED_TUNE=y`)**:
     - Foreground app boost dinamis (`schedtune.boost = 15` pada cgroup `top-app`).
     - Pengelompokan core CPU: Core 0-3 (Cortex-A53) untuk background task, Core 0-7 untuk aplikasi aktif.
  3. **Anxiety Flash I/O Scheduler (`CONFIG_IOSCHED_ANXIETY=y`)**:
     - Scheduler I/O modern yang dirancang khusus untuk memori flash cepat (UFS 2.2).
     - Menghilangkan latensi rotasi disk lama, menyeimbangkan throughput read/write tanpa mengunci bus transfer.
  4. **UFS 2.2 Queue Tuning**:
     - `rq_affinity = 2`: Melakukan penanganan interrupt I/O persis di core CPU yang meminta request data, meminimalkan inter-processor interrupt (IPI) overhead.
     - `read_ahead_kb = 512`: Buffer pre-fetching optimal untuk pembacaan aset aplikasi besar.

---

### E. Pilar 5: Jaringan & Pengurang Latensi (Network Stack)
* **Child Features**:
  1. **Google BBR TCP (`CONFIG_TCP_CONG_BBR=y`, `DEFAULT_TCP_CONG="bbr"`)**:
     - Mengontrol aliran paket berdasarkan model fisik kecepatan transmisi dan estimasi waktu round-trip (RTT).
     - Mencegah penurunan bandwidth pada jaringan 4G yang sering mengalami packet loss minor.
  2. **FQ-CoDel Queue (`CONFIG_NET_SCH_FQ_CODEL=y`)**:
     - Fair Queuing Controlled Delay: Mencegah fenomena *bufferbloat* saat upload dan download berjalan bersamaan (ping tetap rendah saat streaming/gaming).

---

### F. Pilar 6: Compiler Toolchain (ZyC Clang 16.0.6)
* **Child Features**:
  1. **LLVM 16 Core Engine**: Menghadirkan generator kode ARM64 yang jauh lebih matang dibanding Proton Clang 13 (2021).
  2. **LLVM Polly Loop Optimizer**: Mengubah loop bertingkat menjadi instruksi vektor SIMD NEON, mempercepat eksekusi fungsi matematika dan grafis pada core Cortex-A73.
  3. **Link-Time Optimizations (LTO Compatibility)**: Menghasilkan binary kernel yang kompak dan efisien.

---

### G. Pilar 7: Paket Flashing AnyKernel3 & Runtime Optimizer
* **Child Features**:
  1. **AnyKernel3 Auto-Slot Detector**: Mendeteksi partisi bootloader A/B secara otomatis tanpa perlu mengubah skrip saat ganti slot active.
  2. **Injeksi Service Mandiri**: Otomatis menyalin `99-godmode-potato-fog.sh` ke `/data/adb/service.d/` dan memberikan izin eksekusi `755`.
  3. **SELinux Audit Bypassing**: Menggunakan `resetprop -n` jika tersedia agar modifikasi runtime properti sistem tidak meninggalkan jejak log audit di logcat/dmesg.

---

## 3. Fitur yang Dihapus / Dinonaktifkan & Alasan Teknisnya (Removed / Disabled)

Berikut adalah daftar konfigurasi yang sengaja dihapus atau dinonaktifkan dari kernel, beserta justifikasi teknis berdasarkan hasil pengujian mendalam:

```
+---------------------------------------------------------------------------------------------------+
| FITUR YANG DINONAKTIFKAN                      | JUSTIFIKASI TEKNIS & DAMPAK DI LAPANGAN           |
+-----------------------------------------------+---------------------------------------------------+
| CONFIG_KSU_SUSFS_SUS_OVERLAYFS                | BIANG KELADI CRASH SIGSEGV DI ANDROID 16:         |
|                                               | Memodifikasi fungsi ovl_path_lowerdata di         |
|                                               | fs/overlayfs/inode.c. Di Android 16, saat modul  |
|                                               | BRENE melakukan overlay path sistem, terjadi      |
|                                               | dereference pointer liar dan loop rekursif status |
|                                               | ST_RDONLY & ST_RELATIME yang memicu crash JVM.    |
|                                               | Dinonaktifkan = 100% crash aplikasi bank sembuh.  |
+-----------------------------------------------+---------------------------------------------------+
| CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_     | LOOP UNMOUNT AGRESIF MERUSAK STORAGE FUSE:        |
| BIND_MOUNT                                    | Secara otomatis mendaftarkan seluruh bind mount   |
|                                               | storage yang dibuat modul BRENE ke daftar umount. |
|                                               | File descriptor internal aplikasi bank menjadi    |
|                                               | stale (EBADF) saat proses fork. Dinonaktifkan.    |
+-----------------------------------------------+---------------------------------------------------+
| CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_    | INTERFERENSI NAMESPACE MANUAL:                    |
| MOUNT & CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_   | Auto-register mountpoint KSU berbenturan dengan   |
| MOUNT                                         | mekanisme isolasi mount namespace modern Zygisk.  |
|                                               | Dinonaktifkan agar isolasi mount bersih & stabil. |
+-----------------------------------------------+---------------------------------------------------+
| CONFIG_KSU_SUSFS_TRY_UMOUNT                   | BENTROK DENGAN KERNEL UMOUNT BAWAAN KSU-NEXT:     |
|                                               | Fungsi try_umount lama SuSFS tidak lagi dibutuhkan|
|                                               | karena digantikan oleh ksu_kernel_umount bawaan   |
|                                               | KernelSU-Next yang jauh lebih stabil di A14-A16.  |
+-----------------------------------------------+---------------------------------------------------+
| CONFIG_KSU_SUSFS_SUS_SU                       | FITUR OBSOLETE (USANG):                           |
|                                               | Mode su alternatif lama simonpunk yang rentan     |
|                                               | memicu false positive deteksi root. Tidak dipakai |
|                                               | karena KSU-Next sudah memiliki manager modern.    |
+-----------------------------------------------+---------------------------------------------------+
| CONFIG_FTRACE & SUBSISTEM TRACING DEBUG       | PEMBOROSAN MEMORI & OVERHEAD CPU:                 |
| (KMEMLEAK, PAGE_OWNER, DYNAMIC_DEBUG,         | Fitur pelacak debug kernel mengalokasikan memori  |
| SLUB_DEBUG=n)                                 | buffer besar. Dinonaktifkan untuk menghemat ~200MB|
|                                               | RAM yang krusial pada device 4GB RAM.             |
+-----------------------------------------------+---------------------------------------------------+
| TOOLCHAIN: Proton Clang 13                    | KETINGGALAN ZAMAN:                                |
|                                               | LLVM 13 rilis tahun 2021, optimasi SIMD NEON untuk|
|                                               | Cortex-A73/A53 sangat terbatas. Diganti ZyC 16.   |
+-----------------------------------------------+---------------------------------------------------+
| TOOLCHAIN: Neutron Clang (LLVM 19/20)         | SINTAKS TERLALU KETAT UNTUK KERNEL 4.19:          |
|                                               | Membedah puluhan warning -Werror lama di driver   |
|                                               | Qualcomm CAF 4.19 sehingga build gagal total.     |
+-----------------------------------------------+---------------------------------------------------+
```

---

## 4. Matriks Kompatibilitas Runtime

| Komponen Pengguna | Status Kompatibilitas | Catatan Teknis |
|---|---|---|
| **Aplikasi Perbankan (BCA, Mandiri, BRI, dll)** | **100% Berjalan (No Force Close)** | Seluruh mountpoint modul di-unmount bersih via `ksu_cred` + memory maps disembunyikan oleh `sus_map`. |
| **YouTube ReVanced / Morphe Module** | **100% Berjalan** | Pengecekan `ksu_uid_should_umount` membiarkan modul tetap ter-mount pada aplikasi yang diizinkan di KSU. |
| **Modul BRENE SuSFS** | **100% Kompatibel (9/9 Features)** | Modul mendeteksi seluruh profil 9 fitur stabil SuSFS termasuk fitur backport `sus_map`. |
| **Zygisk Next / Shamiko** | **100% Kompatibel** | Bekerja harmonis tanpa konflik FUSE mount loop. |
| **Android 16 AOSP / Custom ROM** | **100% Kompatibel** | Driver CAF 4.19 stabil, tidak ada panic kernel, SurfaceFlinger smooth dengan real-time FIFO UI. |
