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
    published: publishedPorts((c && c.Ports) || ""),
    project: String(labels["com.docker.compose.project"] || ""),
    service: String(labels["com.docker.compose.service"] || ""),
    workingDir: String(labels["com.docker.compose.project.working_dir"] || ""),
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

// Drop trailing zeros of a decimal ("12.30" -> "12.3", "5.00" -> "5") but
// leave integers alone ("100" stays "100").
function trimZeros(text) {
  var t = String(text)
  return t.indexOf(".") === -1 ? t : t.replace(/0+$/, "").replace(/\.$/, "")
}

function formatPercent(n) {
  if (n < 0) return "–"
  if (n >= 100) return Math.round(n) + "%"
  return trimZeros(n >= 10 ? n.toFixed(1) : n.toFixed(2)) + "%"
}

// "20.72MiB" -> "20.7M", "1.234GiB" -> "1.23G", "512KiB" -> "512K"
function shortBytes(text) {
  var m = /^([\d.]+)\s*([KMGT]?i?B)$/i.exec(String(text || "").trim())
  if (!m) return String(text || "")
  var n = parseFloat(m[1])
  var unit = m[2].charAt(0).toUpperCase()
  if (unit === "B") return Math.round(n) + "B"
  return trimZeros(n >= 100 ? Math.round(n) : n >= 10 ? n.toFixed(1) : n.toFixed(2)) + unit
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

// Host-side published ports, deduplicated: [{host: "8080", container: "80", proto: "tcp"}].
// Unpublished exposures ("5432/tcp") are left out — nothing to open there.
function publishedPorts(text) {
  var seen = {}
  var out = []
  var parts = String(text || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var m = /:(\d+)->(\d+)\/(\w+)/.exec(parts[i].trim())
    if (!m || seen[m[1]]) continue
    seen[m[1]] = true
    out.push({ host: m[1], container: m[2], proto: m[3].toLowerCase() })
  }
  out.sort(function(a, b) { return parseInt(a.host, 10) - parseInt(b.host, 10) })
  return out
}

// Where a published port is reachable from this machine: the ssh hostname for
// remote contexts, the tcp host for tcp:// ones, localhost otherwise.
function hostAddress(endpoint) {
  var e = String(endpoint || "")
  var m = /^(?:ssh|tcp|https?):\/\/(?:[^@\/]+@)?([^:\/]+)/i.exec(e)
  return m ? m[1] : "localhost"
}

function portUrl(endpoint, port) {
  if (!port) return ""
  var scheme = String(port.container) === "443" || String(port.host) === "443" ? "https" : "http"
  return scheme + "://" + hostAddress(endpoint) + ":" + port.host
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

var SORT_MODES = ["State", "Name", "CPU", "Memory"]

function nextSortMode(mode) {
  var i = SORT_MODES.indexOf(String(mode || "State"))
  return SORT_MODES[(i + 1) % SORT_MODES.length]
}

// "20.7MiB" -> bytes, for sorting. Unknown -> -1 so stat-less rows sink.
function memBytes(text) {
  var m = /^([\d.]+)\s*([KMGT]?)i?B$/i.exec(String(text || "").trim())
  if (!m) return -1
  var mult = { "": 1, K: 1024, M: 1048576, G: 1073741824, T: 1099511627776 }[m[2].toUpperCase()]
  return parseFloat(m[1]) * mult
}

// Stable sort by the chosen mode; CPU and Memory put the hungriest first and
// fall back to the state order for containers without stats.
function sortContainers(containers, mode) {
  var list = (containers || []).slice()
  var by = String(mode || "State")
  list.sort(function(a, b) {
    if (by === "Name") return a.name.localeCompare(b.name)
    if (by === "CPU" || by === "Memory") {
      var va = a.stats ? (by === "CPU" ? a.stats.cpu : memBytes(a.stats.memUsed)) : -1
      var vb = b.stats ? (by === "CPU" ? b.stats.cpu : memBytes(b.stats.memUsed)) : -1
      if (va !== vb) return vb - va
    }
    return compareContainers(a, b)
  })
  return list
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

// ---- search -----------------------------------------------------------------

// Case-insensitive substring match over the fields a person would type:
// name, image, compose project/service, state and the status line. Every
// whitespace-separated word must match somewhere.
function matchesQuery(container, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return true
  if (!container) return false
  var hay = [container.name, container.image, container.project, container.service, container.state, container.status, container.ports]
    .join(" ").toLowerCase()
  var words = q.split(/\s+/)
  for (var i = 0; i < words.length; i++) if (hay.indexOf(words[i]) === -1) return false
  return true
}

function filterContainers(containers, query) {
  var out = []
  for (var i = 0; i < (containers || []).length; i++) if (matchesQuery(containers[i], query)) out.push(containers[i])
  return out
}

// ---- compose groups ---------------------------------------------------------

// Split a host's containers into compose projects, keeping the containers'
// existing order inside each group. Projects come first (alphabetical), then
// one trailing group with project "" for standalone containers. With
// grouping off the whole list is returned as that single anonymous group.
function groupContainers(containers, enabled) {
  var list = containers || []
  if (!enabled) return [{ project: "", containers: list, counts: countContainers(list), workingDir: "" }]
  var byProject = {}
  var order = []
  var standalone = []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (!c.project) { standalone.push(c); continue }
    if (!byProject[c.project]) { byProject[c.project] = []; order.push(c.project) }
    byProject[c.project].push(c)
  }
  order.sort(function(a, b) { return a.localeCompare(b) })
  var groups = []
  for (var g = 0; g < order.length; g++) {
    var members = byProject[order[g]]
    groups.push({ project: order[g], containers: members, counts: countContainers(members), workingDir: firstWorkingDir(members) })
  }
  if (standalone.length > 0) groups.push({ project: "", containers: standalone, counts: countContainers(standalone), workingDir: "" })
  return groups
}

function firstWorkingDir(containers) {
  for (var i = 0; i < containers.length; i++) if (containers[i].workingDir) return containers[i].workingDir
  return ""
}

function groupKey(hostName, project) {
  return String(hostName) + "//" + String(project)
}

// "3/4 running" style summary for a group header.
function groupSummary(group) {
  if (!group) return ""
  var c = group.counts
  var text = c.running + "/" + c.total + " running"
  if (c.unhealthy > 0) text += " · " + c.unhealthy + " unhealthy"
  return text
}

// ---- ssh helpers ------------------------------------------------------------

// ssh://[user@]host[:port] -> ["ssh", "-p", port, "-l", user, host]. Mirrors
// bin/dockarchy-status so terminal actions on remote hosts reuse the user's
// ~/.ssh/config (ControlMaster and friends) instead of docker's own transport.
function sshArgv(endpoint) {
  var m = /^ssh:\/\/(?:([^@\/]+)@)?([^:\/]+)(?::(\d+))?/i.exec(String(endpoint || ""))
  if (!m) return null
  var argv = ["ssh"]
  if (m[3]) argv.push("-p", m[3])
  if (m[1]) argv.push("-l", m[1])
  argv.push("--", m[2])
  return argv
}

// Shell-quote for embedding in a remote `ssh host <command>` string.
function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// ---- stats history (sparklines) --------------------------------------------

var HISTORY_LENGTH = 20

// Metrics a sparkline can follow. `key` is the series name in a history
// entry, `ceiling` pins the chart top (0 = the series' own peak), `rate`
// marks cumulative counters that are turned into per-second deltas.
var METRICS = {
  CPU:     { key: "cpu",  glyph: "󰘚", ceiling: 100, rate: false },
  Memory:  { key: "mem",  glyph: "󰍛", ceiling: 0,   rate: false },
  Network: { key: "net",  glyph: "󰛳", ceiling: 0,   rate: true },
  Disk:    { key: "disk", glyph: "󰋊", ceiling: 0,   rate: true },
  PIDs:    { key: "pids", glyph: "󰓹", ceiling: 0,   rate: false }
}
var METRIC_NAMES = ["CPU", "Memory", "Network", "Disk", "PIDs"]

// docker's I/O counters use SI units ("2.61kB", "1.2MB", "3GB"); memory uses
// binary ones ("20.7MiB"). Accept both, and "12B".
function ioBytes(text) {
  var m = /^([\d.]+)\s*([kKMGT]?)(i?)B$/.exec(String(text || "").trim())
  if (!m) return -1
  var order = { "": 0, K: 1, M: 2, G: 3, T: 4 }[m[2].toUpperCase()]
  return parseFloat(m[1]) * Math.pow(m[3] ? 1024 : 1000, order)
}

// "1.2kB / 3.4MB" -> total bytes both ways, or -1.
function ioTotal(text) {
  var parts = String(text || "").split("/")
  if (parts.length !== 2) return -1
  var a = ioBytes(parts[0]), b = ioBytes(parts[1])
  return a < 0 || b < 0 ? -1 : a + b
}

function emptySeries() {
  return { cpu: [], mem: [], net: [], disk: [], pids: [], lastNet: -1, lastDisk: -1, lastAt: -1 }
}

function pushCapped(list, value, max) {
  list.push(value)
  while (list.length > max) list.shift()
}

// Append this poll's samples for every running container with stats, drop
// containers that vanished, cap each series at `maxLen`. Network and disk
// are cumulative counters in `docker stats`, so they are stored as bytes per
// second since the previous poll. Returns a new map ("host/id" -> series) so
// QML bindings see the change.
function pushHistory(history, hosts, maxLen, nowMs) {
  var cap = maxLen > 1 ? maxLen : HISTORY_LENGTH
  var now = typeof nowMs === "number" && isFinite(nowMs) ? nowMs : Date.now()
  var next = {}
  var prev = history || {}
  for (var h = 0; h < (hosts || []).length; h++) {
    var host = hosts[h]
    for (var c = 0; c < host.containers.length; c++) {
      var k = host.containers[c]
      var key = host.name + "/" + k.id
      var series = emptySeries()
      if (prev[key]) {
        for (var f in series) series[f] = prev[key][f] instanceof Array ? prev[key][f].slice() : prev[key][f]
      }
      if (k.running && k.stats) {
        pushCapped(series.cpu, k.stats.cpu < 0 ? 0 : k.stats.cpu, cap)
        pushCapped(series.mem, Math.max(0, memBytes(k.stats.memUsed)), cap)
        pushCapped(series.pids, k.stats.pids, cap)
        var net = ioTotal(k.stats.netIO), disk = ioTotal(k.stats.blockIO)
        var dt = series.lastAt >= 0 ? (now - series.lastAt) / 1000 : 0
        if (dt > 0) {
          pushCapped(series.net, net >= 0 && series.lastNet >= 0 ? Math.max(0, (net - series.lastNet) / dt) : 0, cap)
          pushCapped(series.disk, disk >= 0 && series.lastDisk >= 0 ? Math.max(0, (disk - series.lastDisk) / dt) : 0, cap)
        }
        series.lastNet = net
        series.lastDisk = disk
        series.lastAt = now
      } else if (!k.running) {
        // A stopped container starts a fresh line when it comes back.
        series = emptySeries()
      }
      next[key] = series
    }
  }
  return next
}

// Normalised points for a sparkline: [{x: 0..1, y: 0..1}] with y = 1 at the
// series maximum (or at `ceiling` when higher, so CPU never flatlines at 3%).
// `slots` is how many samples fill the width; the newest sits at x = 1.
function sparkPoints(series, ceiling, slots) {
  var values = series || []
  if (values.length === 0) return []
  var max = ceiling || 0
  for (var i = 0; i < values.length; i++) if (values[i] > max) max = values[i]
  if (max <= 0) max = 1
  var n = Math.max(values.length, slots || HISTORY_LENGTH, 2)
  var out = []
  for (var j = 0; j < values.length; j++) {
    out.push({ x: (n - values.length + j) / (n - 1), y: values[j] / max })
  }
  return out
}

function seriesStats(series) {
  var values = series || []
  if (values.length === 0) return null
  var min = values[0], max = values[0], sum = 0
  for (var i = 0; i < values.length; i++) {
    if (values[i] < min) min = values[i]
    if (values[i] > max) max = values[i]
    sum += values[i]
  }
  return { min: min, max: max, avg: sum / values.length, count: values.length }
}

function bytesText(n) {
  if (!(n >= 0)) return "–"
  var units = ["B", "K", "M", "G", "T"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  return trimZeros(n >= 100 || i === 0 ? Math.round(n) : n >= 10 ? n.toFixed(1) : n.toFixed(2)) + units[i]
}

function rateText(n) {
  return n >= 0 ? bytesText(n) + "/s" : "–"
}

function metricValueText(name, value) {
  if (name === "CPU") return formatPercent(value)
  if (name === "Memory") return bytesText(value)
  if (name === "Network" || name === "Disk") return rateText(value)
  return value >= 0 ? String(Math.round(value)) : "–"
}

// Current reading for a metric: from the stats row for instantaneous ones,
// from the newest history sample for rates.
function metricCurrent(name, container, series) {
  if (!container || !container.stats) return -1
  if (name === "CPU") return container.stats.cpu
  if (name === "Memory") return memBytes(container.stats.memUsed)
  if (name === "PIDs") return container.stats.pids
  var list = series ? series[METRICS[name].key] : null
  return list && list.length > 0 ? list[list.length - 1] : -1
}

// Compact metric line, e.g. "󰘚 0.4%" or "󰛳 12K/s".
function metricLabel(name, container, series) {
  var m = METRICS[name]
  if (!m) return ""
  return m.glyph + " " + metricValueText(name, metricCurrent(name, container, series))
}

function windowText(count, intervalSec) {
  var secs = Math.max(0, count - 1) * (intervalSec || 0)
  if (secs <= 0) return count + " polls"
  var span = secs >= 3600 ? (secs / 3600).toFixed(1).replace(/\.0$/, "") + " h" : secs >= 60 ? Math.round(secs / 60) + " min" : Math.round(secs) + " s"
  return count + " polls · " + span
}

function historyTooltip(series, names, intervalSec) {
  if (!series) return ""
  var lines = []
  var count = 0
  var list = names && names.length ? names : ["CPU", "Memory"]
  for (var i = 0; i < list.length; i++) {
    var m = METRICS[list[i]]
    if (!m) continue
    var st = seriesStats(series[m.key])
    if (!st) continue
    count = Math.max(count, st.count)
    var pad = (list[i] + "      ").substring(0, 8)
    lines.push(pad + "min " + metricValueText(list[i], st.min) + " · avg " + metricValueText(list[i], st.avg) + " · max " + metricValueText(list[i], st.max))
  }
  if (lines.length === 0) return ""
  return "Last " + windowText(count, intervalSec) + "\n" + lines.join("\n")
}

// ---- change detection (notifications) ---------------------------------------

// Snapshot the bits of state worth alerting on, keyed so two polls can be
// diffed without caring about ordering.
function snapshot(hosts) {
  var snap = { hosts: {}, containers: {} }
  for (var h = 0; h < (hosts || []).length; h++) {
    var host = hosts[h]
    snap.hosts[host.name] = { ok: host.ok, error: host.error }
    for (var c = 0; c < host.containers.length; c++) {
      var k = host.containers[c]
      snap.containers[host.name + "/" + k.id] = {
        host: host.name, name: k.name, state: k.state, health: k.health, status: k.status, running: k.running
      }
    }
  }
  return snap
}

// Events between two snapshots. `touched` maps "host/id" keys to the verb the
// user just ran on that container (start/stop/restart/…), so the transition
// they asked for is not reported — while anything else still is: a container
// that dies right after the user started it is exactly what to shout about.
var STOP_VERBS = { stop: true, restart: true, pause: true, kill: true }
var START_VERBS = { start: true, restart: true, unpause: true }

function diffSnapshots(prev, next, touched) {
  var events = []
  if (!prev || !next) return events
  var verbs = touched || {}
  for (var name in next.hosts) {
    var was = prev.hosts[name]
    var now = next.hosts[name]
    if (!was) continue
    if (was.ok && !now.ok) events.push({ kind: "problem", type: "host-down", host: name, title: name + " unreachable", body: shortError(now.error) })
    else if (!was.ok && now.ok) events.push({ kind: "recovery", type: "host-up", host: name, title: name + " is back", body: "Host answers again" })
  }
  for (var key in next.containers) {
    var before = prev.containers[key]
    var after = next.containers[key]
    if (!before) continue
    var label = after.host === "default" ? after.name : after.name + " @ " + after.host
    if (before.health !== "unhealthy" && after.health === "unhealthy")
      events.push({ kind: "problem", type: "unhealthy", key: key, host: after.host, title: label + " is unhealthy", body: after.status })
    else if (before.health === "unhealthy" && after.health === "healthy")
      events.push({ kind: "recovery", type: "healthy", key: key, host: after.host, title: label + " is healthy again", body: after.status })
    if (before.running && !after.running && after.state !== "paused" && !STOP_VERBS[verbs[key]])
      events.push({ kind: "problem", type: "stopped", key: key, host: after.host, title: label + " stopped", body: after.status })
    else if (!before.running && after.running && before.state !== "paused" && before.state !== "created" && !START_VERBS[verbs[key]])
      events.push({ kind: "recovery", type: "started", key: key, host: after.host, title: label + " is running again", body: after.status })
  }
  return events
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
    stateGlyph: stateGlyph, hostGlyph: hostGlyph, errorHint: errorHint, shortError: shortError,
    formatBar: formatBar, normalizeStats: normalizeStats, formatPercent: formatPercent, shortBytes: shortBytes, statsTooltip: statsTooltip,
    publishedPorts: publishedPorts, hostAddress: hostAddress, portUrl: portUrl,
    sortContainers: sortContainers, nextSortMode: nextSortMode, memBytes: memBytes, SORT_MODES: SORT_MODES,
    pushHistory: pushHistory, sparkPoints: sparkPoints, seriesStats: seriesStats, bytesText: bytesText, historyTooltip: historyTooltip, HISTORY_LENGTH: HISTORY_LENGTH,
    METRICS: METRICS, METRIC_NAMES: METRIC_NAMES, ioBytes: ioBytes, ioTotal: ioTotal, rateText: rateText, metricValueText: metricValueText,
    metricCurrent: metricCurrent, metricLabel: metricLabel, windowText: windowText,
    matchesQuery: matchesQuery, filterContainers: filterContainers, groupContainers: groupContainers, groupKey: groupKey, groupSummary: groupSummary,
    sshArgv: sshArgv, shellQuote: shellQuote, snapshot: snapshot, diffSnapshots: diffSnapshots
  }
}
