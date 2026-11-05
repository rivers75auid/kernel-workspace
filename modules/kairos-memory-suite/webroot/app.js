// Kairos Engine WebUI Client Controller
// Minimal, offline, anti-slop implementation.

const CONFIG_PATH = "/data/adb/kairos_config.json";

// Safe Root Bridge
function hasBridge() {
  return !!(window.ksu && window.ksu.exec);
}

// A command that never calls back must not freeze init or the poller.
function exec(cmd, timeoutMs = 8000) {
  return new Promise((resolve) => {
    if (!hasBridge()) {
      resolve({ errno: -1, stdout: "", stderr: "No KernelSU bridge detected" });
      return;
    }
    const cb = "cb_" + Math.random().toString(36).slice(2);
    const timer = setTimeout(() => {
      window[cb] = () => delete window[cb];
      resolve({ errno: -2, stdout: "", stderr: "timed out" });
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

// State
let appState = {
  config: {
    bypass_charging: false,
    auto_bypass_games: [],
    heavy_swap_apps: [],
    swappiness: 100,
    zram_size: "4000M",
    bg_limit: 32,
    thermal_guard: false,
    thermal_limit_c: 52,
    charge_limit: 100
  },
  display: {
    physWidth: 720,
    physHeight: 1650,
    physDpi: 268,
    currWidth: 720,
    currHeight: 1650,
    currDpi: 268,
    selectedScale: 1.0
  },
  installedPackages: [],
  filteredPackages: []
};

// UI Elements
const el = {
  tabBtns: document.querySelectorAll(".nav-btn"),
  tabPanes: document.querySelectorAll(".tab-pane"),
  headerTemp: document.getElementById("header-temp"),
  headerCharge: document.getElementById("header-charge"),
  headerBatt: document.getElementById("header-batt"),
  footerLog: document.getElementById("footer-log"),

  // Telemetry
  memFree: document.getElementById("val-mem-free"),
  memAvail: document.getElementById("val-mem-avail"),
  zramUsed: document.getElementById("val-zram-used"),
  zramPhys: document.getElementById("val-zram-phys"),
  zramRatio: document.getElementById("val-zram-ratio"),
  zramTotal: document.getElementById("val-zram-total"),
  swapPct: document.getElementById("val-swap-pct"),
  barSwap: document.getElementById("bar-swap"),
  btnRefresh: document.getElementById("btn-refresh"),
  btnCompact: document.getElementById("btn-compact"),
  btnTrim: document.getElementById("btn-trim"),

  // Power
  pwrStatus: document.getElementById("val-pwr-status"),
  pwrType: document.getElementById("val-pwr-type"),
  pwrCurrent: document.getElementById("val-pwr-current"),
  pwrVoltage: document.getElementById("val-pwr-voltage"),
  chkBypassMaster: document.getElementById("chk-bypass-master"),
  chkThermalGuard: document.getElementById("chk-thermal-guard"),
  groupChargeLimit: document.getElementById("group-charge-limit"),

  // Apps
  appSearch: document.getElementById("app-search"),
  appListContainer: document.getElementById("app-list-container"),
  btnSaveApps: document.getElementById("btn-save-apps"),

  // Tunables
  groupSwappiness: document.getElementById("group-swappiness"),
  groupZramSize: document.getElementById("group-zram-size"),
  groupBgLimit: document.getElementById("group-bg-limit"),
  btnApplyTunables: document.getElementById("btn-apply-tunables"),

  // Display
  valDisplayRes: document.getElementById("val-display-res"),
  valDisplayDpi: document.getElementById("val-display-dpi"),
  groupDisplayScale: document.getElementById("group-display-scale"),
  btnApplyDisplay: document.getElementById("btn-apply-display"),
  btnResetDisplay: document.getElementById("btn-reset-display")
};

function log(msg) {
  if (el.footerLog) el.footerLog.textContent = msg;
}

// Navigation Router
el.tabBtns.forEach((btn) => {
  btn.addEventListener("click", () => {
    const tabId = btn.getAttribute("data-tab");
    el.tabBtns.forEach((b) => b.classList.remove("active"));
    el.tabPanes.forEach((p) => p.classList.remove("active"));
    btn.classList.add("active");
    const target = document.getElementById("tab-" + tabId);
    if (target) target.classList.add("active");

    if (tabId === "apps" && appState.installedPackages.length === 0) {
      loadPackages();
    }
  });
});

// Telemetry Poller
async function fetchTelemetry() {
  const cmd = `
    cat /proc/meminfo | grep -E "MemFree|MemAvailable|SwapTotal|SwapFree";
    echo "---";
    cat /sys/block/zram0/mm_stat 2>/dev/null;
    echo "---";
    cat /sys/class/power_supply/battery/temp 2>/dev/null;
    cat /sys/class/power_supply/battery/current_now 2>/dev/null;
    cat /sys/class/power_supply/battery/voltage_now 2>/dev/null;
    cat /sys/class/power_supply/battery/status 2>/dev/null;
    cat /sys/class/power_supply/usb/real_type 2>/dev/null;
    echo "CE=$(cat /sys/class/power_supply/battery/charging_enabled 2>/dev/null)";
    echo "IS=$(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null)";
    echo "CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)";
  `;
  const res = await exec(cmd);
  if (res.errno !== 0) {
    log("Telemetry fetch failed: " + res.stderr);
    return;
  }

  const sections = res.stdout.split("---");
  if (sections.length < 3) return;

  // 1. Memory info
  const memLines = sections[0].trim().split("\n");
  const memData = {};
  memLines.forEach((l) => {
    const p = l.split(":");
    if (p.length === 2) memData[p[0].trim()] = parseInt(p[1].trim());
  });

  const memFreeMb = Math.round((memData["MemFree"] || 0) / 1024);
  const memAvailMb = Math.round((memData["MemAvailable"] || 0) / 1024);
  const swapTotalMb = Math.round((memData["SwapTotal"] || 0) / 1024);
  const swapFreeMb = Math.round((memData["SwapFree"] || 0) / 1024);

  // 2. mm_stat
  const mmTokens = sections[1].trim().split(/\s+/);
  let origSizeMb = 0;
  let compSizeMb = 0;
  let ratio = 1.0;

  if (mmTokens.length >= 3) {
    const origBytes = parseInt(mmTokens[0]) || 0;
    const compBytes = parseInt(mmTokens[1]) || 0;
    origSizeMb = Math.round(origBytes / 1048576);
    compSizeMb = Math.round(compBytes / 1048576);
    ratio = compBytes > 0 ? (origBytes / compBytes).toFixed(2) : "1.0";
  }

  // 3. Power
  const pwrLines = sections[2].trim().split("\n");
  const tempRaw = parseInt(pwrLines[0]) || 0;
  const currRaw = parseInt(pwrLines[1]) || 0;
  const voltRaw = parseInt(pwrLines[2]) || 0;
  const statusStr = (pwrLines[3] || "Unknown").trim();
  const typeStr = (pwrLines[4] || "USB").trim();
  const ceVal = (pwrLines.find(l => l.startsWith("CE=")) || "").slice(3).trim();
  const isVal = (pwrLines.find(l => l.startsWith("IS=")) || "").slice(3).trim();
  const capVal = (pwrLines.find(l => l.startsWith("CAP=")) || "").slice(4).trim();
  let chargeEnabled = true;
  let chargeNodeSupported = true;
  if (ceVal !== "") chargeEnabled = ceVal === "1";
  else if (isVal !== "") chargeEnabled = isVal === "0"; // input_suspend is inverted
  else chargeNodeSupported = false;

  const tempC = (tempRaw / 10).toFixed(1);
  const currentMa = Math.abs(Math.round(currRaw / 1000));
  const voltageV = (voltRaw / 1000000).toFixed(2);
  const watt = ((currentMa * parseFloat(voltageV)) / 1000).toFixed(1);

  // Render Telemetry
  el.memFree.textContent = memFreeMb + " MB";
  el.memAvail.textContent = memAvailMb + " MB";
  el.zramUsed.textContent = origSizeMb + " MB";
  el.zramPhys.textContent = compSizeMb + " MB";
  el.zramRatio.textContent = ratio + " x";
  el.zramTotal.textContent = swapTotalMb + " MB";

  const swapPct = swapTotalMb > 0 ? Math.round((origSizeMb / swapTotalMb) * 100) : 0;
  const boundedPct = Math.min(100, Math.max(0, swapPct));
  el.swapPct.textContent = boundedPct + "%";
  el.barSwap.style.width = boundedPct + "%";
  if (boundedPct > 85) {
    el.barSwap.style.backgroundColor = "var(--status-err)";
  } else if (boundedPct > 65) {
    el.barSwap.style.backgroundColor = "var(--status-warn)";
  } else {
    el.barSwap.style.backgroundColor = "var(--accent-blue)";
  }

  // Render Power
  // Checkbox shows the user's manual choice; State shows what the node is actually doing.
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

  log(`Live: Temp ${tempC}°C | Net ${watt}W | Swap ${boundedPct}%` + (chargeNodeSupported ? "" : " | Charging control unsupported"));
}

// Quick Actions
el.btnRefresh.addEventListener("click", fetchTelemetry);

el.btnCompact.addEventListener("click", async () => {
  log("Running ZRAM compaction...");
  await exec("echo 1 > /sys/block/zram0/compact");
  await fetchTelemetry();
  log("ZRAM compaction complete.");
});

el.btnTrim.addEventListener("click", async () => {
  log("Trimming inactive background apps...");
  await exec("am kill-all");
  await fetchTelemetry();
  log("Inactive applications trimmed.");
});

// Master Bypass Toggle (node-aware: charging_enabled vs input_suspend)
el.chkBypassMaster.addEventListener("change", async (e) => {
  const bypass = e.target.checked;
  const probe = await exec(
    "if [ -e /sys/class/power_supply/battery/charging_enabled ]; then echo charging_enabled;" +
    "elif [ -e /sys/class/power_supply/battery/input_suspend ]; then echo input_suspend;" +
    "else echo none; fi"
  );
  const node = probe.stdout.trim();
  if (node === "none") {
    log("Charging control unsupported by this kernel, nothing to toggle.");
    e.target.checked = false;
    return;
  }
  const val = node === "charging_enabled" ? (bypass ? "0" : "1") : (bypass ? "1" : "0");
  log(`Toggling charging via ${node}...`);
  await exec(`echo ${val} > /sys/class/power_supply/battery/${node}`);
  appState.config.bypass_charging = bypass;
  saveConfig();
  await fetchTelemetry();
});

// Thermal Guard Toggle
el.chkThermalGuard.addEventListener("change", async (e) => {
  appState.config.thermal_guard = e.target.checked;
  await saveConfig();
  log("Thermal guard " + (e.target.checked ? "enabled" : "disabled") + ".");
});

// App Manager
async function loadPackages() {
  log("Scanning installed user packages...");
  const res = await exec("pm list packages -3 | cut -d: -f2 | sort");
  if (res.errno === 0) {
    appState.installedPackages = res.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
    renderAppList();
    log(`Loaded ${appState.installedPackages.length} packages.`);
  } else {
    log("Failed loading packages: " + res.stderr);
  }
}

function renderAppList() {
  const query = (el.appSearch.value || "").toLowerCase().trim();
  const list = appState.installedPackages.filter((pkg) => pkg.toLowerCase().includes(query));

  if (list.length === 0) {
    el.appListContainer.innerHTML = '<div class="empty-state">No packages match this filter. Adjust the search or save current rules.</div>';
    return;
  }

  let html = "";
  list.forEach((pkg) => {
    const isGame = (appState.config.auto_bypass_games || []).includes(pkg);
    const isSwap = (appState.config.heavy_swap_apps || []).includes(pkg);

    html += `
      <div class="app-row" data-pkg="${pkg}">
        <div class="app-meta">
          <span class="app-pkg">${pkg}</span>
        </div>
        <div class="app-tags">
          <button class="tag-btn ${isGame ? "active-game" : ""}" data-action="toggle-game" data-pkg="${pkg}">
            ${isGame ? "Game on" : "Game"}
          </button>
          <button class="tag-btn ${isSwap ? "active-swap" : ""}" data-action="toggle-swap" data-pkg="${pkg}">
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

  if (action === "toggle-game") {
    const idx = appState.config.auto_bypass_games.indexOf(pkg);
    if (idx >= 0) {
      appState.config.auto_bypass_games.splice(idx, 1);
    } else {
      appState.config.auto_bypass_games.push(pkg);
    }
  } else if (action === "toggle-swap") {
    const idx = appState.config.heavy_swap_apps.indexOf(pkg);
    if (idx >= 0) {
      appState.config.heavy_swap_apps.splice(idx, 1);
    } else {
      appState.config.heavy_swap_apps.push(pkg);
    }
  }
  renderAppList();
});

el.btnSaveApps.addEventListener("click", async () => {
  await saveConfig();
  log("App priority rules saved to /data/adb/kairos_config.json");
});

// Config Persistence
async function loadConfig() {
  const res = await exec(`cat ${CONFIG_PATH} 2>/dev/null`);
  if (res.errno === 0 && res.stdout.trim()) {
    try {
      appState.config = Object.assign({}, appState.config, JSON.parse(res.stdout));
    } catch (_) {}
  }
  syncTunablesUI();
}

async function saveConfig() {
  const jsonStr = JSON.stringify(appState.config, null, 2);
  const cmd = `cat << 'EOF' > ${CONFIG_PATH}\n${jsonStr}\nEOF\nchmod 644 ${CONFIG_PATH}`;
  await exec(cmd);
}

// Tunables Controller
function setupPillGroup(groupEl, configKey) {
  groupEl.addEventListener("click", (e) => {
    const btn = e.target.closest(".pill-btn");
    if (!btn) return;
    groupEl.querySelectorAll(".pill-btn").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    const val = btn.getAttribute("data-val");
    appState.config[configKey] = isNaN(Number(val)) ? val : Number(val);
  });
}

setupPillGroup(el.groupSwappiness, "swappiness");
setupPillGroup(el.groupZramSize, "zram_size");
setupPillGroup(el.groupBgLimit, "bg_limit");
if (el.groupChargeLimit) {
  setupPillGroup(el.groupChargeLimit, "charge_limit");
  // No Apply button on the Status tab, so persist immediately; service.sh picks it up within 4s.
  el.groupChargeLimit.addEventListener("click", async (e) => {
    if (!e.target.closest(".pill-btn")) return;
    await saveConfig();
    log(`Charge limit set to ${appState.config.charge_limit}%.`);
  });
}

function syncTunablesUI() {
  const selectPill = (groupEl, val) => {
    if (!groupEl) return;
    groupEl.querySelectorAll(".pill-btn").forEach((b) => {
      if (b.getAttribute("data-val") == String(val)) {
        b.classList.add("active");
      } else {
        b.classList.remove("active");
      }
    });
  };
  selectPill(el.groupSwappiness, appState.config.swappiness);
  selectPill(el.groupZramSize, appState.config.zram_size);
  selectPill(el.groupBgLimit, appState.config.bg_limit);
  selectPill(el.groupChargeLimit, appState.config.charge_limit || 100);
  if (el.chkThermalGuard) el.chkThermalGuard.checked = appState.config.thermal_guard === true;
}

el.btnApplyTunables.addEventListener("click", async () => {
  log("Applying kernel tunables...");
  await saveConfig();

  // 1. Swappiness
  const sw = appState.config.swappiness || 100;
  await exec(`chmod 666 /proc/sys/vm/swappiness 2>/dev/null; echo ${sw} > /proc/sys/vm/swappiness; chmod 444 /proc/sys/vm/swappiness 2>/dev/null`);

  // 2. LMKD bg apps limit
  const limit = appState.config.bg_limit || 32;
  await exec(`resetprop ro.sys.fw.bg_apps_limit ${limit}; device_config put activity_manager max_cached_processes ${limit}`);

  // 3. ZRAM disk size if changed
  const zsize = appState.config.zram_size || "4000M";
  const currDisk = (await exec("cat /sys/block/zram0/disksize")).stdout.trim();
  const targetBytes = zsize.includes("M") ? parseInt(zsize) * 1048576 : parseInt(zsize);

  if (Math.abs(parseInt(currDisk) - targetBytes) > 50000000) {
    log(`Resizing ZRAM to ${zsize}...`);
    const r = await exec(
      `swapoff /dev/block/zram0 2>/dev/null; ` +
      `echo ${zsize} > /sys/block/zram0/disksize 2>/dev/null || ` +
      `{ echo 1 > /sys/block/zram0/reset && echo ${zsize} > /sys/block/zram0/disksize; }; ` +
      `mkswap /dev/block/zram0 2>/dev/null && swapon /dev/block/zram0 -p -2 2>/dev/null; ` +
      `grep -q zram0 /proc/swaps && echo ZRAM_OK || echo ZRAM_FAIL`
    );
    if ((r.stdout || "").includes("ZRAM_FAIL")) {
      log("ZRAM resize FAILED, swap is OFF. Fix size or reboot.");
      return;
    }
  }

  await fetchTelemetry();
  log("Kernel memory tunables applied successfully.");
});

// Display Manager
async function fetchDisplayInfo() {
  const sizeRes = await exec("wm size");
  const densRes = await exec("wm density");

  let physW = 720, physH = 1650, currW = 720, currH = 1650;
  let physDpi = 268, currDpi = 268;

  const physSizeMatch = sizeRes.stdout.match(/Physical size:\s*(\d+)x(\d+)/i);
  if (physSizeMatch) {
    physW = parseInt(physSizeMatch[1]);
    physH = parseInt(physSizeMatch[2]);
  }
  const overSizeMatch = sizeRes.stdout.match(/Override size:\s*(\d+)x(\d+)/i);
  if (overSizeMatch) {
    currW = parseInt(overSizeMatch[1]);
    currH = parseInt(overSizeMatch[2]);
  } else {
    currW = physW;
    currH = physH;
  }

  const physDensMatch = densRes.stdout.match(/Physical density:\s*(\d+)/i);
  if (physDensMatch) {
    physDpi = parseInt(physDensMatch[1]);
  }
  const overDensMatch = densRes.stdout.match(/Override density:\s*(\d+)/i);
  if (overDensMatch) {
    currDpi = parseInt(overDensMatch[1]);
  } else {
    currDpi = physDpi;
  }

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
  el.btnApplyDisplay.addEventListener("click", async () => {
    const scale = appState.display.selectedScale;
    log(`Applying display scale ${scale * 100}%...`);
    if (Math.abs(scale - 1.0) < 0.01) {
      await exec("wm size reset && wm density reset");
    } else {
      const targetW = Math.round(appState.display.physWidth * scale);
      const targetH = Math.round(appState.display.physHeight * scale);
      const targetDpi = Math.round(appState.display.physDpi * scale);
      await exec(`wm size ${targetW}x${targetH} && wm density ${targetDpi}`);
    }
    await fetchDisplayInfo();
    log("Display resolution scaled successfully.");
  });
}

if (el.btnResetDisplay) {
  el.btnResetDisplay.addEventListener("click", async () => {
    log("Resetting display to native resolution...");
    await exec("wm size reset && wm density reset");
    if (el.groupDisplayScale) {
      el.groupDisplayScale.querySelectorAll(".pill-btn").forEach((b) => {
        b.classList.toggle("active", b.getAttribute("data-scale") === "1.0");
      });
    }
    appState.display.selectedScale = 1.0;
    await fetchDisplayInfo();
    log("Display reset to native 100%.");
  });
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
    log("KernelSU bridge not found. Open this page from the KernelSU manager.");
    return;
  }
  await loadConfig();
  await pollTelemetry();
  fetchDisplayInfo();
  setInterval(pollTelemetry, 3500);
}

window.addEventListener("DOMContentLoaded", init);
