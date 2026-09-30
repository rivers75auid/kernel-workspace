# 🚀 Redmi 10C (fog/wind/rain) Kernel Builder: KernelSU-Next + SUSFS + RAM & MGLRU Optimization

Repository ini berisi workflow **GitHub Actions** otomatis untuk mengompilasi Linux Kernel 4.19 untuk **Xiaomi Redmi 10C (`fog`, `wind`, `rain`)** yang dioptimalkan secara khusus untuk **RAM 4GB** pada **Android 16 (AOSP)**.

---

## ⚡ Fitur Utama & Alasan Penambahan

### 1. Multi-Gen LRU (MGLRU)
- **Kenapa Ditambahkan?**
  Android 16 memakan banyak RAM untuk sistem dan aplikasi modern. Algoritma manajemen memori standar Linux 4.19 (Active/Inactive LRU) sudah berusia 20 tahun dan rentan mengalami *kswapd thrashing* & *lock contention* saat RAM hampir penuh, memicu lag parah dan pembunuhan aplikasi secara brutal oleh LMK.
- **Dampak:**
  MGLRU membagi halaman memori menjadi beberapa generasi berdasarkan frekuensi akses. Mengurangi *direct reclaim latency* hingga ~80%, menghemat CPU, dan mencegah aplikasi keluar sendiri saat multitasking di RAM 4GB.

### 2. ZRAM ZSTD (Menggantikan LZO/LZO-RLE)
- **Kenapa Ditambahkan?**
  Kompresi bawaan ZRAM (LZO) hanya memiliki rasio ~1.8x. Dengan **ZSTD**, rasio kompresi melonjak menjadi **2.7x - 3.2x**.
- **Dampak:**
  Pada HP RAM 4GB, ZRAM berukuran 3GB–4GB dengan ZSTD secara efektif memberi ruang setara **~7 GB sampai 8 GB memori virtual**, menampung aplikasi latar belakang jauh lebih banyak tanpa membuat sistem kehabisan memori (*OOM*).

### 3. Tweak Kernel I/O: `vm.page-cluster = 0`
- **Kenapa Ditambahkan?**
  Default Linux membaca 8 halaman sekaligus ($2^3$) setiap kali swap diakses. Untuk ZRAM (yang berada di RAM, bukan disk mekanis), ini membuang siklus CPU untuk mendekompresi data yang tidak diperlukan.
- **Dampak:**
  Dengan `page-cluster = 0` (membaca 1 halaman per kebutuhan), kecepatan baca ZRAM meningkat hingga **3x lipat**, menghilangkan jeda/stutter saat membuka aplikasi yang sedang di-*swap*.

### 4. Swappiness & Watermark Boost Factor
- `vm.swappiness = 160`: Mendorong kernel menyimpan memori pasif ke ZRAM terkompresi dan mempertahankan *file-backed cache* di RAM agar sistem tetap responsif.
- `vm.watermark_boost_factor = 0`: Menghilangkan lonjakan alokasi palsu yang sering menyebabkan frame drop pada animasi antarmuka dan game.

### 5. Google TCP BBR Congestion Control
- **Kenapa Ditambahkan?**
  Menggantikan algoritma TCP Cubic lama. BBR memonitor bandwidth aktual dan RTT, memberikan latency lebih rendah dan ping yang jauh lebih stabil pada jaringan 4G/LTE dan Wi-Fi.

### 6. KernelSU-Next (Latest) & SUSFS v1.5.5+ (Latest)
- **Kenapa Ditambahkan?**
  Deteksi root (Play Integrity, aplikasi perbankan BCA/Mandiri/BRI, dll.) selalu diperbarui. SUSFS v1.5.5+ menyediakan penyembunyian mount, path, kstat, symlink, dan spoofing cmdline yang tidak terdeteksi oleh sistem keamanan modern, dipadukan dengan KernelSU-Next yang aktif mendukung Linux 4.19 Non-GKI.

---

## 📌 Cara Setup & Push ke GitHub

### 1. Buat Repository Baru di GitHub
1. Buka [GitHub New Repository](https://github.com/new).
2. Beri nama repositori (contoh: `kernel-builder-fog`).
3. Pilih **Public** (agar runner GitHub Actions gratis).
4. Biarkan opsi "Initialize with README" tidak dicentang, lalu klik **Create repository**.

### 2. Push Folder Ini ke GitHub
Buka terminal / PowerShell di folder ini (`c:\Users\Administrator\Documents\kernel`), lalu jalankan:

```bash
git add .
git commit -m "feat: add MGLRU, ZRAM ZSTD, TCP BBR, and RAM tuning for Android 16"
git remote add origin https://github.com/<USERNAME-KAMU>/<NAMA-REPO-KAMU>.git
git push -u origin main
```
*(Ganti `<USERNAME-KAMU>` dan `<NAMA-REPO-KAMU>` sesuai akun GitHub kamu).*

---

## ⚙️ Cara Menjalankan Build di GitHub

1. Buka repository kamu di browser.
2. Masuk ke tab **Actions**.
3. Di panel sebelah kiri, pilih **"Build Redmi 10C Kernel (KernelSU-Next + SUSFS + RAM Optimization)"**.
4. Klik tombol **Run workflow** di sebelah kanan.
5. Parameter default sudah disesuaikan secara otomatis:
   - **Kernel Source Repository**: `r0ddty/kernel_xiaomi_fog`
   - **Kernel Source Branch**: `andromeda-mk2`
   - **Defconfig**: `vendor/fog-perf_defconfig`
   - **Integrate KernelSU-Next**: `true`
   - **Integrate SUSFS**: `true`
   - **Enable MGLRU, ZSTD ZRAM & Low-RAM Optimizations**: `true`
6. Klik **Run workflow** (proses kompilasi memakan waktu sekitar 12–18 menit).

---

## 📦 Mengunduh & Memasang Hasil Build

1. Setelah build selesai (ikon centang hijau), buka log run tersebut.
2. Download file di bagian **Artifacts**: `KernelSU-Next-SUSFS-MGLRU-fog-xxxx.zip`.
3. Masuk ke custom recovery (**TWRP** atau **OrangeFox**).
4. **Wajib:** Backup partisi **Boot** & **DTBO** kamu terlebih dahulu.
5. Flash file zip AnyKernel3 tersebut.
6. Reboot System.
7. Pasang APK [KernelSU-Next Manager](https://github.com/KernelSU-Next/KernelSU-Next/releases) dan modul [susfs4ksu-module (sidex15)](https://github.com/sidex15/susfs4ksu-module/releases).

---

## 🔍 Cara Verifikasi di HP (Termux)

Jalankan perintah berikut di Termux dengan akses root:

```bash
# 1. Cek versi SUSFS aktif
su -c ksu_susfs -v

# 2. Cek status MGLRU
su -c cat /sys/kernel/mm/lru_gen/enabled

# 3. Cek algoritma ZRAM aktif (harus menunjukkan [zstd])
su -c cat /sys/block/zram0/comp_algorithm

# 4. Cek page-cluster (harus bernilai 0)
su -c cat /proc/sys/vm/page-cluster
```
