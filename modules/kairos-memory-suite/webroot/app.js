// Kairos Engine WebUI Client Controller
// Single bridge helper + shared kairos_zram.sh CLI integration.

const CONFIG_PATH = "/data/adb/kairos_config.json";
const ZRAM_HELPER =
  "[ -x /data/adb/modules_update/kairos_memory_suite/kairos_zram.sh ] " +
  "&& echo /data/adb/modules_update/kairos_memory_suite/kairos_zram.sh " +
  "|| echo /data/adb/modules/kairos_memory_suite/kairos_zram.sh";

function hasBridge() {
  return !!(window.ksu && window.ksu.exec);
}

function exec(cmd, timeoutMs = 12000) {
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

async function execHelper(subcmd) {
  return exec(`HELPER=$(${ZRAM_HELPER}); sh "$HELPER" ${subcmd}`, 20000);
}

const appState = {
  config: {
    bypass_charging: false,
    auto_bypass_games: [],
    heavy_swap_apps: [],
    swappiness: 100,
    comp_algorithm: "zstd",
    zram_size: "3072M",
    zram_writeback: false,
    wb_size_mb: 1024,
    watermark_scale: 15,
    vfs_cache_pressure: 100,
    compaction_proactiveness: 20,
    bg_limit: 48,
    thermal_guard: false,
    thermal_limit_c: 52,
    charge_limit: 100
  },
  wbSupported: false,
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

  memFree: document.getElementById("val-mem-free"),
  memAvail: document.getElementById("val-mem-avail"),
  psiMem: document.getElementById("val-psi-mem"),
  zramUsed: document.getElementById("val-zram-used"),
  zramPhys: document.getElementById("val-zram-phys"),
  zramRatio: document.getElementById("val-zram-ratio"),
  zramAlgo: document.getElementById("val-zram-algo"),
  zramTotal: document.getElementById("val-zram-total"),
  rowWbStat: document.getElementById("row-wb-stat"),
  valWbStat: document.getElementById("val-wb-stat"),
  swapPct: document.getElementById("val-swap-pct"),
  barSwap: document.getElementById("bar-swap"),
  barSwapTrack: document.getElementById("bar-swap-track"),
  btnRefresh: document.getElementById("btn-refresh"),
  btnCompact: document.getElementById("btn-compact"),
  btnReclaim: document.getElementById("btn-reclaim"),
  btnTrim: document.getElementById("btn-trim"),

  pwrStatus: document.getElementById("val-pwr-status"),
  pwrType: document.getElementById("val-pwr-type"),
  pwrCurrent: document.getElementById("val-pwr-current"),
  pwrVoltage: document.getElementById("val-pwr-voltage"),
  chkBypassMaster: document.getElementById("chk-bypass-master"),
  chkThermalGuard: document.getElementById("chk-thermal-guard"),
  groupChargeLimit: document.getElementById("group-charge-limit"),

  appSearch: document.getElementById("app-search"),
  appCounts: document.getElementById("val-app-counts"),
  appListContainer: document.getElementById("app-list-container"),
  btnSaveApps: document.getElementById("btn-save-apps"),

  groupCompAlgo: document.getElementById("group-comp-algo"),
  groupZramSize: document.getElementById("group-zram-size"),
  chkZramWb: document.getElementById("chk-zram-wb"),
  groupWbSizeWrap: document.getElementById("group-wb-size-wrap"),
  groupWbSize: document.getElementById("group-wb-size"),
  groupSwappiness: document.getElementById("group-swappiness"),
  groupWmScale: document.getElementById("group-wm-scale"),
  groupVfsPressure: document.getElementById("group-vfs-pressure"),
  groupBgLimit: document.getElementById("group-bg-limit"),
  btnApplyTunables: document.getElementById("btn-apply-tunables"),

  valDisplayRes: document.getElementById("val-display-res"),
  valDisplayDpi: document.getElementById("val-display-dpi"),
  groupDisplayScale: document.getElementById("group-display-scale"),
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

// Navigation Router (accessible tablist + hidden panels)
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
    if (idx > 0) {
      map[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
    }
  });
  return map;
}

