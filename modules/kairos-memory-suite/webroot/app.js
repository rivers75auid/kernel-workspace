// Kairos Engine WebUI Client Controller
// Per-item config apply + Scene-adapted Swapfile, Power Profile, Freezer/USAP & Animation controls.

const CONFIG_PATH = "/data/adb/kairos_config.json";
const ZRAM_HELPER =
  "[ -x /data/adb/modules_update/kairos_memory_suite/kairos_zram.sh ] " +
  "&& echo /data/adb/modules_update/kairos_memory_suite/kairos_zram.sh " +
  "|| echo /data/adb/modules/kairos_memory_suite/kairos_zram.sh";
const POWER_HELPER =
  "[ -x /data/adb/modules_update/kairos_memory_suite/kairos_power.sh ] " +
  "&& echo /data/adb/modules_update/kairos_memory_suite/kairos_power.sh " +
  "|| echo /data/adb/modules/kairos_memory_suite/kairos_power.sh";

function hasBridge() {
  return !!(window.ksu && window.ksu.exec);
}

function exec(cmd, timeoutMs = 15000) {
  return new Promise((resolve) => {
    if (!hasBridge()) {
      resolve({ errno: -1, stdout: "", stderr: "No KernelSU bridge detected" });
      return;
    }
    const cb = "cb_" + Math.random().toString(36).slice(2);
    const timer = setTimeout(() => {
      window[cb] = () => delete window[cb];
      resolve({ errno: -2, stdout: "", stderr: "Command timed out" });
    }, timeoutMs);
    window[cb] = (errno, stdout, stderr) => {
      clearTimeout(timer);
      delete window[cb];
      resolve({ errno, stdout: stdout || "", stderr: stderr || "" });
    };
    try {
      window.ksu.exec(cmd, "{}", cb);
    } catch (err) {
      clearTimeout(timer);
      delete window[cb];
      resolve({ errno: -1, stdout: "", stderr: String(err) });
    }
  });
}

async function execHelper(subcmd, timeoutMs = 20000) {
  return exec(`HELPER=$(${ZRAM_HELPER}); sh "$HELPER" ${subcmd}`, timeoutMs);
}

const appState = {
  config: {
    bypass_charging: false,
    auto_bypass_games: [],
    heavy_swap_apps: [],
    swappiness: 100,
    comp_algorithm: "zstd",
    zram_size: "4096M",
    zram_writeback: false,
    wb_size_mb: 1024,
    swapfile_mb: 0,
    swapfile_prio: -1,
    power_profile: "balance",
    use_freezer: true,
    usap_pool: false,
    watermark_scale: 15,
    vfs_cache_pressure: 100,
    compaction_proactiveness: 20,
    bg_limit: 48,
    thermal_guard: false,
    thermal_limit_c: 52,
    charge_limit: 100
  },
  wbSupported: false,
  filterActiveOnly: false,
  animScale: "1.0",
  display: {
    physWidth: 720,
    physHeight: 1650,
    physDpi: 268,
    currWidth: 720,
    currHeight: 1650,
    currDpi: 268,
    selectedScale: 1.0
  },
  installedPackages: []
};

