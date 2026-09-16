.pragma library

// Pure data helpers for the Dockarchy panel. No Qt imports so the whole file
// can be exercised from node/qjs: `node -e 'require("./Model.js")'` style
// checks in the README.

var STATE_ORDER = {
  running: 0,
  restarting: 1,
  paused: 2,
  created: 3,
  exited: 4,
  dead: 5,
  removing: 6
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "Empty status output" }
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "Invalid status JSON: " + e }
  }
  if (!data || typeof data !== "object") return { ok: false, error: "Unexpected status shape" }
  if (data.installed === false) return { ok: true, installed: false, hosts: [], counts: emptyCounts() }

  var hosts = []
  var list = data.hosts && typeof data.hosts.length === "number" ? data.hosts : []
  for (var i = 0; i < list.length; i++) hosts.push(normalizeHost(list[i]))
  return { ok: true, installed: true, hosts: hosts, counts: countHosts(hosts) }
}

function normalizeHost(host) {
  var containers = []
  var raw = host && host.containers && typeof host.containers.length === "number" ? host.containers : []
  for (var i = 0; i < raw.length; i++) containers.push(normalizeContainer(raw[i]))
  containers.sort(compareContainers)
  var name = String((host && host.name) || "default")
  return {
    id: name,
    name: name,
    endpoint: String((host && host.endpoint) || ""),
    remote: isRemoteEndpoint((host && host.endpoint) || ""),
    ok: !!(host && host.ok),
    error: String((host && host.error) || ""),
    containers: containers,
    counts: countContainers(containers)
  }
}

function normalizeContainer(c) {
  var state = String((c && c.State) || "").toLowerCase()
  var status = String((c && c.Status) || "")
  var name = String((c && c.Names) || "").split(",")[0].trim()
  var labels = parseLabels((c && c.Labels) || "")
  return {
    id: String((c && c.ID) || ""),
    shortId: String((c && c.ID) || "").substring(0, 12),
    name: name || String((c && c.ID) || "").substring(0, 12),
    image: String((c && c.Image) || ""),
    state: state,
    status: status,
    health: healthFromStatus(status),
    running: state === "running",
    ports: summarizePorts((c && c.Ports) || ""),
    project: String(labels["com.docker.compose.project"] || ""),
    service: String(labels["com.docker.compose.service"] || ""),
    createdAt: String((c && c.CreatedAt) || ""),
    stats: normalizeStats(c && c.Stats)
  }
}

// `docker stats` row -> compact numbers; null when the container was not
// running (or stats were not requested).
function normalizeStats(st) {
  if (!st || typeof st !== "object") return null
  var mem = String(st.MemUsage || "")
  var slash = mem.indexOf("/")
  return {
    cpu: parsePercent(st.CPUPerc),
    memPerc: parsePercent(st.MemPerc),
    memUsed: (slash >= 0 ? mem.substring(0, slash) : mem).trim(),
    memLimit: (slash >= 0 ? mem.substring(slash + 1) : "").trim(),
    netIO: String(st.NetIO || ""),
    blockIO: String(st.BlockIO || ""),
    pids: parseInt(String(st.PIDs || "0"), 10) || 0
  }
}

function parsePercent(text) {
  var n = parseFloat(String(text || "").replace("%", ""))
  return isFinite(n) ? n : -1
}

function formatPercent(n) {
  if (n < 0) return "–"
  if (n >= 100) return Math.round(n) + "%"
  return (n >= 10 ? n.toFixed(1) : n.toFixed(2)).replace(/\.?0+$/, "") + "%"
}

// "20.72MiB" -> "20.7M", "1.234GiB" -> "1.23G", "512KiB" -> "512K"
function shortBytes(text) {
  var m = /^([\d.]+)\s*([KMGT]?i?B)$/i.exec(String(text || "").trim())
  if (!m) return String(text || "")
  var n = parseFloat(m[1])
  var unit = m[2].charAt(0).toUpperCase()
  if (unit === "B") return Math.round(n) + "B"
  return (n >= 100 ? Math.round(n) : n >= 10 ? n.toFixed(1) : n.toFixed(2)).toString().replace(/\.?0+$/, "") + unit
}

function cpuText(container) {
  if (!container || !container.stats) return ""
  return formatPercent(container.stats.cpu)
}

function memText(container) {
  if (!container || !container.stats) return ""
  return shortBytes(container.stats.memUsed)
}

function statsTooltip(container) {
  if (!container || !container.stats) return ""
  var st = container.stats
  var lines = ["CPU " + formatPercent(st.cpu), "Memory " + st.memUsed + (st.memLimit ? " / " + st.memLimit : "") + " (" + formatPercent(st.memPerc) + ")"]
  if (st.netIO) lines.push("Net " + st.netIO)
  if (st.blockIO) lines.push("Disk " + st.blockIO)
  if (st.pids) lines.push("PIDs " + st.pids)
  return lines.join("\n")
}

// `docker ps` prints labels as "k=v,k=v". Values may contain "=" but not ",".
function parseLabels(text) {
  var out = {}
  var parts = String(text || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    var eq = part.indexOf("=")
    if (eq <= 0) continue
    out[part.substring(0, eq).trim()] = part.substring(eq + 1)
  }
  return out
}

// "Up 3 hours (healthy)" -> "healthy"; "Up 2 minutes (health: starting)" -> "starting"
function healthFromStatus(status) {
  var m = /\((healthy|unhealthy|health: starting)\)/i.exec(String(status || ""))
  if (!m) return ""
  var h = m[1].toLowerCase()
  return h === "health: starting" ? "starting" : h
}

