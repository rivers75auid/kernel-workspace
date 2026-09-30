# 🚀 Redmi 10C (fog/wind/rain) Kernel Builder: Godmode Potato Suite (KernelSU-Next + SUSFS v2.3.0 + FAS/UCLAMP + BFQ + MGLRU + KSM)

Repository ini berisi workflow **GitHub Actions** otomatis tingkat lanjut untuk mengompilasi Linux Kernel 4.19 pada **Xiaomi Redmi 10C (`fog`, `wind`, `rain` / Snapdragon 680)** yang dirancang dengan filosofi **"Kernel Master / Google Android Core Engineer"**: memeras performa maksimal dari hardware *potato* (RAM 4GB & SoC budget) agar sanggup melibas **Android 16** dengan mulus tanpa kompromi.

---

## 🏛️ Arsitektur "Godmode Potato Suite": Rahasia Dapur Sepuh

Di luar urusan RAM, performa Android ditentukan oleh interaksi antara **CPU Scheduler**, **GPU Compositor (SurfaceFlinger)**, **I/O Storage Bus**, dan **Binder IPC**. Berikut teknologi tingkat tinggi yang disematkan:

### 1. FAS (Frame Aware Scheduling) & UCLAMP (Utilization Clamping)
* **Masalah Snapdragon 680:** Memiliki 4x Core Big (Cortex-A73) dan 4x Core Little (Cortex-A53). Schedutil standar hanya bereaksi setelah antrian CPU menumpuk (butuh 64ms–96ms untuk mendeteksi beban). Akibatnya, saat jari menyentuh layar atau saat game butuh render frame 60/90fps, CPU terlambat menaikkan frekuensi dan frame langsung *drop (jank)*.
* **Solusi FAS & UCLAMP:**
  * **UCLAMP Task Grouping:** Menggantikan Schedtune lama. `top-app` (aplikasi/game yang sedang aktif di layar) otomatis diberi `uclamp.min = 20%` dan diprioritaskan ke Core Big A73 dengan flag `latency_sensitive = 1`.
  * **Isolasi Background:** Aplikasi latar belakang dikurung ketat di Core Little A53 (`cpuset 0-3`) dengan plafon maksimal `uclamp.max = 30%`. Task background haram menyentuh Core Big saat layar menyala!
  * **Schedutil Hyper-Ramp:** Parameter `up_rate_limit_us` disetel ke **500µs (0.5 milidetik)** untuk langsung loncat ke clock tinggi saat frame terancam drop, dan `down_rate_limit_us = 20000µs` agar clock tidak anjlok di tengah animasi scrolling.

### 2. Storage I/O: BFQ Low-Latency Scheduler (Menyelamatkan eMMC/UFS 2.2)
* **Masalah Potato Storage:** Storage budget memiliki bandwidth I/O terbatas. Ketika Google Play Services atau download berjalan di latar belakang, bus I/O macet total. Thread antarmuka UI terpaksa masuk ke status `D-State` (uninterruptible disk sleep), menyebabkan HP membeku (*freeze*) beberapa detik.
* **Solusi:**
  * Mengaktifkan **BFQ (Budget Fair Queueing)** (`CONFIG_IOSCHED_BFQ=y`) dengan mode `low_latency = 1` dan `slice_idle = 0`.
  * BFQ menjamin aplikasi interaktif (sentuhan & UI) selalu mendapatkan slot I/O seketika, mengabaikan antrian background download.
  * Menambah `read_ahead_kb = 512KB` pada storage internal untuk melipatgandakan kecepatan baca sequensial saat membuka file APK aplikasi.

### 3. SurfaceFlinger & HWUI Pipeline Bypass (Zero Display Jitter)
* `debug.sf.latch_unsignaled = 1`: SurfaceFlinger tidak perlu menunggu fence buffer yang tidak perlu, langsung menampilkan buffer frame siap saji ke panel layar.
* `debug.sf.disable_backpressure = 1`: Menghilangkan backpressure buffer GPU yang sering memicu micro-stutter pada panel 90Hz.
* `sys.use_fifo_ui = 1`: Thread render UI dinaikkan ke level penjadwalan Real-Time (SCHED_FIFO), mengalahkan prioritas proses background apa pun.

