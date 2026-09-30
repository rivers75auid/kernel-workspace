# 🚀 Redmi 10C (fog/wind/rain) Kernel Builder: Kairos Godmode Potato Suite

Repository ini berisi workflow **GitHub Actions** otomatis tingkat lanjut untuk mengompilasi Linux Kernel 4.19 pada **Xiaomi Redmi 10C (`fog`, `wind`, `rain` / Snapdragon 680)** dengan konfigurasi **Godmode Potato Suite**.

---

## 🔍 Hasil Survey Repositori Kernel Redmi 10C (fog/sm6225)

Berikut perbandingan mendalam seluruh kandidat repositori kernel untuk Redmi 10C yang ada di komunitas:

| Repositori | Versi Linux | Status Terkini | Kelebihan & Fitur Utama | Catatan / Kompatibilitas |
| :--- | :--- | :--- | :--- | :--- |
| **`iDead-Project/ai-kernel_xiaomi_sm6225`** *(Default Rekomendasi)* | **4.19.333** | Paling Baru (2026) | - **ZRAM DEDUP** bawaan kernel.<br>- I/O scheduler **Anxiety** & **BFQ**.<br>- Branch `aistrix-ext` & `ai-ebpf-a16` (support modern BPF Android 16).<br>- `fog-perf_defconfig` & `fog-ksu-perf_defconfig` resmi. | **Sangat Direkomendasikan.** Dibangun khusus untuk `fog/rain/wind` dengan optimisasi paling modern. |
| **`r0ddty/kernel_xiaomi_fog`** | **4.19.328** | Stabil (April 2026) | - Fork bersih dari `alternoegraha`.<br>- MGLRU backport bawaan.<br>- Stabil untuk ROM berbasis AOSP. | Pilihan kedua yang sangat bagus dan stabil. |
| **`Evolution-X-Devices/kernel_xiaomi_sm6225`** | **4.19.33x** | Aktif (Sept 2026) | - Android 16 ready.<br>- Dioptimalkan untuk spes/spesn. | **Hati-hati:** Ditargetkan untuk **Redmi Note 11 (`spes`)** yang memakai layar AMOLED & chip sentuh berbeda. Flashing langsung ke `fog` (IPS LCD) berisiko layar sentuh / kamera mati. |
| **`alternoegraha/wwy_kernel_xiaomi_fog_rebase`** | **4.19.157** | Diarsipkan | - Pohon dasar (*upstream*) pertama fog. | Sudah diarsipkan dan digantikan oleh rebase modern (`r0ddty` & `iDead-Project`). |

> [!TIP]
> Workflow ini secara default menggunakan **`iDead-Project/ai-kernel_xiaomi_sm6225`** (branch `aistrix-ext`), namun kamu tetap bisa menggantinya ke `r0ddty/kernel_xiaomi_fog` atau repositori lain secara instan lewat input box saat menekan tombol **Run workflow** di GitHub!

---

## 🏛️ Arsitektur "Godmode Potato Suite"

1. **FAS (Frame Aware Scheduling) & UCLAMP:** `uclamp.min = 20%` pada `top-app` untuk mengunci frame rate mulus 60/90fps, background task dikarantina di Core Little (CPU 0–3) dengan `uclamp.max = 30%`.
2. **Schedutil Hyper-Ramp:** `up_rate_limit_us = 500µs` (lompat frekuensi instan 0.5ms) dan `down_rate_limit_us = 20000µs`.
3. **Storage I/O (Anxiety / BFQ Low-Latency):** Mencegah *D-State Freeze* saat ada download background di storage eMMC/UFS 2.2, plus `read_ahead_kb = 512KB`.
4. **Memory Hardcore (MGLRU + KSM + ZRAM DEDUP + Z3FOLD + ZSTD):** Menggabungkan page identik ART Android 16, deduplikasi kompresi swap, membebaskan ruang memori setara **~11 GB**.
5. **SurfaceFlinger Real-Time UI (SCHED_FIFO):** `sys.use_fifo_ui = 1` dan `debug.sf.latch_unsignaled = 1` untuk menghilangkan jeda render.
6. **Network Google BBR + FQ-CoDel:** Mengatasi *bufferbloat* dan ping loncat di game online.
7. **Root & Hiding:** KernelSU-Next terbaru + SUSFS **v2.3.0** tersinkronisasi penuh.

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
4. Parameter default sudah otomatis diset ke pilihan terbaik:
   - **Custom Kernel Name**: `Kairos` (bisa kamu ubah sesuka hati)
   - **Kernel Source Repository**: `iDead-Project/ai-kernel_xiaomi_sm6225`
   - **Kernel Source Branch**: `aistrix-ext`
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

# 2. Cek status UCLAMP top-app (harus 20)
su -c cat /dev/cpuctl/top-app/uclamp.min

# 3. Cek I/O Scheduler aktif (harus [anxiety] atau [bfq])
su -c cat /sys/block/mmcblk0/queue/scheduler

# 4. Cek respon cepat Schedutil (harus 500 us)
su -c cat /sys/devices/system/cpu/cpufreq/policy0/schedutil/up_rate_limit_us

# 5. Cek MGLRU (harus 7) & KSM (harus 1)
su -c cat /sys/kernel/mm/lru_gen/enabled
su -c cat /sys/kernel/mm/ksm/run

# 6. Cek kapasitas ZRAM (harus ~4096 MB dengan kompresor [zstd])
su -c free -m
```
