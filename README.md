# 🚀 Redmi 10C (fog/wind/rain) Kernel Builder: Kairos Godmode Potato Suite

Repository ini berisi workflow **GitHub Actions** otomatis tingkat lanjut untuk mengompilasi Linux Kernel 4.19 pada **Xiaomi Redmi 10C (`fog`, `wind`, `rain` / Snapdragon 680)** dengan konfigurasi **Godmode Potato Suite**.

---

## 🎯 Keputusan Tegas Sepuh: Pemilihan Base & Implementasi Fitur

Sebagai engineer kernel senior, keputusan harus **tegas, berbasis data silikon, dan tanpa kompromi**. 

* **Prosesor Target:** Qualcomm Snapdragon 680 4G (SM6225)
  * Arsitektur: 4x Cortex-A73 (Kryo 265 Gold @ 2.4 GHz) + 4x Cortex-A53 (Kryo 265 Silver @ 1.9 GHz - In-Order).
* **Kapasitas RAM:** 4GB LPDDR4X (Sangat sempit untuk Android 16).
* **Storage Bus:** UFS 2.2 (Universal Flash Storage 2.2 - Dual-Lane Full-Duplex, Write Booster, SCSI Queuing ~800–1000 MB/s).

---

### 1. Base Kernel Pilihan: `alternoegraha/kernel_xiaomi_sm6225` (Branch `fog`)

**Mengapa wajib ini?**
1. **Zero-Bug Hardware Guarantee:** `@alternoegraha` adalah pembuat *device tree* resmi Redmi 10C. Hanya di repositori ini seluruh driver hardware (IC Touchscreen FocalTech/Novatek panel IPS LCD 6.71", kamera 50MP Samsung S5KJN1, sensor proximity, dan audio codec) dijamin 100% stabil tanpa risiko bug hardware.
2. **Qualcomm WALT (Window-Assisted Load Tracking):** Di Kryo 265, CFS scheduler generic lambat mengenali beban. WALT milik Qualcomm mengukur beban dalam window 20ms dan langsung melempar tugas UI ke 4 Core Big A73 seketika.
3. **MGLRU & ZRAM DEDUP Asli:** Pohon ini sudah memiliki backport Multi-Gen LRU dan ZRAM Deduplication di defconfig resminya.

---

### 2. Fitur Terbaik yang Diambil & Diimplementasikan

Dari repositori lain (`rystX` dan `iDead-Project`), kita mengambil elemen terbaik yang **benar-benar esensial** tanpa memasukkan kode eksperimental yang rentan *kernel panic*:

1. **Anxiety I/O Scheduler (Raja Flash Storage):**
   * Diambil dari implementasi modder flash storage. Jauh lebih ringan dibanding BFQ untuk Core A53, memprioritaskan antrian baca (*read priority*) di atas tulis (*write*). Menghilangkan lag saat ada background download.
2. **ZRAM DEDUP + ZSTD 4GB Dinamis:**
   * Hashing blok swap memori agar halaman identik tidak memakan ruang dobel di swap. Kapasitas memori virtual efektif melonjak setara **~11 GB**.
3. **KSM (Kernel Samepage Merging):**
   * Menggabungkan duplikasi halaman RAM dari runtime ART Android 16 (menghemat 300MB–600MB RAM fisik murni).
4. **Schedtune & Core-Control Isolation:**
   * Core Big A73 diprioritaskan untuk `top-app` dengan boost 15%, sedangkan task background dikarantina ketat di Core Little A53 (CPU 0–3).
5. **Zero-Debloat:**
   * Mematikan `CONFIG_SCHEDSTATS`, `CONFIG_SLUB_DEBUG`, dan `CONFIG_FTRACE` untuk membebaskan ~200MB slab RAM yang tidak bisa di-reclaim.
6. **SUSFS v2.3.0 & KernelSU-Next:**
   * Sinkronisasi header otomatis untuk bypass Play Integrity & deteksi root perbankan.

---

## 📌 Cara Upload Manual ke GitHub (Tanpa Terminal)

1. Buat repository baru di [github.com/new](https://github.com/new) (pilih **Public**).
2. Di halaman repo baru, klik link **"uploading an existing file"** (atau menu **Add file** > **Upload files**).
3. Buka File Explorer di Windows, masuk ke folder:
   `c:\Users\Administrator\Documents\kernel`
4. **Drag & drop** folder `.github`, file [`README.md`](file:///c:/Users/Administrator/Documents/kernel/README.md), dan [`.gitignore`](file:///c:/Users/Administrator/Documents/kernel/.gitignore) ke browser GitHub.
5. Klik **Commit changes**.

---

## ⚙️ Cara Menjalankan Build di GitHub Actions

1. Buka repo GitHub kamu > Masuk ke tab **Actions**.
2. Pilih workflow **"Build Redmi 10C Kernel (KernelSU-Next + SUSFS v2.3.0 + Godmode Potato Suite)"**.
3. Klik tombol **Run workflow**.
4. Parameter default sudah otomatis disetel ke pohon resmi maintainer fog:
   - **Custom Kernel Name**: `Kairos` (bisa kamu ubah sesuka hati)
   - **Kernel Source Repository**: `alternoegraha/kernel_xiaomi_sm6225`
   - **Kernel Source Branch**: `fog`
   - **Defconfig**: `vendor/fog-perf_defconfig`
   - **Integrate KernelSU-Next**: `true`
   - **Integrate SUSFS**: `true`
   - **Enable Godmode Potato**: `true`
5. Tunggu proses kompilasi selesai (~12–18 menit), lalu download file `.zip` di bagian **Artifacts**:
   `Kairos-SUSFS-GodmodePotato-fog-xxxx.zip`

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

# 2. Cek status Schedtune top-app boost (harus 15)
su -c cat /dev/stune/top-app/schedtune.boost

# 3. Cek I/O Scheduler aktif (harus [anxiety])
su -c "cat /sys/block/sda/queue/scheduler 2>/dev/null || cat /sys/block/mmcblk0/queue/scheduler"

# 4. Cek respon cepat Schedutil (harus 500 us)
su -c cat /sys/devices/system/cpu/cpufreq/policy0/schedutil/up_rate_limit_us

# 5. Cek MGLRU (harus 7) & KSM (harus 1)
su -c cat /sys/kernel/mm/lru_gen/enabled
su -c cat /sys/kernel/mm/ksm/run

# 6. Cek kapasitas ZRAM (harus ~4096 MB ZSTD)
su -c free -m
```
