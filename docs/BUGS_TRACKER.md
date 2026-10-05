# Bugs & Issues Tracker: Redmi 10C (`fog`) Kernel

Status Pelacakan Bug:
- `[FIXED]`: Bug telah diselesaikan, diuji, dan dicoret (`~~strikethrough~~`).
- `[LIMITATION]`: Batasan fisik hardware/firmware di luar kontrol kernel Linux.

---

## 1. Daftar Bug yang Telah Diperbaiki (Resolved)

### ~~1. [FIXED] Duplikasi Objek di `scripts/dtc/Makefile`~~
- **Tanggal Ditemukan**: 2026-09-30
- **Tanggal Selesai**: 2026-09-30
- **Commit**: `0bea9e1`
- **Gejala**: Linker error saat build device tree compiler (`dtc`): `multiple definition of 'yamltree'`.
- **Penyebab**: Makefile upstream memicu kompilasi parser YAML yang duplikat di Ubuntu 22.04 runner.
- **Solusi**: Dibuat patch bersih `patches/dtc_Makefile` dengan flag `NO_YAML`.

---

### ~~2. [FIXED] Missing Link Symbols KernelSU-Next & SuSFS~~
- **Tanggal Ditemukan**: 2026-09-30
- **Tanggal Selesai**: 2026-09-30
- **Commit**: `bd79ba8`
- **Gejala**: Kompilasi kernel gagal me-link fungsi `is_ksu_domain`, `is_zygote`, `ksu_try_umount`.
- **Penyebab**: KernelSU-Next legacy tidak menyediakan glue API yang diekspektasi oleh patch SuSFS simonpunk.
- **Solusi**: Menyuntikkan compatibility glue code langsung ke `fs/susfs.c`.

---

