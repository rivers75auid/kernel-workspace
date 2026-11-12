# Custom Scene9 Profile untuk Redmi 10C (`fog` / Snapdragon 680 `khaje`)

Hasil reverse-engineering statik `scene/scene_N1 2026.09 Alpha7.apk` via REA menunjukkan cara kerja menu **Download Cloud Config** di Scene9 beserta struktur profil kustom lokalnya.

## 1. Kenapa Redmi 10C (`fog`) Tidak Mendukung Config Cloud Resmi & Arti Mode `HP` / `LP` / `EP` / `FAS`

Berdasarkan dekompilasi `a.bn0`, `a.re1`, `a.tg1`, dan `res/*` pada Scene9 Alpha7:
1. **Endpoint Cloud Telemetry & Downloader:**
   - Server base dipilih di `a.tg1.i()`: `https://omarea.com` (`cn`), `http://scene7.omarea.com:8080` (`cn2`), `https://vtools.online` (`gb`).
   - Endpoint `/hardware-properties2` (`a.re1.o()`) membaca `platform`, `cpu0..N` frequencies/governor, dan `adreno-gpu`.
   - Endpoint `/cloud-scheduler-v2` mengembalikan profil resmi khusus SoC tertentu saja; perangkat entry/mid-range seperti `khaje` / `fog` sering tidak tersedia atau terfilter di sisi server & UI.
2. **Arti Pilihan Config di Dialog Cloud Scene9:**
   - **`HP`** (`CLOUD_PROFILE_BRANCH = "normal"` / default) — **High Performance / Balanced-Performance standard**.
   - **`LP`** (`CLOUD_PROFILE_BRANCH = "lp"`) — **Low Power**. Di UI Scene9 (`a.hm0.onClick` / `a.bn0.Z`), opsi `source_official_lp` disembunyikan otomatis jika Android `SDK_INT <= 30` atau `platform` bukan SoC flagship list (`mt6893`, `mt6895`, `mt6897`, `mt6983`, `mt6985`, `mt6989`, `lahaina`, `waipio`, `cape`, `ukee`, `kalama`, `pineapple`, `sun`, `canoe`).
   - **`EP`** (`CLOUD_PROFILE_BRANCH = "ep"`) — **Extreme Power / Efficiency-Performance** (menyembunyikan `cpus_limiter`, dan juga dibatasi pada SoC flagship di UI).
   - **`FAS`** (`source_fas_rs` / `fas-rs`) — **Frame-Aware Scheduling** (`features.fas: true`).
   - Selain itu Scene juga menautkan konfigurasi pihak ke-3 seperti **Uperf** dan **Uperf Game Turbo**.

## 2. Kontrak Konfigurasi Lokal (`/data/powercfg.sh` & `/data/powercfg.json`)

Dari method `a.tg1.p()` dan `a.lv.c()`:
- Jika `/data/powercfg.sh` ada dan readable/executable, Scene9 otomatis menggunakannya sebagai mode **Custom / Outside Schedule**.
- `/data/powercfg.json` dibaca untuk metadata & `features` (`strict`, `pedestal`, `reboot`, `fas`, `limiter`).
- Scene mengeksekusi `sh /data/powercfg.sh "<mode>"`:
  - `init` (saat daemon inisialisasi)
  - `powersave`
  - `balance`
  - `performance`
  - `fast`
  - `pedestal` (aktif bila `"pedestal": true`)

## 3. Penyesuaian Khusus Hardware `fog` / `khaje` + Kairos Engine v2.3

Konfigurasi di folder ini (`powercfg.json` + `powercfg.sh`) disusun langsung dari DTS & config kernel `cirno-pin`:
- **Cluster 0 (`policy0`, `cpu0-3`):** Kryo 265 Silver (`capacity-dmips-mhz = 1024`).
- **Cluster 1 (`policy4`, `cpu4-7`):** Kryo 265 Gold (`capacity-dmips-mhz = 1638`).
- **Scheduler Kernel:** `CONFIG_SCHED_WALT=y` + `CONFIG_SCHED_TUNE=y` (`uclamp` tidak aktif di kernel 4.19 `khaje`, sehingga memakai `/dev/stune/*` + `schedutil` WALT `up_rate_limit_us` / `down_rate_limit_us` / `hispeed_freq` / `hispeed_load` / `pl`).
- **GPU Adreno 610 (`kgsl-3d0`):** Frekuensi min/max **otomatis disnap** ke `available_frequencies` perangkat agar aman di semua speed-bin SM6225.
- **Anti-konflik Kairos Engine:** Skrip ini sengaja **tidak menyentuh** `vm.swappiness`, MGLRU, PSI, atau ZRAM, sehingga Kairos Engine v2.3 memegang kendali penuh manajemen RAM tanpa rebutan tunables dengan Scene.

## 4. Cara Pasang di HP

Jalankan lewat shell root (ADB / Termux `su`):

```sh
su
cp /sdcard/Download/powercfg.sh /data/powercfg.sh
cp /sdcard/Download/powercfg.json /data/powercfg.json
chmod 755 /data/powercfg.sh
chmod 644 /data/powercfg.json
```

Lalu buka **Scene9 -> Settings / Schedule -> Pilih External / `/data/powercfg.sh`**, dan verifikasi mode (`Powersave`, `Balance`, `Performance`, `Fast`, `Pedestal`) muncul tanpa pesan error.
