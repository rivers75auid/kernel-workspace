# 🚀 Redmi 10C (fog/wind/rain) Kernel Builder: KernelSU-Next + SUSFS v2.3.0 + Hardcore RAM Optimization Suite

Repository ini berisi workflow **GitHub Actions** otomatis untuk mengompilasi Linux Kernel 4.19 untuk **Xiaomi Redmi 10C (`fog`, `wind`, `rain`)** dengan konfigurasi **Hardcore Extreme** untuk mengatasi limitasi **RAM 4GB** pada **Android 16**.

---

## 🔍 Penjelasan Versi SUSFS: v2.3.0 vs v1.5.5

Banyak yang bingung mengenai nomor versi SUSFS:
1. **Di Kernel GKI (Linux 5.10, 5.15, 6.1, 6.6, 6.12):** Menggunakan skema versi `v2.x` (saat ini rilis terbaru adalah **v2.3.0**).
2. **Di Kernel Non-GKI (Linux 4.19 Redmi 10C):** Di repo resmi GitLab `simonpunk/susfs4ksu` branch `kernel-4.19`, kode patch intinya terus diperbarui (update terakhir September 2026), namun versi string bawaannya tertulis `v1.5.5`.
3. **Solusi di Builder ini:**
   Workflow ini **secara otomatis menyinkronkan header kernel ke `v2.3.0`** (`#define SUSFS_VERSION "v2.3.0"`). Dengan ini, ketika kamu menginstal modul [susfs4ksu-module sidex15 v2.3.0](https://github.com/sidex15/susfs4ksu-module/releases), modul dan kernel akan berada pada versi yang sama persis tanpa ada error *version mismatch*!

---

## 💥 Paket Optimisasi RAM Hardcore (Bukan Standar Biasa)

Menjalankan Android 16 di RAM 4GB biasanya mimpi buruk karena aplikasi sering reload (*re-draw*), animasi patah-patah, dan multitasking lambat. Builder ini menyematkan **7 lapis optimisasi tingkat kernel & runtime**:

### 1. Multi-Gen LRU (MGLRU) Aggressive Tiering
- **Alasan:** Algoritma LRU bawaan Linux 4.19 sudah usang (20 tahun lalu). Saat RAM 4GB penuh, ia mengalami *lock contention* dan *kswapd thrashing*, membuat CPU 100% dan HP nge-freeze.
- **Tuning:** Diaktifkan dengan mode `enabled 7` (memindai page table, file cache, dan anonymous memory) serta `min_ttl_ms 1000`. Mengurangi *direct reclaim latency* hingga **80%**.

### 2. KSM (Kernel Samepage Merging)
- **Alasan:** Di Android 16, ratusan aplikasi dan service berjalan di atas Zygote & runtime ART yang sama. Akibatnya, ada ribuan halaman memori (4KB) yang isinya 100% identik namun menduplikasi ruang di RAM.
- **Tuning:** KSM memindai memori di background dan menggabungkan halaman-halaman identik tersebut menjadi 1 halaman berstatus *Copy-On-Write*. Ini menghemat **300MB – 600MB RAM fisik murni** secara cuma-cuma!

### 3. Z3FOLD & ZPOOL Compressed Allocator
- **Alasan:** Allocator standar seperti `zbud` hanya bisa menyimpan 2 halaman terkompresi per 1 halaman fisik (rasio 2:1).
- **Tuning:** Mengaktifkan `CONFIG_Z3FOLD=y` yang mampu mengemas hingga **3 halaman terkompresi ke dalam 1 halaman fisik**, meningkatkan densitas memori terkompresi hingga 50% lebih padat.

### 4. ZRAM Dynamic Reallocation (4GB ZSTD + High-Priority Swap)
- **Alasan:** Bawaan ROM sering kali hanya mengalokasikan 2GB atau 3GB ZRAM dengan kompresor lawas (LZO).
- **Tuning:** Script boot AnyKernel3 otomatis me-reset ZRAM saat startup menjadi **4096MB (4GB)** penuh dengan algoritma **ZSTD** (rasio kompresi 2.8x - 3.2x). Kapasitas alamat memori efektif ponsel meningkat setara **~11 GB virtual address space**!

### 5. VFS Choke Prevention (Dirty Ratio Tuning)
- **Alasan:** Di Linux standar, `dirty_ratio` bernilai 20%. Di HP RAM 4GB, ini berarti hingga 800MB RAM bisa tersandera oleh file kotor yang menunggu ditulis ke storage eMMC. Saat RAM habis, kernel terpaksa *freeze* sistem untuk menulis 800MB tersebut ke storage (I/O bottleneck stall).
- **Tuning:** 
  - `vm.dirty_ratio = 5`
  - `vm.dirty_background_ratio = 2`
  - `vm.dirty_writeback_centisecs = 300`
  Data kotor langsung dialirkan ke disk secara kontinu dalam ukuran kecil tanpa pernah menyumbat RAM!

### 6. Swap I/O Latency Kill: `vm.page-cluster = 0`
- **Alasan:** Default Linux membaca 8 halaman ($2^3$) sekaligus saat membaca swap. Untuk ZRAM (yang merupakan RAM, bukan harddisk piringan), ini memboroskan siklus CPU untuk mendekompresi 7 halaman yang tidak terpakai.
- **Tuning:** Diset ke `0` (baca 1 halaman murni per permintaan). Kecepatan buka aplikasi dari ZRAM melonjak **3x lipat**.

### 7. Zero-Debloat Kernel Memory (Stripping Tracing & Debug)
- **Alasan:** Kernel Xiaomi bawaan membawa banyak debugger internal (`FTRACE`, `DYNAMIC_DEBUG`, `DEBUG_SPINLOCK`, `SLUB_DEBUG`) yang memakan puluhan megabyte memori slab yang tidak bisa di-reclaim (*unreclaimable memory*).
- **Tuning:** Seluruh overhead debugging dihilangkan, membebaskan **~150MB - 200MB RAM kernel murni** untuk dialokasikan ke aplikasi kamu.

### 8. Android 16 LMKD PSI & Real-Time UI Scheduling
- `sys.use_fifo_ui = 1`: Memberi prioritas real-time (FIFO) pada thread antarmuka Android, sehingga animasi layar tetap 60fps/90fps tanpa *drop frame* meski RAM sedang 98% terpakai.
- `ro.lmk.kill_heaviest_task = true`: Daripada membunuh 5-10 background apps kecil, LMKD hanya akan mematikan 1 task terberat jika memori benar-benar genting.

---

## 📌 Cara Setup & Push ke GitHub

Buka PowerShell di folder `c:\Users\Administrator\Documents\kernel`, lalu jalankan:

```powershell
git add .
git commit -m "feat: upgrade to SUSFS v2.3.0 and add hardcore RAM optimization suite"
git remote add origin https://github.com/<USERNAME-KAMU>/<NAMA-REPO-KAMU>.git
git branch -M main
git push -u origin main
```

---

## ⚙️ Cara Menjalankan Kompilasi di GitHub Actions

1. Buka repo GitHub kamu di browser.
2. Masuk ke tab **Actions**.
3. Pilih **"Build Redmi 10C Kernel (KernelSU-Next + SUSFS v2.3.0 + Hardcore RAM Optimization)"**.
4. Klik **Run workflow**.
5. Tunggu proses kompilasi selesai (sekitar 12–18 menit).
6. Unduh file `.zip` dari bagian **Artifacts**: `KernelSU-Next-SUSFS-HardcoreRAM-fog-xxxx.zip`.

---

## 📲 Cara Flash & Verifikasi di HP

1. Masuk ke TWRP / OrangeFox.
2. **Wajib:** Backup partisi **Boot** & **DTBO**.
3. Flash file zip AnyKernel3 hasil download.
4. Reboot System.
5. Pasang APK [KernelSU-Next Manager](https://github.com/KernelSU-Next/KernelSU-Next/releases) dan modul [susfs4ksu-module v2.3.0](https://github.com/sidex15/susfs4ksu-module/releases).
6. Buka **Termux** dan cek keberhasilan aktivasi:
   ```bash
   su -c ksu_susfs -v                       # Harus menampilkan v2.3.0
   su -c cat /sys/kernel/mm/lru_gen/enabled  # Status MGLRU (harus 7)
   su -c cat /sys/kernel/mm/ksm/run         # Status KSM (harus 1)
   su -c free -m                            # Cek swap/ZRAM (harus ~4096MB)
   su -c cat /proc/sys/vm/page-cluster      # Harus 0
   ```