### ~~3. [FIXED] MemAvailable Overflow / MGLRU Active Page Counter Leak~~
- **Tanggal Ditemukan**: 2026-10-01
- **Tanggal Selesai**: 2026-10-01
- **Commit**: `44941fa`, `7d8fb46` (PR #3, #2)
- **Gejala**: Sisa RAM terbaca puluhan GB (abnormal) di device 4GB RAM ("ram bug.jpg") dan memicu crash OOM.
- **Penyebab**: Makro `set_mask_bits` di `include/linux/bitops.h` mengembalikan `new__` bukan `old__`. Di `lru_gen_del_page`, generasi halaman selalu terhitung `-1`. Pada `lru_gen_update_size`, `old_gen == -1` dianggap sebagai page baru yang masuk, sehingga counter memori aktif bertambah terus saat ada page yang dihapus.
- **Solusi**: Perbaiki makro `set_mask_bits` agar mengembalikan `old__` dan menjaga akurasi perhitungan generasi page.

---

### ~~4. [FIXED] YouTube ReVanced / Morphe Crash (Unconditional Umount)~~
- **Tanggal Ditemukan**: 2026-10-01
- **Tanggal Selesai**: 2026-10-01
- **Commit**: `814b864` (PR #4)
- **Gejala**: YouTube ReVanced dan modul overlay mount langsung crash saat dibuka.
- **Penyebab**: `susfs_try_umount_all` mencopot `/data/adb/modules` dan `/product` untuk seluruh aplikasi tanpa filter.
- **Solusi**: Tambahkan pengecekan `ksu_uid_should_umount(new_uid)` sebelum unmount modul dieksekusi.

---

### ~~5. [FIXED] Status SuSFS "Unknown" di KernelSU Manager~~
- **Tanggal Ditemukan**: 2026-10-01
- **Tanggal Selesai**: 2026-10-01
- **Commit**: `e2bca06`, `15c5c69`
- **Gejala**: KernelSU Manager menampilkan versi SuSFS tidak diketahui meski kernel sudah dipatch.
- **Penyebab**: Manager memanggil `reboot(0xDEADBEEF, 0xFAFAFAFA, CMD_SUSFS_SHOW_*)` yang belum di-handle oleh kernel 4.19.
- **Solusi**: Implementasi handler `ksu_handle_susfs_sys_reboot` di `supercall.c` dan hook `kernel/reboot.c`.

---

### ~~6. [FIXED] Zygote Credential Timing Bypassing Module Umount~~
- **Tanggal Ditemukan**: 2026-10-02
- **Tanggal Selesai**: 2026-10-02
- **Commit**: `baea87f` (PR #5)
- **Gejala**: Aplikasi perbankan langsung force close karena mendeteksi mountpoint root/modul.
- **Penyebab**: Android 14/15/16 mengubah SELinux context ke `u:r:untrusted_app:s0` *sebelum* `setresuid`. Pemanggilan `is_zygote(current_cred())` selalu return `false`.
- **Solusi**: Buat helper `is_child_of_zygote()` yang memeriksa `current_cred()` dan `current->real_parent->cred`.

---

### ~~7. [FIXED] Filter SuSFS Tertidur (Dormant Flag `susfs_task_state`)~~
- **Tanggal Ditemukan**: 2026-10-02
- **Tanggal Selesai**: 2026-10-02
- **Commit**: `baea87f` (PR #5)
- **Gejala**: Fitur hide mount, hide path, dan spoof kstat SuSFS mati total untuk semua aplikasi.
- **Penyebab**: Bit `TASK_STRUCT_NON_ROOT_USER_APP_PROC` pada `current->susfs_task_state` tidak pernah diset di `setresuid_hook.c`.
- **Solusi**: Set bit tersebut pada `setresuid` untuk `is_appuid` dan `is_isolated_process`.

---

### ~~8. [FIXED] Modul BRENE Memicu Crash SIGSEGV di Android 16~~
- **Tanggal Ditemukan**: 2026-10-02
- **Tanggal Selesai**: 2026-10-02
- **Commit**: `2051ebb`
- **Gejala**: Bank app langsung crash saat modul BRENE aktif (13 fitur aktif).
- **Penyebab**: `CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y` memodifikasi `ovl_path_lowerdata` di `fs/overlayfs/inode.c`, memicu dereference pointer dan rekursi `ST_RDONLY & ST_RELATIME` di Android 16.
- **Solusi**: Nonaktifkan `CONFIG_KSU_SUSFS_SUS_OVERLAYFS` dan standarkan profil ke 9 fitur stabil.

---

### ~~9. [FIXED] Storage FUSE Unmount Loop~~
- **Tanggal Ditemukan**: 2026-10-02
- **Tanggal Selesai**: 2026-10-02
- **Commit**: `2051ebb`
- **Gejala**: File descriptor internal bank menjadi invalid (`EBADF`).
- **Penyebab**: `CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y` mendaftarkan bind mount storage BRENE ke unmount loop secara agresif.
- **Solusi**: Nonaktifkan `AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT` dan biarkan unmount dikontrol modul/KSU.

---

### ~~10. [FIXED] Fitur `sus_map` Hilang di Kernel 4.19~~
- **Tanggal Ditemukan**: 2026-10-02
- **Tanggal Selesai**: 2026-10-02
- **Commit**: `f6c14b6`
- **Gejala**: BRENE hanya mendeteksi 8/9 fitur. File library `.so` injeksi Zygisk/BRENE terbongkar di `/proc/self/maps`.
- **Penyebab**: Upstream simonpunk cabang `kernel-4.19` tidak pernah mengimplementasikan `sus_map` (hanya ada di GKI).
- **Solusi**: Backport penuh `CONFIG_KSU_SUSFS_SUS_MAP`, `CMD_SUSFS_ADD_SUS_MAP (0x60020)`, `AS_FLAGS_SUS_MAP (39)`, dan hook `fs/proc/task_mmu.c`.

---

### ~~11. [FIXED] Compiler Error: Implicit Declaration of `susfs_try_umount`~~
- **Tanggal Ditemukan**: 2026-10-02
- **Tanggal Selesai**: 2026-10-02
- **Commit**: `541a5f2`
- **Gejala**: CI build gagal dengan pesan `-Werror,-Wimplicit-function-declaration`.
- **Penyebab**: `susfs_try_umount(uid)` dipanggil tanpa proteksi `#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT`.
- **Solusi**: Bungkus pemanggilan dengan `#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT`.

---

### ~~12. [FIXED] Syscall `execveat` Terblokir Register `envp` (Kredensial `ksu_cred` Mati Total)~~
- **Tanggal Ditemukan**: 2026-10-03
- **Tanggal Selesai**: 2026-10-03
- **Commit**: `5216a45`
- **Gejala**: Aplikasi bank tetap force close meskipun modul dicopot total. Seluruh modul unmount lumpuh.
- **Penyebab**: Pada ARM64, libc bionic menerjemahkan `execve` ke `execveat`. Hook `syscall_table_hook.c` memeriksa `PARM4 == 0` (`regs[3]` / `envp`), yang di Android **tidak pernah 0**. Akibatnya `ksu_handle_execve_ksud` tidak pernah jalan seumur hidup device, `init second_stage` terlewat, `cache_sid()` mati, dan `ksu_cred` selalu `NULL` sehingga unmount dibatalkan (`if (!ksu_cred) return 0;`).
- **Solusi**: Panggil `ksu_handle_execve_ksud` pada `execveat` langsung tanpa blokir register `envp`.

---

### ~~13. [FIXED] Audit Log SELinux di Script Runtime Godmode Potato~~
- **Tanggal Ditemukan**: 2026-10-03
- **Tanggal Selesai**: 2026-10-03
- **Commit**: `5216a45`
- **Gejala**: `setprop` di `99-godmode-potato-fog.sh` memicu log audit `avc: denied` di dmesg yang terbaca scanner bank.
- **Solusi**: Gunakan `resetprop -n` jika tersedia untuk memodifikasi properti tanpa memicu audit SELinux.

---

### ~~14. [FIXED] SuSFS Error `[-] CMD: '0x55550', SUSFS operation not supported`~~
- **Tanggal Ditemukan**: 2026-10-03
- **Tanggal Selesai**: 2026-10-04
- **Commit**: `6dea4c2`
- **Gejala**: Perintah `ksu_susfs add_sus_path` dan tombol Apply pada aplikasi Brene gagal dengan respon error `0x55550 operation not supported`.
- **Penyebab**: Tool SuSFS v2.3.0 memanggil supercall `reboot()` dengan default `payload.err = 126`. Kernel belum memiliki dispatcher lengkap untuk perintah-perintah SuSFS v2.3.0 dan tidak menulis balik `err = 0` via `copy_to_user`.
- **Solusi**: Implementasikan full reboot dispatcher untuk ABI SuSFS v2.3.0 (`0x55550`, `0x55553`, `0x60020`, kstat, open_redirect, uname, log), tandai `INODE_STATE_SUS_PATH`, dan tulis balik `err = 0` ke userspace.

---

### ~~15. [FIXED] Duck Detector Leak `KernelSU prctl errno=14` (Direct Probe)~~
- **Tanggal Ditemukan**: 2026-10-03
- **Tanggal Selesai**: 2026-10-04
- **Commit**: `610f134`, `bd67635`
- **Gejala**: Duck Detector mendeteksi 1 direct probe pada pengecekan `KernelSU prctl` dengan pesan `errno=14 instead of EINVAL/ENOSYS`.
- **Penyebab**: Caller non-root mengirim invalid pointer dengan magic `0xDEADBEEF`, kernel KSU memicu `copy_to_user` fault (`EFAULT` 14) alih-alih ditolak normal (`EINVAL` 22).
- **Solusi**: Validasi pointer dan tambahkan privilege check (`is_manager()` atau `uid == 0`). Caller tidak berhak langsung dialihkan ke handler Linux bawaan (mengembalikan `EINVAL`).

---

### ~~16. [FIXED] Duck Detector Warning `Shell tmp: inode=102450` (Indirect Probe)~~
- **Tanggal Ditemukan**: 2026-10-03
- **Tanggal Selesai**: 2026-10-04
- **Commit**: `6dea4c2`
- **Gejala**: Duck Detector menampilkan peringatan kuning di `runtimeArtifacts` karena nomor inode `/data/local/tmp` melebihi ambang batas 10000.
- **Penyebab**: Seringnya proses create/delete file sementara di folder shell tmp menaikkan nomor inode sistem.
- **Solusi**: Intercept syscall `newfstatat` di `ksu_sth_newfstatat`, lalu timpa nilai `st->st_ino` menjadi `42` saat path adalah `/data/local/tmp`. Peringatan indirect probe di Duck hilang total.

---

### ~~17. [FIXED] Shamiko Installer Abort ("KernelSU version abnormal")~~
- **Tanggal Ditemukan**: 2026-10-03
- **Tanggal Selesai**: 2026-10-04
- **Commit**: `d298aed`
- **Gejala**: Modul Shamiko gagal diflash dengan pesan `KernelSU version abnormal! Integrate as submodule instead of copying`.
- **Penyebab**: Script `customize.sh` Shamiko menolak versi kernel `KSU_KERNEL_VER_CODE >= 20000` (KernelSU-Next secara bawaan menggunakan nomor versi 33xxx).
- **Solusi**: Tetapkan `KSU_VERSION_OVERRIDE=11998` dan fallback `11998` pada build sehingga terbaca di rentang resmi yang diterima Shamiko (`10940 <= ver < 20000`).

---

### ~~18. [FIXED] UAPI Version Mismatch ("Manager update required" & "Version too low")~~
- **Tanggal Ditemukan**: 2026-10-04
- **Tanggal Selesai**: 2026-10-05
- **Commit**: `1cc91c2`
- **Gejala**: ReSukiSU Manager memunculkan kartu peringatan merah `Manager update required`, dan KernelSU-Next Manager menampilkan `The current KernelSU-Next manager version is too low for KernelSU-Next to work properly`.
- **Penyebab**: KernelSU-Next legacy memiliki ketidaksesuaian antarmuka UAPI (v4 vs v5) dan pemalsuan versi 11998 memicu penolakan oleh ReSukiSU Manager v4.2.0-rc3.
- **Solusi**: Migrasi penuh dari KernelSU-Next ke upstream resmi ReSukiSU v4.2.0-rc3 dengan 8 manual inline kernel hooks (sys.c, reboot.c, exec.c, open.c, read_write.c, stat.c, input.c, selinuxfs.c), dan hapus override versi palsu agar kernel dan manager sinkron 1:1 (Full Featured hijau).

---

### ~~19. [FIXED] SuSFS Error `0x555b0` & ReSuSFS `file_size too long`~~
- **Tanggal Ditemukan**: 2026-10-04
- **Tanggal Selesai**: 2026-10-05
- **Commit**: `6d20037`, `01d29a2`
- **Gejala**: Perintah `susfs set_cmdline_or_bootconfig` gagal dengan respon error `0x555b0 unsupported`, dan script ReSuSFS gagal dengan pesan `file_size too long`.
- **Penyebab**: File `cmdline_or_bootconfig.txt` membengkak hingga 11 KB akibat penumpukan baris komentar `cat >>`, melampaui batas kernel 4096 byte. Selain itu, ReSukiSU `ksud` mengalokasikan buffer struct 8192 byte (`err` di offset 8192), sedangkan kernel lama hanya menulis `err = 0` di offset 4096.
- **Solusi**: Bersihkan file konfigurasi menjadi 1 baris ringkas (~1 KB) dan ubah script ke mode overwrite. Di kernel, tulis balik `err = 0` di kedua offset (+4096 dan +8192) sehingga kompatibel dengan semua versi userspace.

---

### ~~20. [FIXED] Linker Failure vmlinux: Undefined Reference to GKI SuSFS Symbols~~
- **Tanggal Ditemukan**: 2026-10-05
- **Tanggal Selesai**: 2026-10-05
- **Commit**: `dd97801`
- **Gejala**: Build kernel gagal pada tahap `MODPOST vmlinux.o` dengan pesan `undefined reference to susfs_is_current_proc_no_su`, `susfs_extra_works`, `susfs_set_current_proc_umounted`, dan `susfs_start_sdcard_monitor_fn`.
- **Penyebab**: ReSukiSU memanggil simbol-simbol SuSFS modern dari cabang GKI 5.10+, sedangkan patch kernel 4.19 simonpunk sudah tidak dipelihara dan tidak memiliki simbol tersebut.
- **Solusi**: Backport definisi thread flags (`TIF_PROC_UMOUNTED`, `TIF_PROC_NO_SU`, dll.) ke `include/linux/susfs_def.h`, serta deklarasikan workqueue `susfs_extra_works` dan fungsi stub di `fs/susfs.c`.

---

### ~~21. [FIXED] Redefinition Compiler Error `susfs_is_current_proc_umounted`~~
- **Tanggal Ditemukan**: 2026-10-05
- **Tanggal Selesai**: 2026-10-05
- **Commit**: `a9ee7e1`
- **Gejala**: Kompilasi kernel gagal pada `fs/notify/fdinfo.c` dengan error `redefinition of 'susfs_is_current_proc_umounted'`.
- **Penyebab**: Blok helper SuSFS di-append ke akhir `susfs_def.h` di luar include guard utama, menyebabkan deklarasi ganda saat file di-include berulang kali.
- **Solusi**: Bungkus seluruh blok ekstensi helper SuSFS dengan include guard `#ifndef _KSU_SUSFS_DEF_EXT_H ... #endif`.

---

## 2. Batasan Perangkat Keras (Hardware Limitations)

### 1. [LIMITATION] LTE Carrier Aggregation (4CA / B1+B3 Combo Lock)
- **Status**: Hardware & Baseband Limitation (Di luar jangkauan Kernel Linux).
- **Gejala**: Device hanya mengunci 1 band (1800 atau 2100 saja), tidak bisa agregasi B1+B3.
- **Penyebab**:
  1. Modem Snapdragon X11 pada SDM680 memiliki batas maksimal **2CA** (tidak mendukung 4CA).
  2. Xiaomi memangkas komponen RF Front-End (RFFE) pada Redmi 10C (tidak ada duplexer fisik untuk penerimaan frekuensi ganda B1+B3 simultan).
  3. Modulasi baseband dikontrol tertutup oleh firmware DSP Hexagon (`NON-HLOS.bin`), kernel Android hanya bertindak sebagai bridge data IP (`rmnet_data`).