const el = {
  tabBtns: document.querySelectorAll(".nav-btn"),
  tabPanes: document.querySelectorAll(".tab-pane"),
  badgeKernelMode: document.getElementById("badge-kernel-mode"),
  headerTemp: document.getElementById("header-temp"),
  headerCharge: document.getElementById("header-charge"),
  headerBatt: document.getElementById("header-batt"),
  footerLog: document.getElementById("footer-log"),

  memAvail: document.getElementById("val-mem-avail"),
  memFreeInline: document.getElementById("val-mem-free-inline"),
  psiMem: document.getElementById("val-psi-mem"),
  zramTotal: document.getElementById("val-zram-total"),
  zramUsed: document.getElementById("val-zram-used"),
  zramPhys: document.getElementById("val-zram-phys"),
  zramRatioAlgo: document.getElementById("val-zram-ratio-algo"),
  rowWbStat: document.getElementById("row-wb-stat"),
  valWbStat: document.getElementById("val-wb-stat"),
  rowSwapfileStat: document.getElementById("row-swapfile-stat"),
  valSwapfileStat: document.getElementById("val-swapfile-stat"),
  swapPct: document.getElementById("val-swap-pct"),
  barSwap: document.getElementById("bar-swap"),
  barSwapTrack: document.getElementById("bar-swap-track"),
  btnRefresh: document.getElementById("btn-refresh"),
  btnCompact: document.getElementById("btn-compact"),
  btnReclaim: document.getElementById("btn-reclaim"),
  btnTrim: document.getElementById("btn-trim"),

  pwrStatusChip: document.getElementById("val-pwr-status-chip"),
  pwrPortVolt: document.getElementById("val-pwr-port-volt"),
  pwrCurrent: document.getElementById("val-pwr-current"),
  chkBypassMaster: document.getElementById("chk-bypass-master"),
  sumPowerPolicy: document.getElementById("sum-power-policy"),

  chkThermalGuard: document.getElementById("chk-thermal-guard"),
  groupThermalLimit: document.getElementById("group-thermal-limit"),
  groupThermalLimitWrap: document.getElementById("group-thermal-limit-wrap"),
  groupChargeLimit: document.getElementById("group-charge-limit"),
  btnSavePower: document.getElementById("btn-save-power"),

  appSearch: document.getElementById("app-search"),
  btnFilterActive: document.getElementById("btn-filter-active"),
  appCounts: document.getElementById("val-app-counts"),
  appListContainer: document.getElementById("app-list-container"),
  btnSaveApps: document.getElementById("btn-save-apps"),

  sumZram: document.getElementById("sum-zram"),
  sumSwapfile: document.getElementById("sum-swapfile"),
  sumCache: document.getElementById("sum-cache"),
  sumVm: document.getElementById("sum-vm"),
  sumProfile: document.getElementById("sum-profile"),
  sumRuntime: document.getElementById("sum-runtime"),
  sumDisplay: document.getElementById("sum-display"),

  groupCompAlgo: document.getElementById("group-comp-algo"),
  groupZramSize: document.getElementById("group-zram-size"),
  chkZramWb: document.getElementById("chk-zram-wb"),
  groupWbSizeWrap: document.getElementById("group-wb-size-wrap"),
  groupWbSize: document.getElementById("group-wb-size"),
  btnSaveZramReboot: document.getElementById("btn-save-zram-reboot"),
  btnApplyZramLive: document.getElementById("btn-apply-zram-live"),

  groupSwapfileSize: document.getElementById("group-swapfile-size"),
  groupSwapfilePrioWrap: document.getElementById("group-swapfile-prio-wrap"),
  groupSwapfilePrio: document.getElementById("group-swapfile-prio"),
  btnApplySwapfile: document.getElementById("btn-apply-swapfile"),

  groupBgLimit: document.getElementById("group-bg-limit"),
  btnApplyCache: document.getElementById("btn-apply-cache"),

  groupSwappiness: document.getElementById("group-swappiness"),
  groupWmScale: document.getElementById("group-wm-scale"),
  groupVfsPressure: document.getElementById("group-vfs-pressure"),
  groupCompProact: document.getElementById("group-comp-proact"),
  btnApplyVm: document.getElementById("btn-apply-vm"),

  groupPowerProfile: document.getElementById("group-power-profile"),
  btnApplyProfile: document.getElementById("btn-apply-profile"),

  chkFreezer: document.getElementById("chk-freezer"),
  chkUsap: document.getElementById("chk-usap"),
  btnFstrim: document.getElementById("btn-fstrim"),
  btnApplyRuntime: document.getElementById("btn-apply-runtime"),

  valDisplayRes: document.getElementById("val-display-res"),
  valDisplayDpi: document.getElementById("val-display-dpi"),
  groupDisplayScale: document.getElementById("group-display-scale"),
  groupAnimScale: document.getElementById("group-anim-scale"),
  btnApplyDisplay: document.getElementById("btn-apply-display"),
  btnResetDisplay: document.getElementById("btn-reset-display")
};

function log(msg) {
  if (el.footerLog) el.footerLog.textContent = msg;
}

async function withBusyButton(btn, pendingText, fn) {
  if (!btn) return fn();
  const prev = btn.textContent;
  btn.disabled = true;
  if (pendingText) btn.textContent = pendingText;
  try {
    return await fn();
  } finally {
    btn.disabled = false;
    btn.textContent = prev;
  }
}

// --- Native <dialog> Top-Layer Exit & Light-Dismiss Helpers (modern-web-guidance) ---
let supportsDisplayTransition;
function canTransitionDisplay() {
  if (supportsDisplayTransition !== undefined) return supportsDisplayTransition;
  if (!window.CSS?.supports?.("transition-behavior", "allow-discrete") || !document.body) {
    return false;
  }
  const probe = document.createElement("div");
  probe.style.cssText = "transition: display 1s allow-discrete !important; display: block;";
  document.body.appendChild(probe);
  getComputedStyle(probe).display;
  probe.style.display = "none";
  supportsDisplayTransition = getComputedStyle(probe).display === "block";
  probe.remove();
  return supportsDisplayTransition;
}

function supportsTopLayerExit() {
  return Boolean(window.CSS?.supports?.("overlay", "auto") && canTransitionDisplay());
}

async function closeTopLayer(dialog) {
  if (!dialog || !dialog.open) return;
  if (!supportsTopLayerExit()) {
    dialog.setAttribute("data-closing", "");
    const animations = dialog.getAnimations ? dialog.getAnimations({ subtree: true }) : [];
    if (animations.length > 0) {
      await Promise.race([
        Promise.allSettled(animations.map((a) => a.finished)),
        new Promise((r) => setTimeout(r, 350))
      ]);
    }
    if (!dialog.hasAttribute("data-closing")) return;
    dialog.removeAttribute("data-closing");
  }
  dialog.close();
}

function initDialogs() {
  document.querySelectorAll("[data-open-dialog]").forEach((trigger) => {
    trigger.addEventListener("click", () => {
      const dlg = document.getElementById(trigger.getAttribute("data-open-dialog"));
      if (dlg && !dlg.open) {
        syncTunablesUI();
        dlg.showModal();
      }
    });
  });

  const supportsClosedBy = "closedBy" in HTMLDialogElement.prototype;
  const outside = (e, dialog) => {
    const r = dialog.getBoundingClientRect();
    return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
  };

  document.querySelectorAll("dialog.sheet-dialog").forEach((dlg) => {
    dlg.querySelectorAll("[data-close-dialog]").forEach((btn) => {
      btn.addEventListener("click", () => closeTopLayer(dlg));
    });

    dlg.addEventListener("cancel", (event) => {
      event.preventDefault();
      closeTopLayer(dlg);
    });

    dlg.addEventListener("close", () => {
      dlg.removeAttribute("data-closing");
      dlg.returnValue = "";
    });

    if (!supportsClosedBy) {
      let pressedOutside = false;
      dlg.addEventListener("pointerdown", (e) => {
        pressedOutside = outside(e, dlg);
      });
      dlg.addEventListener("pointerup", (e) => {
        if (pressedOutside && outside(e, dlg)) closeTopLayer(dlg);
        pressedOutside = false;
      });
    }
  });
}