function escapeAttr(str) {
  return String(str).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Telemetry Poller
async function fetchTelemetry() {
  const res = await execHelper("status");
  if (res.errno !== 0) {
    log("Telemetry fetch failed: " + (res.stderr || `errno ${res.errno}`));
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

  el.memFree.textContent = memFreeMb + " MB";
  el.memAvail.textContent = memAvailMb + " MB";
  el.zramUsed.textContent = origSizeMb + " MB";
  el.zramPhys.textContent = compSizeMb + " MB";
  el.zramRatio.textContent = ratio + " x";
  el.zramTotal.textContent = swapTotalMb + " MB";
  if (el.zramAlgo) el.zramAlgo.textContent = kv.COMP_ALGO || "unknown";

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
      const writtenKb = (parseInt(bdParts[2], 10) || 0) * 4;
      const writtenMb = (writtenKb / 1024).toFixed(1);
      el.valWbStat.textContent = `${bdNode} (${writtenMb} MB out)`;
    } else {
      el.rowWbStat.hidden = true;
    }
  }

  const swapPct = swapTotalMb > 0 ? Math.round((origSizeMb / swapTotalMb) * 100) : 0;
  const boundedPct = Math.min(100, Math.max(0, swapPct));
  el.swapPct.textContent = boundedPct + "%";
  el.barSwap.style.width = boundedPct + "%";
  if (el.barSwapTrack) el.barSwapTrack.setAttribute("aria-valuenow", String(boundedPct));
  if (boundedPct > 85) {
    el.barSwap.style.backgroundColor = "var(--status-err)";
  } else if (boundedPct > 65) {
    el.barSwap.style.backgroundColor = "var(--status-warn)";
  } else {
    el.barSwap.style.backgroundColor = "var(--accent)";
  }

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

  el.pwrStatus.textContent = chargeEnabled ? statusStr : "Charging paused";
  el.pwrType.textContent = typeStr;
  const sign = statusStr === "Charging" ? "+" : statusStr === "Discharging" ? "-" : "";
  el.pwrCurrent.textContent = sign + currentMa + " mA";
  el.pwrVoltage.textContent = voltageV + " V";
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

if (el.btnReclaim) {
  el.btnReclaim.addEventListener("click", () =>
    withBusyButton(el.btnReclaim, "Reclaiming...", async () => {
      await execHelper("compact hard");
      await fetchTelemetry();
      log("Deep reclaim & cache flush complete.");
    })
  );
}

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

el.chkThermalGuard.addEventListener("change", async (e) => {
  appState.config.thermal_guard = e.target.checked;
  if (await saveConfig()) {
    log("Thermal guard " + (e.target.checked ? "enabled" : "disabled") + ".");
  }
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
  const list = appState.installedPackages.filter((pkg) => pkg.toLowerCase().includes(query));

  if (list.length === 0) {
    el.appListContainer.innerHTML = '<div class="empty-state">No packages match this filter. Adjust the query to manage rules.</div>';
    return;
  }

  let html = "";
  list.forEach((pkg) => {
    const safePkg = escapeAttr(pkg);
    const isGame = (appState.config.auto_bypass_games || []).includes(pkg);
    const isSwap = (appState.config.heavy_swap_apps || []).includes(pkg);

    html += `
      <div class="app-row" data-pkg="${safePkg}">
        <div class="app-meta">
          <span class="app-pkg">${safePkg}</span>
        </div>
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
      log("Per-app rules saved to /data/adb/kairos_config.json.");
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
  return true;
}

// Tunables Controller
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
    appState.config[configKey] = isNaN(Number(val)) ? val : Number(val);
    if (onPick) onPick(appState.config[configKey]);
  });
}

setupPillGroup(el.groupCompAlgo, "comp_algorithm");
setupPillGroup(el.groupZramSize, "zram_size");
setupPillGroup(el.groupWbSize, "wb_size_mb");
setupPillGroup(el.groupSwappiness, "swappiness");
setupPillGroup(el.groupWmScale, "watermark_scale");
setupPillGroup(el.groupVfsPressure, "vfs_cache_pressure");
setupPillGroup(el.groupBgLimit, "bg_limit");

if (el.chkZramWb) {
  el.chkZramWb.addEventListener("change", (e) => {
    appState.config.zram_writeback = e.target.checked;
    if (el.groupWbSizeWrap) el.groupWbSizeWrap.hidden = !e.target.checked;
  });
}

if (el.groupChargeLimit) {
  setupPillGroup(el.groupChargeLimit, "charge_limit", async (val) => {
    if (await saveConfig()) {
      log(`Charge limit set to ${val}%.`);
    }
  });
}

function syncTunablesUI() {
  const selectPill = (groupEl, val) => {
    if (!groupEl) return;
    groupEl.querySelectorAll(".pill-btn").forEach((b) => {
      const match = b.getAttribute("data-val") == String(val);
      b.classList.toggle("active", match);
      b.setAttribute("aria-pressed", match ? "true" : "false");
    });
  };
  selectPill(el.groupCompAlgo, appState.config.comp_algorithm || "zstd");
  selectPill(el.groupZramSize, appState.config.zram_size || "3072M");
  selectPill(el.groupWbSize, appState.config.wb_size_mb || 1024);
  selectPill(el.groupSwappiness, appState.config.swappiness);
  selectPill(el.groupWmScale, appState.config.watermark_scale || 15);
  selectPill(el.groupVfsPressure, appState.config.vfs_cache_pressure || 100);
  selectPill(el.groupBgLimit, appState.config.bg_limit || 48);
  selectPill(el.groupChargeLimit, appState.config.charge_limit || 100);
  if (el.chkThermalGuard) el.chkThermalGuard.checked = appState.config.thermal_guard === true;
  if (el.chkZramWb) {
    el.chkZramWb.checked = appState.config.zram_writeback === true;
    if (el.groupWbSizeWrap) el.groupWbSizeWrap.hidden = !el.chkZramWb.checked;
  }
}

el.btnApplyTunables.addEventListener("click", () =>
  withBusyButton(el.btnApplyTunables, "Applying...", async () => {
    if (!(await saveConfig())) return;

    const c = appState.config;
    const limit = c.bg_limit || 48;
    const wbFlag = c.zram_writeback ? 1 : 0;

    await exec(
      `resetprop ro.sys.fw.bg_apps_limit ${limit}; ` +
      `device_config put activity_manager max_cached_processes ${limit} 2>/dev/null`
    );

    const zres = await execHelper(
      `apply "${c.zram_size || "3072M"}" "${c.comp_algorithm || "zstd"}" ` +
      `${wbFlag} ${c.wb_size_mb || 1024} ${c.swappiness || 100} ` +
      `${c.vfs_cache_pressure || 100} ${c.watermark_scale || 15} ${c.compaction_proactiveness || 20}`
    );

    await fetchTelemetry();
    if (zres.stdout.includes("ZRAM_FAIL") || zres.stdout.includes("DISKSIZE_FAIL")) {
      log("ZRAM apply failed; check log or reduce size.");
    } else if (zres.stdout.includes("WB_UNSUPPORTED")) {
      log("Tunables saved (writeback unsupported by this kernel).");
    } else {
      log("Kernel tunables applied & persisted.");
    }
  })
);

// Display Manager
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
    withBusyButton(el.btnApplyDisplay, "Scaling...", async () => {
      const scale = appState.display.selectedScale;
      if (Math.abs(scale - 1.0) < 0.01) {
        await exec("wm size reset && wm density reset");
      } else {
        const targetW = Math.round(appState.display.physWidth * scale);
        const targetH = Math.round(appState.display.physHeight * scale);
        const targetDpi = Math.round(appState.display.physDpi * scale);
        await exec(`wm size ${targetW}x${targetH} && wm density ${targetDpi}`);
      }
      await fetchDisplayInfo();
      log(`Display scale applied (${Math.round(scale * 100)}%).`);
    })
  );
}

if (el.btnResetDisplay) {
  el.btnResetDisplay.addEventListener("click", () =>
    withBusyButton(el.btnResetDisplay, "Resetting...", async () => {
      await exec("wm size reset && wm density reset");
      if (el.groupDisplayScale) {
        el.groupDisplayScale.querySelectorAll(".pill-btn").forEach((b) => {
          b.classList.toggle("active", b.getAttribute("data-scale") === "1.0");
        });
      }
      appState.display.selectedScale = 1.0;
      await fetchDisplayInfo();
      log("Display reset to native 100%.");
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
