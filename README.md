# Android Kernel CI: Automated Custom Linux 4.19 Pipeline

An automated CI/CD pipeline built on **GitHub Actions** for compiling and packaging optimized custom Linux 4.19 kernels for Android devices.

---

## ⚡ Overview & Features

This pipeline provides a reproducible, hermetic build environment using LLVM Clang to produce flashable AnyKernel3 zip packages.

### 1. Performance Tuning Suite
- **CPU Scheduling (WALT & Schedtune Engine):** Tuned energy-aware scheduler prioritizing interactive tasks (`top-app`) with dynamic frequency scaling driven by `schedutil`.
- **Storage I/O Optimization:** Flash-optimized `anxiety` I/O scheduler prioritizing read operations over background write bursts, with `bfq` group scheduling fallback.
- **Network Latency & QoS:** `bbr` congestion control paired with `fq_codel` queuing disciplines to mitigate bufferbloat.
- **Hardware Charging Subsystem:** Integrated driver enhancements for fast charging negotiation (HVDCP QC 3.0 protocol support).

### 2. Modern Memory Management
- **Multi-Gen LRU (MGLRU):** Advanced generation-based page reclamation minimizing cold-page churn under memory pressure.
- **ZRAM Deduplication:** Content-addressable memory hashing to compress identical swap pages, utilizing `zstd` compression.
- **Kernel Samepage Merging (KSM):** Automatic deduplication of identical memory pages across userland runtime processes.
- **Debloated Tracing Overhead:** Stripped unnecessary debugging symbols (`CONFIG_SLUB_DEBUG=n`, minimized slab footprint) to maximize available physical RAM.

### 3. Root & Stealth Framework
- **KernelSU / ReSukiSU Integration:** Inline manual VFS hooks (`execveat`, `faccessat`, `stat`, `sys_read`, `sys_reboot`, `setresuid`) for minimal kernel footprint.
- **SuSFS Subsystem:** Supercall handlers and VFS isolation hooks to protect namespace integrity and prevent userspace mount enumeration.

---

## 🛠️ GitHub Actions Workflow Usage

Builds are triggered manually using the **workflow_dispatch** trigger in GitHub Actions.

1. Navigate to the **Actions** tab in the repository.
2. Select **Android Kernel Build Engine**.
3. Click **Run workflow** and configure the input parameters if needed:
   - **KERNEL_NAME**: Suffix identifier displayed in kernel version strings (default: `Kairos`).
   - **KERNEL_REPO**: Target kernel source tree repository path.
   - **KERNEL_BRANCH**: Target git branch.
   - **DEFCONFIG**: Target defconfig file relative to `arch/arm64/configs/`.
   - **ENABLE_RESUKISU**: Toggle root subsystem hooks (`true` / `false`).
   - **ENABLE_POTATO_SUITE**: Toggle performance tuning and memory enhancements (`true` / `false`).
4. Once compilation completes, download the flashable AnyKernel3 archive from the **Artifacts** section.

---

## 📦 Installation & Verification

1. Boot into a custom recovery environment (TWRP / OrangeFox).
2. Create a backup of existing `boot` and `dtbo` partitions.
3. Flash the compiled AnyKernel3 zip package.
4. Reboot the system and verify the kernel status via adb shell:

```bash
# Verify active kernel version and governor
uname -a
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# Verify Multi-Gen LRU status
cat /sys/kernel/mm/lru_gen/enabled

# Verify active I/O scheduler
cat /sys/block/sda/queue/scheduler
```

---

## 📄 License

The kernel source tree and related components are distributed under the terms of the GNU General Public License (GPL) version 2.