// Navigation Router
el.tabBtns.forEach((btn) => {
  btn.addEventListener("click", () => {
    const tabId = btn.getAttribute("data-tab");
    el.tabBtns.forEach((b) => {
      const isSelected = b === btn;
      b.classList.toggle("active", isSelected);
      b.setAttribute("aria-selected", isSelected ? "true" : "false");
    });
    el.tabPanes.forEach((p) => {
      const show = p.id === "tab-" + tabId;
      p.classList.toggle("active", show);
      p.hidden = !show;
    });
    if (tabId === "apps" && appState.installedPackages.length === 0) {
      loadPackages();
    }
  });
});

function parseKV(stdout) {
  const map = {};
  (stdout || "").split("\n").forEach((line) => {
    const idx = line.indexOf("=");
    if (idx > 0) map[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
  });
  return map;
}

function escapeAttr(str) {
  return String(str).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Summary Tile Synchronizer
function updateSummaryTiles() {
  const c = appState.config;
  if (el.sumPowerPolicy) {
    const tg = c.thermal_guard ? `On (${c.thermal_limit_c || 52}°C)` : "Off";
    el.sumPowerPolicy.textContent = `Thermal ${tg} · Limit ${c.charge_limit || 100}%`;
  }
  if (el.sumZram) {
    const gb = ((parseInt(c.zram_size, 10) || 4096) / 1024).toFixed(1);
    const wb = c.zram_writeback ? `WB ${c.wb_size_mb || 1024} MB` : "WB Off";
    el.sumZram.textContent = `${gb} GB · ${c.comp_algorithm || "zstd"} · ${wb}`;
  }
  if (el.sumSwapfile) {
    const smb = parseInt(c.swapfile_mb, 10) || 0;
    if (smb > 0) {
      const gb = (smb / 1024).toFixed(0);
      el.sumSwapfile.textContent = `${gb} GB active · Priority ${c.swapfile_prio ?? -1}`;
    } else {
      el.sumSwapfile.textContent = "Off · Independent from ZRAM";
    }
  }
  if (el.sumCache) {
    el.sumCache.textContent = `Limit ${c.bg_limit || 48} cached apps · Instant apply`;
  }
  if (el.sumVm) {
    el.sumVm.textContent =
      `Swap ${c.swappiness} · WM ${c.watermark_scale || 15} · VFS ${c.vfs_cache_pressure || 100}`;
  }
  if (el.sumProfile) {
    const p = c.power_profile || "balance";
    el.sumProfile.textContent = `${p.charAt(0).toUpperCase() + p.slice(1)} · Schedutil + Adreno 610`;
  }
  if (el.sumRuntime) {
    el.sumRuntime.textContent =
      `Freezer ${c.use_freezer ? "On" : "Off"} · USAP ${c.usap_pool ? "On" : "Off"} · FSTRIM`;
  }
}

// Telemetry Poller
async function fetchTelemetry() {
  const res = await execHelper("status");
  if (res.errno !== 0) {
    log("Telemetry error: " + (res.stderr || `errno ${res.errno}`));
    return;
  }

  const kv = parseKV(res.stdout);
  const memFreeMb = Math.round((parseInt(kv.MEM_MEMFREE, 10) || 0) / 1024);
  const memAvailMb = Math.round((parseInt(kv.MEM_MEMAVAILABLE, 10) || 0) / 1024);
  const swapTotalMb = Math.round((parseInt(kv.MEM_SWAPTOTAL, 10) || 0) / 1024);

  const mmTokens = (kv.MM_STAT || "").split(/\s+/).filter(Boolean);
  let origSizeMb = 0;
  let compSizeMb = 0;
  let ratio = "1.00";
  if (mmTokens.length >= 2) {
    const origBytes = parseInt(mmTokens[0], 10) || 0;
    const compBytes = parseInt(mmTokens[1], 10) || 0;
    origSizeMb = Math.round(origBytes / 1048576);
    compSizeMb = Math.round(compBytes / 1048576);
    ratio = compBytes > 0 ? (origBytes / compBytes).toFixed(2) : "1.00";
  }

  const mglruOn = kv.MGLRU && kv.MGLRU !== "0x0000" && kv.MGLRU !== "0";
  if (el.badgeKernelMode) {
    el.badgeKernelMode.textContent = mglruOn ? "PSI + MGLRU" : "PSI LMKD";
  }

  const psiMatch = (kv.PSI_MEM || "").match(/avg10=([\d.]+)/);
  if (el.psiMem) {
    el.psiMem.textContent = psiMatch ? `PSI avg10 ${psiMatch[1]}%` : "PSI N/A";
  }

  el.memAvail.textContent = memAvailMb + " MB";
  if (el.memFreeInline) el.memFreeInline.textContent = `Free ${memFreeMb} MB`;
  el.zramTotal.textContent = swapTotalMb + " MB";
  el.zramUsed.textContent = origSizeMb + " MB";
  el.zramPhys.textContent = compSizeMb + " MB";
  if (el.zramRatioAlgo) {
    el.zramRatioAlgo.textContent = `${ratio}x · ${kv.COMP_ALGO || "?"}`;
  }

  appState.wbSupported = kv.WB_SUPPORTED === "1";
  const bdNode = kv.BACKING_DEV || "none";
  if (el.chkZramWb) {
    el.chkZramWb.disabled = !appState.wbSupported;
    if (!appState.wbSupported) el.chkZramWb.title = "CONFIG_ZRAM_WRITEBACK unavailable";
  }
  if (el.rowWbStat) {
    if (bdNode && bdNode !== "none") {
      el.rowWbStat.hidden = false;
      const bdParts = (kv.BD_STAT || "").split(/\s+/).filter(Boolean);
      const writtenMb = (((parseInt(bdParts[2], 10) || 0) * 4) / 1024).toFixed(1);
      el.valWbStat.textContent = `${bdNode} (${writtenMb} MB out)`;
    } else {
      el.rowWbStat.hidden = true;
    }
  }

  if (el.rowSwapfileStat && el.valSwapfileStat) {
    const sfLine = (kv.SWAPFILE_LINE || "").trim();
    if (sfLine) {
      const [dev, sizeKb, usedKb, prio] = sfLine.split(/\s+/);
      const szMb = Math.round((parseInt(sizeKb, 10) || 0) / 1024);
      const usMb = Math.round((parseInt(usedKb, 10) || 0) / 1024);
      el.rowSwapfileStat.hidden = false;
      el.valSwapfileStat.textContent = `${usMb}/${szMb} MB (${dev}, p=${prio || 0})`;
    } else {
      el.rowSwapfileStat.hidden = true;
    }
  }

  if (kv.ANIM_SCALE) {
    appState.animScale = kv.ANIM_SCALE === "null" ? "1.0" : kv.ANIM_SCALE;
  }

  const swapPct = swapTotalMb > 0 ? Math.round((origSizeMb / swapTotalMb) * 100) : 0;
  const boundedPct = Math.min(100, Math.max(0, swapPct));
  const swapStateText = boundedPct > 85 ? "High" : boundedPct > 65 ? "Elevated" : "Normal";
  el.swapPct.textContent = `${boundedPct}% · ${swapStateText}`;
  el.barSwap.style.width = boundedPct + "%";
  if (el.barSwapTrack) el.barSwapTrack.setAttribute("aria-valuenow", String(boundedPct));

  if (boundedPct > 85) el.barSwap.style.backgroundColor = "var(--status-err)";
  else if (boundedPct > 65) el.barSwap.style.backgroundColor = "var(--status-warn)";
  else el.barSwap.style.backgroundColor = "var(--accent)";

  // Power
  const tempRaw = parseInt(kv.PWR_TEMP, 10) || 0;
  const currRaw = parseInt(kv.PWR_CURRENT, 10) || 0;
  const voltRaw = parseInt(kv.PWR_VOLTAGE, 10) || 0;
  const statusStr = kv.PWR_STATUS || "Unknown";
  const typeStr = kv.PWR_TYPE || "USB";
  const ceVal = kv.PWR_CE || "";
  const isVal = kv.PWR_IS || "";
  const capVal = kv.PWR_CAP || "";

  let chargeEnabled = true;
  let chargeNodeSupported = true;
  if (ceVal !== "") chargeEnabled = ceVal === "1";
  else if (isVal !== "") chargeEnabled = isVal === "0";
  else chargeNodeSupported = false;

  const tempC = (tempRaw / 10).toFixed(1);
  const currentMa = Math.abs(Math.round(currRaw / 1000));
  const voltageV = (voltRaw / 1000000).toFixed(2);
  const watt = ((currentMa * parseFloat(voltageV || "0")) / 1000).toFixed(1);

  if (el.pwrStatusChip) el.pwrStatusChip.textContent = chargeEnabled ? statusStr : "Paused";
  if (el.pwrPortVolt) el.pwrPortVolt.textContent = `${typeStr} · ${voltageV} V`;
  const sign = statusStr === "Charging" ? "+" : statusStr === "Discharging" ? "-" : "";
  if (el.pwrCurrent) el.pwrCurrent.textContent = `${sign}${currentMa} mA`;

  el.headerTemp.textContent = tempC + "°C";
  el.headerCharge.textContent = watt + "W";
  el.headerBatt.textContent = (capVal !== "" ? capVal : "--") + "%";

  el.chkBypassMaster.checked = appState.config.bypass_charging === true;
  el.chkBypassMaster.disabled = !chargeNodeSupported;

  log(`Live: ${tempC}°C | ${watt}W | Swap ${boundedPct}%` + (chargeNodeSupported ? "" : " | Charge toggle N/A"));
}

// Quick Actions
el.btnRefresh.addEventListener("click", fetchTelemetry);

el.btnCompact.addEventListener("click", () =>
  withBusyButton(el.btnCompact, "Compacting...", async () => {
    await execHelper("compact soft");
    await fetchTelemetry();
    log("ZRAM compaction complete.");
  })
);

el.btnReclaim.addEventListener("click", () =>
  withBusyButton(el.btnReclaim, "Reclaiming...", async () => {
    await execHelper("compact hard");
    await fetchTelemetry();
    log("Deep reclaim & cache flush complete.");
  })
);

el.btnTrim.addEventListener("click", () =>
  withBusyButton(el.btnTrim, "Trimming...", async () => {
    await exec("am kill-all");
    await fetchTelemetry();
    log("Inactive cached applications trimmed.");
  })
);

// Master Bypass Toggle
el.chkBypassMaster.addEventListener("change", async (e) => {
  const bypass = e.target.checked;
  const probe = await exec(
    "if [ -e /sys/class/power_supply/battery/charging_enabled ]; then echo charging_enabled;" +
    "elif [ -e /sys/class/power_supply/battery/input_suspend ]; then echo input_suspend;" +
    "else echo none; fi"
  );
  const node = probe.stdout.trim();
  if (node === "none") {
    log("Charging control unsupported by kernel.");
    e.target.checked = false;
    return;
  }
  const val = node === "charging_enabled" ? (bypass ? "0" : "1") : (bypass ? "1" : "0");
  const wres = await exec(`echo ${val} > /sys/class/power_supply/battery/${node}`);
  if (wres.errno !== 0) {
    log("Failed updating charging node.");
    e.target.checked = !bypass;
    return;
  }
  appState.config.bypass_charging = bypass;
  await saveConfig();
  await fetchTelemetry();
});

// App Manager
function updateRuleSummary() {
  if (!el.appCounts) return;
  const g = (appState.config.auto_bypass_games || []).length;
  const s = (appState.config.heavy_swap_apps || []).length;
  el.appCounts.textContent = `${g} game · ${s} swap`;
}

async function loadPackages() {
  log("Scanning installed user packages...");
  const res = await exec("pm list packages -3 | cut -d: -f2 | sort");
  if (res.errno === 0) {
    appState.installedPackages = res.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
    renderAppList();
    log(`Loaded ${appState.installedPackages.length} packages.`);
  } else {
    el.appListContainer.innerHTML = '<div class="empty-state">Unable to list packages from root bridge.</div>';
    log("Failed loading packages: " + res.stderr);
  }
}

function renderAppList() {
  updateRuleSummary();
  const query = (el.appSearch.value || "").toLowerCase().trim();
  const games = appState.config.auto_bypass_games || [];
  const swaps = appState.config.heavy_swap_apps || [];

  const list = appState.installedPackages.filter((pkg) => {
    if (query && !pkg.toLowerCase().includes(query)) return false;
    if (appState.filterActiveOnly) return games.includes(pkg) || swaps.includes(pkg);
    return true;
  });

  if (list.length === 0) {
    el.appListContainer.innerHTML = '<div class="empty-state">No packages match this filter.</div>';
    return;
  }

  let html = "";
  list.forEach((pkg) => {
    const safePkg = escapeAttr(pkg);
    const isGame = games.includes(pkg);
    const isSwap = swaps.includes(pkg);

    html += `
      <div class="app-row" data-pkg="${safePkg}">
        <div class="app-meta"><span class="app-pkg">${safePkg}</span></div>
        <div class="app-tags">
          <button type="button" class="tag-btn ${isGame ? "active-game" : ""}" aria-pressed="${isGame}" data-action="toggle-game" data-pkg="${safePkg}">
            ${isGame ? "Game on" : "Game"}
          </button>
          <button type="button" class="tag-btn ${isSwap ? "active-swap" : ""}" aria-pressed="${isSwap}" data-action="toggle-swap" data-pkg="${safePkg}">
            ${isSwap ? "Swap on" : "Swap"}
          </button>
        </div>
      </div>
    `;
  });
  el.appListContainer.innerHTML = html;
}

el.appSearch.addEventListener("input", renderAppList);

if (el.btnFilterActive) {
  el.btnFilterActive.addEventListener("click", () => {
    appState.filterActiveOnly = !appState.filterActiveOnly;
    el.btnFilterActive.setAttribute("aria-pressed", String(appState.filterActiveOnly));
    renderAppList();
  });
}

el.appListContainer.addEventListener("click", (e) => {
  const btn = e.target.closest(".tag-btn");
  if (!btn) return;
  const action = btn.getAttribute("data-action");
  const pkg = btn.getAttribute("data-pkg");
  if (!pkg) return;

  const targetKey = action === "toggle-game" ? "auto_bypass_games" : "heavy_swap_apps";
  const arr = appState.config[targetKey] || [];
  const idx = arr.indexOf(pkg);
  if (idx >= 0) arr.splice(idx, 1);
  else arr.push(pkg);
  appState.config[targetKey] = arr;
  renderAppList();
});

el.btnSaveApps.addEventListener("click", () =>
  withBusyButton(el.btnSaveApps, "Saving...", async () => {
    if (await saveConfig()) {
      log("Per-app rules saved instantly.");
    }
  })
);

// Config Persistence
async function loadConfig() {
  const res = await exec(`cat ${CONFIG_PATH} 2>/dev/null`);
  if (res.errno === 0 && res.stdout.trim()) {
    try {
      appState.config = Object.assign({}, appState.config, JSON.parse(res.stdout));
    } catch (_) {
      log("Config parse warning; using safe defaults.");
    }
  }
  syncTunablesUI();
  updateRuleSummary();
}

async function saveConfig() {
  const jsonStr = JSON.stringify(appState.config, null, 2);
  const cmd = `cat << 'KAIROS_CFG_EOF' > ${CONFIG_PATH}\n${jsonStr}\nKAIROS_CFG_EOF\nchmod 644 ${CONFIG_PATH}`;
  const res = await exec(cmd);
  if (res.errno !== 0) {
    log("Save config failed: " + (res.stderr || `errno ${res.errno}`));
    return false;
  }
  updateSummaryTiles();
  return true;
}

// Pill Selection Wiring
function setupPillGroup(groupEl, configKey, onPick) {
  if (!groupEl) return;
  groupEl.addEventListener("click", (e) => {
    const btn = e.target.closest(".pill-btn");
    if (!btn) return;
    groupEl.querySelectorAll(".pill-btn").forEach((b) => {
      b.classList.remove("active");
      b.setAttribute("aria-pressed", "false");
    });
    btn.classList.add("active");
    btn.setAttribute("aria-pressed", "true");
    const val = btn.getAttribute("data-val");
    if (configKey) appState.config[configKey] = isNaN(Number(val)) ? val : Number(val);
    if (onPick) onPick(configKey ? appState.config[configKey] : val);
  });
}

setupPillGroup(el.groupCompAlgo, "comp_algorithm");
setupPillGroup(el.groupZramSize, "zram_size");
setupPillGroup(el.groupWbSize, "wb_size_mb");
setupPillGroup(el.groupSwapfileSize, "swapfile_mb", (val) => {
  if (el.groupSwapfilePrioWrap) el.groupSwapfilePrioWrap.hidden = Number(val) === 0;
});
setupPillGroup(el.groupSwapfilePrio, "swapfile_prio");
setupPillGroup(el.groupBgLimit, "bg_limit");
setupPillGroup(el.groupSwappiness, "swappiness");
setupPillGroup(el.groupWmScale, "watermark_scale");
setupPillGroup(el.groupVfsPressure, "vfs_cache_pressure");
setupPillGroup(el.groupCompProact, "compaction_proactiveness");
setupPillGroup(el.groupPowerProfile, "power_profile");
setupPillGroup(el.groupThermalLimit, "thermal_limit_c");
setupPillGroup(el.groupChargeLimit, "charge_limit");

if (el.chkThermalGuard) {
  el.chkThermalGuard.addEventListener("change", (e) => {
    appState.config.thermal_guard = e.target.checked;
    if (el.groupThermalLimitWrap) el.groupThermalLimitWrap.hidden = !e.target.checked;
  });
}

if (el.chkZramWb) {
  el.chkZramWb.addEventListener("change", (e) => {
    appState.config.zram_writeback = e.target.checked;
    if (el.groupWbSizeWrap) el.groupWbSizeWrap.hidden = !e.target.checked;
  });
}

if (el.chkFreezer) {
  el.chkFreezer.addEventListener("change", (e) => {
    appState.config.use_freezer = e.target.checked;
  });
}

if (el.chkUsap) {
  el.chkUsap.addEventListener("change", (e) => {
    appState.config.usap_pool = e.target.checked;
  });
}

if (el.groupAnimScale) {
  el.groupAnimScale.addEventListener("click", (e) => {
    const btn = e.target.closest(".pill-btn");
    if (!btn) return;
    el.groupAnimScale.querySelectorAll(".pill-btn").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    appState.animScale = btn.getAttribute("data-anim") || "1.0";
  });
}

function syncTunablesUI() {
  const selectPill = (groupEl, val, attr = "data-val") => {
    if (!groupEl) return;
    groupEl.querySelectorAll(".pill-btn").forEach((b) => {
      const match = b.getAttribute(attr) == String(val);
      b.classList.toggle("active", match);
      b.setAttribute("aria-pressed", match ? "true" : "false");
    });
  };
  const c = appState.config;
  selectPill(el.groupCompAlgo, c.comp_algorithm || "zstd");
  selectPill(el.groupZramSize, c.zram_size || "4096M");
  selectPill(el.groupWbSize, c.wb_size_mb || 1024);
  selectPill(el.groupSwapfileSize, c.swapfile_mb ?? 0);
  selectPill(el.groupSwapfilePrio, c.swapfile_prio ?? -1);
  selectPill(el.groupBgLimit, c.bg_limit || 48);
  selectPill(el.groupSwappiness, c.swappiness);
  selectPill(el.groupWmScale, c.watermark_scale || 15);
  selectPill(el.groupVfsPressure, c.vfs_cache_pressure || 100);
  selectPill(el.groupCompProact, c.compaction_proactiveness ?? 20);
  selectPill(el.groupPowerProfile, c.power_profile || "balance");
  selectPill(el.groupThermalLimit, c.thermal_limit_c || 52);
  selectPill(el.groupChargeLimit, c.charge_limit || 100);
  selectPill(el.groupAnimScale, parseFloat(appState.animScale || "1.0"), "data-anim");

  if (el.groupSwapfilePrioWrap) {
    el.groupSwapfilePrioWrap.hidden = Number(c.swapfile_mb || 0) === 0;
  }
  if (el.chkThermalGuard) {
    el.chkThermalGuard.checked = c.thermal_guard === true;
    if (el.groupThermalLimitWrap) el.groupThermalLimitWrap.hidden = !el.chkThermalGuard.checked;
  }
  if (el.chkZramWb) {
    el.chkZramWb.checked = c.zram_writeback === true;
    if (el.groupWbSizeWrap) el.groupWbSizeWrap.hidden = !el.chkZramWb.checked;
  }
  if (el.chkFreezer) el.chkFreezer.checked = c.use_freezer !== false;
  if (el.chkUsap) el.chkUsap.checked = c.usap_pool === true;
  updateSummaryTiles();
}

// Per-Item Fast Apply Handlers (Zero unrelated overhead!)
if (el.btnSavePower) {
  el.btnSavePower.addEventListener("click", () =>
    withBusyButton(el.btnSavePower, "Saving...", async () => {
      if (await saveConfig()) {
        await closeTopLayer(document.getElementById("dlg-power"));
        log("Power policy updated.");
      }
    })
  );
}

if (el.btnSaveZramReboot) {
  el.btnSaveZramReboot.addEventListener("click", () =>
    withBusyButton(el.btnSaveZramReboot, "Saving...", async () => {
      if (await saveConfig()) {
        await closeTopLayer(document.getElementById("dlg-zram"));
        log("ZRAM config saved for next boot (zero live freeze).");
      }
    })
  );
}

if (el.btnApplyZramLive) {
  el.btnApplyZramLive.addEventListener("click", () =>
    withBusyButton(el.btnApplyZramLive, "Rebuilding...", async () => {
      if (!(await saveConfig())) return;
      const c = appState.config;
      const wbFlag = c.zram_writeback ? 1 : 0;
      const zres = await execHelper(
        `zram "${c.zram_size || "4096M"}" "${c.comp_algorithm || "zstd"}" ${wbFlag} ${c.wb_size_mb || 1024}`,
        45000
      );
      await fetchTelemetry();
      await closeTopLayer(document.getElementById("dlg-zram"));
      if (zres.errno === -2) log("Live ZRAM rebuild timed out (saved for reboot).");
      else if (zres.stdout.includes("ZRAM_FAIL") || zres.stdout.includes("DISKSIZE_FAIL")) log("ZRAM apply failed.");
      else if (zres.stdout.includes("WB_UNSUPPORTED")) log("ZRAM applied (writeback unsupported by kernel).");
      else if (zres.stdout.includes("ZRAM_UNCHANGED")) log("ZRAM already matches active settings.");
      else log("ZRAM rebuilt & persisted.");
    })
  );
}

if (el.btnApplySwapfile) {
  el.btnApplySwapfile.addEventListener("click", () =>
    withBusyButton(el.btnApplySwapfile, "Applying...", async () => {
      if (!(await saveConfig())) return;
      const c = appState.config;
      const mb = parseInt(c.swapfile_mb, 10) || 0;
      const prio = c.swapfile_prio ?? -1;
      const res = await execHelper(`swapfile ${mb} ${prio}`, 60000);
      await fetchTelemetry();
      await closeTopLayer(document.getElementById("dlg-swapfile"));
      if (res.stdout.includes("SWAP_OFF")) log("Extra swapfile disabled & removed.");
      else if (res.stdout.includes("SWAP_OK")) log(`Extra swapfile active (${mb} MB, prio ${prio}).`);
      else log("Swapfile setup failed: " + (res.stdout || res.stderr));
    })
  );
}

if (el.btnApplyCache) {
  el.btnApplyCache.addEventListener("click", () =>
    withBusyButton(el.btnApplyCache, "Applying...", async () => {
      if (!(await saveConfig())) return;
      const limit = appState.config.bg_limit || 48;
      const res = await exec(
        `resetprop ro.sys.fw.bg_apps_limit ${limit}; ` +
        `device_config put activity_manager max_cached_processes ${limit} 2>/dev/null`
      );
      await closeTopLayer(document.getElementById("dlg-cache"));
      log(res.errno === 0 ? `Cache limit applied (${limit} apps, no swapoff).` : "Failed updating cache limit.");
    })
  );
}

if (el.btnApplyVm) {
  el.btnApplyVm.addEventListener("click", () =>
    withBusyButton(el.btnApplyVm, "Applying...", async () => {
      if (!(await saveConfig())) return;
      const c = appState.config;
      const vres = await execHelper(
        `vm ${c.swappiness} ${c.vfs_cache_pressure || 100} ${c.watermark_scale || 15} ${c.compaction_proactiveness ?? 20}`,
        8000
      );
      await closeTopLayer(document.getElementById("dlg-vm"));
      log(vres.stdout.includes("VM_OK") ? "VM tunables applied instantly." : "VM apply failed.");
    })
  );
}

if (el.btnApplyProfile) {
  el.btnApplyProfile.addEventListener("click", () =>
    withBusyButton(el.btnApplyProfile, "Applying...", async () => {
      if (!(await saveConfig())) return;
      const prof = appState.config.power_profile || "balance";
      const res = await exec(`P=$(${POWER_HELPER}); sh "$P" "${prof}"`);
      await closeTopLayer(document.getElementById("dlg-profile"));
      log(res.errno === 0 ? `Power profile switched to ${prof}.` : "Failed switching profile.");
    })
  );
}

if (el.btnApplyRuntime) {
  el.btnApplyRuntime.addEventListener("click", () =>
    withBusyButton(el.btnApplyRuntime, "Saving...", async () => {
      if (!(await saveConfig())) return;
      const freezer = appState.config.use_freezer ? "true" : "false";
      const usap = appState.config.usap_pool ? "true" : "false";
      await exec(
        `device_config put activity_manager_native_boot use_freezer ${freezer} 2>/dev/null; ` +
        `setprop persist.device_config.runtime_native.usap_pool_enabled ${usap} 2>/dev/null`
      );
      await closeTopLayer(document.getElementById("dlg-runtime"));
      log(`Runtime saved (Freezer ${freezer}, USAP ${usap}).`);
    })
  );
}

if (el.btnFstrim) {
  el.btnFstrim.addEventListener("click", () =>
    withBusyButton(el.btnFstrim, "Trimming...", async () => {
      await exec("fstrim /data 2>/dev/null; fstrim /cache 2>/dev/null; sm fstrim 2>/dev/null", 30000);
      log("Flash FSTRIM completed on /data & /cache.");
    })
  );
}

// Display Manager & Animation Speed
async function fetchDisplayInfo() {
  const sizeRes = await exec("wm size");
  const densRes = await exec("wm density");

  let physW = 720, physH = 1650, currW = 720, currH = 1650;
  let physDpi = 268, currDpi = 268;

  const physSizeMatch = sizeRes.stdout.match(/Physical size:\s*(\d+)x(\d+)/i);
  if (physSizeMatch) {
    physW = parseInt(physSizeMatch[1], 10);
    physH = parseInt(physSizeMatch[2], 10);
  }
  const overSizeMatch = sizeRes.stdout.match(/Override size:\s*(\d+)x(\d+)/i);
  if (overSizeMatch) {
    currW = parseInt(overSizeMatch[1], 10);
    currH = parseInt(overSizeMatch[2], 10);
  } else {
    currW = physW;
    currH = physH;
  }

  const physDensMatch = densRes.stdout.match(/Physical density:\s*(\d+)/i);
  if (physDensMatch) physDpi = parseInt(physDensMatch[1], 10);
  const overDensMatch = densRes.stdout.match(/Override density:\s*(\d+)/i);
  currDpi = overDensMatch ? parseInt(overDensMatch[1], 10) : physDpi;

  appState.display.physWidth = physW;
  appState.display.physHeight = physH;
  appState.display.physDpi = physDpi;
  appState.display.currWidth = currW;
  appState.display.currHeight = currH;
  appState.display.currDpi = currDpi;

  if (el.valDisplayRes) el.valDisplayRes.textContent = `${currW}x${currH}`;
  if (el.valDisplayDpi) el.valDisplayDpi.textContent = `${currDpi} dpi`;
  if (el.sumDisplay) el.sumDisplay.textContent = `${currW}×${currH} · ${currDpi} dpi · Anim ${appState.animScale}x`;
}

if (el.groupDisplayScale) {
  el.groupDisplayScale.addEventListener("click", (e) => {
    const btn = e.target.closest(".pill-btn");
    if (!btn) return;
    el.groupDisplayScale.querySelectorAll(".pill-btn").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    appState.display.selectedScale = parseFloat(btn.getAttribute("data-scale")) || 1.0;
  });
}

if (el.btnApplyDisplay) {
  el.btnApplyDisplay.addEventListener("click", () =>
    withBusyButton(el.btnApplyDisplay, "Applying...", async () => {
      const scale = appState.display.selectedScale;
      const anim = appState.animScale || "1.0";
      let cmd =
        `settings put global window_animation_scale ${anim}; ` +
        `settings put global transition_animation_scale ${anim}; ` +
        `settings put global animator_duration_scale ${anim}; `;
      if (Math.abs(scale - 1.0) < 0.01) {
        cmd += "wm size reset && wm density reset";
      } else {
        const targetW = Math.round(appState.display.physWidth * scale);
        const targetH = Math.round(appState.display.physHeight * scale);
        const targetDpi = Math.round(appState.display.physDpi * scale);
        cmd += `wm size ${targetW}x${targetH} && wm density ${targetDpi}`;
      }
      await exec(cmd);
      await fetchDisplayInfo();
      await closeTopLayer(document.getElementById("dlg-display"));
      log(`Display updated (${Math.round(scale * 100)}%, anim ${anim}x).`);
    })
  );
}

if (el.btnResetDisplay) {
  el.btnResetDisplay.addEventListener("click", () =>
    withBusyButton(el.btnResetDisplay, "Resetting...", async () => {
      await exec(
        "wm size reset && wm density reset && " +
        "settings put global window_animation_scale 1.0 && " +
        "settings put global transition_animation_scale 1.0 && " +
        "settings put global animator_duration_scale 1.0"
      );
      appState.display.selectedScale = 1.0;
      appState.animScale = "1.0";
      syncTunablesUI();
      await fetchDisplayInfo();
      await closeTopLayer(document.getElementById("dlg-display"));
      log("Display & animation scale reset to 100% / 1.0x.");
    })
  );
}

// Boot Initializer
let polling = false;
async function pollTelemetry() {
  if (polling || document.hidden) return;
  polling = true;
  try {
    await fetchTelemetry();
  } finally {
    polling = false;
  }
}

async function init() {
  initDialogs();
  if (!hasBridge()) {
    log("KernelSU bridge not found. Open inside KernelSU Manager.");
    return;
  }
  await loadConfig();
  await pollTelemetry();
  fetchDisplayInfo();
  setInterval(pollTelemetry, 3500);
}

window.addEventListener("DOMContentLoaded", init);