// Collapse "0.0.0.0:18080->80/tcp, [::]:18080->80/tcp" to "18080->80".
function summarizePorts(text) {
  var seen = {}
  var out = []
  var parts = String(text || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i].trim()
    if (p === "") continue
    var m = /:(\d+)->(\d+)\//.exec(p)
    var label = m ? m[1] + "->" + m[2] : p.replace(/\/tcp$/, "")
    if (!seen[label]) {
      seen[label] = true
      out.push(label)
    }
  }
  return out.join(", ")
}

function isRemoteEndpoint(endpoint) {
  var e = String(endpoint || "")
  return /^(ssh|tcp|https?):\/\//i.test(e)
}

function compareContainers(a, b) {
  var sa = STATE_ORDER[a.state] === undefined ? 9 : STATE_ORDER[a.state]
  var sb = STATE_ORDER[b.state] === undefined ? 9 : STATE_ORDER[b.state]
  if (sa !== sb) return sa - sb
  return a.name.localeCompare(b.name)
}

function emptyCounts() {
  return { total: 0, running: 0, stopped: 0, unhealthy: 0, hosts: 0, unreachable: 0 }
}

function countContainers(containers) {
  var counts = emptyCounts()
  for (var i = 0; i < containers.length; i++) {
    var c = containers[i]
    counts.total++
    if (c.running) counts.running++
    else counts.stopped++
    if (c.health === "unhealthy" || c.state === "restarting" || c.state === "dead") counts.unhealthy++
  }
  return counts
}

function countHosts(hosts) {
  var counts = emptyCounts()
  for (var i = 0; i < hosts.length; i++) {
    var h = hosts[i]
    counts.hosts++
    if (!h.ok) counts.unreachable++
    counts.total += h.counts.total
    counts.running += h.counts.running
    counts.stopped += h.counts.stopped
    counts.unhealthy += h.counts.unhealthy
  }
  return counts
}

function stateGlyph(container) {
  if (!container) return "󰆧"
  if (container.health === "unhealthy" || container.state === "dead") return "󰀦"
  if (container.state === "restarting" || container.health === "starting") return "󰑐"
  if (container.state === "paused") return "󰏤"
  if (container.running) return "󰐊"
  return "󰓛"
}

function hostGlyph(host) {
  if (!host) return "󰒋"
  return host.remote ? "󰒋" : "󰌢"
}

// "3 running · 1 stopped · 2 hosts" for the hero line.
function summaryText(counts, installed) {
  if (installed === false) return "Docker CLI is not installed"
  if (!counts) return "Checking…"
  var parts = []
  parts.push(counts.running + " running")
  if (counts.stopped > 0) parts.push(counts.stopped + " stopped")
  if (counts.unhealthy > 0) parts.push(counts.unhealthy + " unhealthy")
  if (counts.hosts > 1 || counts.unreachable > 0) {
    var hostText = counts.hosts + (counts.hosts === 1 ? " host" : " hosts")
    if (counts.unreachable > 0) hostText += " (" + counts.unreachable + " unreachable)"
    parts.push(hostText)
  }
  return parts.join(" · ")
}

// Python-style template for the bar label: "{running}/{total}" etc. Unknown
// names are left in place so a typo is visible rather than silently blank;
// "{{" and "}}" produce literal braces.
function formatBar(template, counts) {
  var c = counts || emptyCounts()
  var values = {
    total: c.total, running: c.running, alive: c.running, up: c.running,
    stopped: c.stopped, down: c.stopped, exited: c.stopped,
    unhealthy: c.unhealthy, unreachable: c.unreachable,
    errors: c.unhealthy + c.unreachable, hosts: c.hosts
  }
  return String(template || "")
    .replace(/\{\{/g, "\u0001").replace(/\}\}/g, "\u0002")
    .replace(/\{\s*([a-zA-Z_]+)\s*\}/g, function(match, name) {
      var key = name.toLowerCase()
      return values.hasOwnProperty(key) ? String(values[key]) : match
    })
    .replace(/\u0001/g, "{").replace(/\u0002/g, "}")
    .trim()
}

// Short, human hint for common daemon errors; empty when nothing useful to add.
function errorHint(error) {
  var e = String(error || "")
  if (/permission denied/i.test(e)) return "Run `omarchy setup security sudoless-docker` (or add your user to the docker group) and log in again."
  if (/Cannot connect to the Docker daemon/i.test(e)) return "The daemon is not running on this host."
  if (/Timed out/i.test(e)) return "Host did not answer in time. Check SSH connectivity."
  if (/Permission denied \(publickey/i.test(e) || /Host key verification failed/i.test(e)) return "SSH refused the connection. Try `ssh` to this host once in a terminal."
  return ""
}

function shortError(error) {
  var e = String(error || "").replace(/\s+/g, " ").trim()
  // The docker CLI prefixes most failures with this noise.
  e = e.replace(/^Cannot connect to the Docker daemon at [^.]+\. /, "")
  e = e.replace(/^error during connect: /, "")
  e = e.replace(/^Failed to initialize: /, "")
  return e.length > 160 ? e.substring(0, 157) + "…" : e
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus, normalizeContainer: normalizeContainer, parseLabels: parseLabels,
    healthFromStatus: healthFromStatus, summarizePorts: summarizePorts, summaryText: summaryText,
    stateGlyph: stateGlyph, errorHint: errorHint, shortError: shortError,
    formatBar: formatBar, normalizeStats: normalizeStats, formatPercent: formatPercent, shortBytes: shortBytes, statsTooltip: statsTooltip
  }
}
