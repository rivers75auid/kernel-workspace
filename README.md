# 🚀 Redmi 10C (fog/wind/rain) Kernel Builder with KernelSU-Next & SUSFS

Repository ini berisi workflow **GitHub Actions** otomatis untuk mengompilasi Linux Kernel 4.19 untuk **Xiaomi Redmi 10C (`fog`, `wind`, `rain`)** dengan dukungan:
- **KernelSU-Next** (v3+ Driver)
- **SUSFS** (Kernel-level Root Hiding Patch untuk menyembunyikan deteksi root & mount)
- **Proton Clang 13** Toolchain
- **AnyKernel3** flashable zip (siap flash lewat TWRP / OrangeFox)

---

## 📌 Cara Setup & Push ke GitHub

Ikuti langkah-langkah berikut untuk mengunggah builder ini ke akun GitHub kamu:

### 1. Buat Repository Baru di GitHub
1. Buka [GitHub New Repository](https://github.com/new).
2. Beri nama repositori (contoh: `kernel-builder-fog`).
3. Pilih visibilitas **Public** (agar kuota GitHub Actions gratis tanpa batas menit).
4. Biarkan opsi "Initialize with README" tidak dicentang, lalu klik **Create repository**.

### 2. Push Folder Ini ke GitHub
Buka terminal / PowerShell di folder ini (`c:\Users\Administrator\Documents\kernel`), lalu jalankan:

```bash
git init -b main
git add .
git commit -m "feat: initial kernel builder workflow with KernelSU-Next and SUSFS"
git remote add origin https://github.com/<USERNAME-KAMU>/<NAMA-REPO-KAMU>.git
git push -u origin main
```
*(Ganti `<USERNAME-KAMU>` dan `<NAMA-REPO-KAMU>` sesuai akun GitHub kamu).*

---

## ⚙️ Cara Menjalankan Build di GitHub

1. Buka repository kamu di browser.
2. Masuk ke tab **Actions**.
3. Di bilah samping kiri, klik workflow **"Build Redmi 10C Kernel (KernelSU-Next + SUSFS)"**.
4. Klik tombol **Run workflow** di sebelah kanan.
5. Kamu dapat membiarkan parameter default atau menyesuaikannya:
   - **Kernel Source Repository**: `r0ddty/kernel_xiaomi_fog`
   - **Kernel Source Branch**: `andromeda-mk2` (atau `main`)
   - **Defconfig**: `vendor/fog-perf_defconfig`
   - **Integrate KernelSU-Next**: `true`
   - **Integrate SUSFS**: `true`
6. Klik tombol hijau **Run workflow**.

---

## 📦 Mengunduh Hasil Build

1. Tunggu proses build selesai di tab **Actions** (biasanya memakan waktu 10–18 menit).
2. Setelah selesai (bercentang hijau), klik run build tersebut.
3. Scroll ke bagian bawah pada bagian **Artifacts**.
4. Download file artifact berekstensi `.zip` (misal: `KernelSU-Next-SUSFS-fog-2026xxxx.zip`).

---

## 📲 Cara Flash & Konfigurasi di HP

### 1. Backup Partisi Boot
Sebelum melakukan flashing, masuk ke **TWRP / OrangeFox** dan lakukan backup partisi **Boot** & **DTBO** perangkat kamu untuk berjaga-jaga jika terjadi masalah.

### 2. Flash Kernel
1. Copy file AnyKernel3 `.zip` hasil build ke internal storage atau micro-SD HP kamu.
2. Masuk ke recovery (TWRP/OrangeFox).
3. Pilih menu **Install** > pilih file `.zip` kernel > geser untuk flash.
4. **Reboot System**.

### 3. Pasang Aplikasi KernelSU-Next & Modul SUSFS
1. Download dan instal APK [KernelSU-Next Manager](https://github.com/KernelSU-Next/KernelSU-Next/releases).
2. Buka aplikasi KernelSU-Next dan pastikan status menunjukkan **Working** (Kernel terpasang).
3. Download modul [susfs4ksu-module (oleh sidex15)](https://github.com/sidex15/susfs4ksu-module/releases).
4. Buka KernelSU-Next Manager > tab **Modules** > pasang file modul SUSFS `.zip` > restart HP.

---

## 🔍 Cara Verifikasi SUSFS Aktif

Buka aplikasi terminal di Android (misalnya **Termux**) dan ketik perintah:
```bash
su -c ksu_susfs -v
```
Jika kernel berhasil di-patch dengan benar, terminal akan menampilkan versi SUSFS yang aktif di kernel.