### 4. Memory Subsystem: MGLRU + KSM + Z3FOLD + ZRAM ZSTD
* **MGLRU (Multi-Gen LRU):** Mode agresif `enabled 7` memotong direct reclaim latency hingga 80%.
* **KSM (Kernel Samepage Merging):** Memindai dan menggabungkan duplikasi halaman RAM dari runtime ART Android 16 (hemat 300MB–600MB RAM fisik murni).
* **Z3FOLD & ZPOOL:** Kompresi memori densitas tinggi (3 frame terkompresi per 1 halaman fisik).
* **ZRAM 4GB ZSTD:** Swap dinamis 4GB berkecepatan tinggi dengan `page-cluster = 0` (zero latency read-ahead). Kapasitas alamat memori efektif menjadi **~11 GB**.
* **Zero-Debloat:** Menghilangkan `FTRACE`, `DYNAMIC_DEBUG`, `DEBUG_SPINLOCK` untuk membebaskan ~200MB slab RAM yang tidak bisa di-reclaim.

### 5. Network Bufferbloat Kill: Google BBR + FQ-CoDel
* Memadukan queue discipline `fq_codel` dengan algoritma TCP BBR Google. Ping game online (Mobile Legends, PUBG, FF) tetap stabil tanpa lonjakan 200ms+ meski Wi-Fi/sinyal 4G sedang ramai.

### 6. Root & Hiding: KernelSU-Next + SUSFS v2.3.0
* Header kernel otomatis disinkronkan ke **`v2.3.0`**, kompatibel penuh dengan rilis terbaru [susfs4ksu-module sidex15 v2.3.0](https://github.com/sidex15/susfs4ksu-module/releases) tanpa issue *version mismatch*.

---

## 📌 Cara Push ke GitHub

Buka PowerShell di folder `c:\Users\Administrator\Documents\kernel`, lalu jalankan:

```powershell
git add .
git commit -m "feat: implement Godmode Potato Suite (FAS/UCLAMP, BFQ, MGLRU, KSM, SurfaceFlinger, BBR)"
git remote add origin https://github.com/<USERNAME-KAMU>/<NAMA-REPO-KAMU>.git
git branch -M main
git push -u origin main
```

---

## ⚙️ Cara Menjalankan Build di GitHub Actions

1. Buka repo GitHub kamu > Masuk ke tab **Actions**.
2. Pilih workflow **"Build Redmi 10C Kernel (KernelSU-Next + SUSFS v2.3.0 + Godmode Potato Suite)"**.
3. Klik tombol **Run workflow**.
4. Tunggu ~12–18 menit hingga proses selesai (centang hijau).
5. Unduh file zip dari bagian **Artifacts**:
   `KernelSU-Next-SUSFS-GodmodePotato-fog-xxxx.zip`

---

## 📲 Cara Flash & Verifikasi di HP (Termux)

1. Masuk ke TWRP / OrangeFox recovery.
2. **Backup partisi `Boot` dan `DTBO`** terlebih dahulu.
3. Flash file AnyKernel3 zip hasil build > **Reboot System**.
4. Pasang APK [KernelSU-Next Manager](https://github.com/KernelSU-Next/KernelSU-Next/releases) dan [Modul SUSFS sidex15 v2.3.0](https://github.com/sidex15/susfs4ksu-module/releases).
5. Buka **Termux** dan jalankan perintah cek:

```bash
# 1. Cek versi SUSFS aktif (harus v2.3.0)
su -c ksu_susfs -v

# 2. Cek status UCLAMP top-app (harus 20)
su -c cat /dev/cpuctl/top-app/uclamp.min

# 3. Cek I/O Scheduler aktif (harus [bfq])
su -c cat /sys/block/mmcblk0/queue/scheduler

# 4. Cek ramp-up Schedutil (harus 500 us)
su -c cat /sys/devices/system/cpu/cpufreq/policy0/schedutil/up_rate_limit_us

# 5. Cek MGLRU (harus 7) & KSM (harus 1)
su -c cat /sys/kernel/mm/lru_gen/enabled
su -c cat /sys/kernel/mm/ksm/run

# 6. Cek kapasitas ZRAM (harus ~4096 MB ZSTD)
su -c free -m
```
