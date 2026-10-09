// Kairos Engine WebUI Client Controller
// Minimal, offline, anti-slop implementation.

const CONFIG_PATH = "/data/adb/kairos_config.json";

// Safe Root Bridge
function hasBridge() {
  return !!(window.ksu && window.ksu.exec);
}

function exec(cmd) {
  return new Promise((resolve) => {
    if (!hasBridge()) {
      resolve({ errno: -1, stdout: "", stderr: "No KernelSU bridge detected" });
      return;
    }
    const cb = "cb_" + Math.random().toString(36).slice(2);
    window[cb] = (errno, stdout, stderr) => {
      delete window[cb];
      resolve({ errno, stdout: stdout || "", stderr: stderr || "" });
    };
    try {
      window.ksu.exec(cmd, "{}", cb);
    } catch (err) {
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
    bg_limit: 32
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

  // Apps
  appSearch: document.getElementById("app-search"),
  appListContainer: document.getElementById("app-list-container"),
  btnSaveApps: document.getElementById("btn-save-apps"),

  // Tunables
  groupSwappiness: document.getElementById("group-swappiness"),
  groupZramSize: document.getElementById("group-zram-size"),
  groupBgLimit: document.getElementById("group-bg-limit"),
  btnApplyTunables: document.getElementById("btn-apply-tunables")
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
    cat /sys/class/power_supply/battery/charging_enabled 2>/dev/null;
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
  const chargeEnabled = (pwrLines[5] || "1").trim() === "1";

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
  el.pwrStatus.textContent = chargeEnabled ? statusStr : "Bypass Mode";
  el.pwrType.textContent = typeStr;
  el.pwrCurrent.textContent = (chargeEnabled ? "-" : "+") + currentMa + " mA";
  el.pwrVoltage.textContent = voltageV + " V";
  el.headerTemp.textContent = tempC + "°C";
  el.headerCharge.textContent = watt + "W";
  el.chkBypassMaster.checked = !chargeEnabled;

  log(`Live: Temp ${tempC}°C | Net ${watt}W | Swap ${boundedPct}%`);
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

// Master Bypass Toggle
el.chkBypassMaster.addEventListener("change", async (e) => {
  const bypass = e.target.checked;
  const val = bypass ? "0" : "1";
  log("Toggling charging hardware state...");
  await exec(`echo ${val} > /sys/class/power_supply/battery/charging_enabled`);
  appState.config.bypass_charging = bypass;
  saveConfig();
  await fetchTelemetry();
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
    el.appListContainer.innerHTML = '<div class="empty-state">No matching packages found.</div>';
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
            ${isGame ? "✓ Game Mode" : "Game Mode"}
          </button>
          <button class="tag-btn ${isSwap ? "active-swap" : ""}" data-action="toggle-swap" data-pkg="${pkg}">
            ${isSwap ? "✓ Aggressive Swap" : "Force Swap"}
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

function syncTunablesUI() {
  const selectPill = (groupEl, val) => {
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
    await exec(`swapoff /dev/block/zram0 && echo ${zsize} > /sys/block/zram0/disksize && mkswap /dev/block/zram0 && swapon /dev/block/zram0 -p -2`);
  }

  await fetchTelemetry();
  log("Kernel memory tunables applied successfully.");
});

// Boot Initializer
async function init() {
  await loadConfig();
  await fetchTelemetry();
  setInterval(fetchTelemetry, 3500);
}

window.addEventListener("DOMContentLoaded", init);
