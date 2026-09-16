import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Talks to the docker CLI. Every host — local socket or a remote daemon over
// ssh — is a docker *context*, so `docker --context <name>` is the only
// dispatch mechanism the plugin needs. Status polling is delegated to
// bin/dockarchy-status so many contexts can be queried in parallel by one
// process and land as a single JSON document.
Item {
  id: root

  property var settings: ({})

  property bool installed: true
  property bool refreshing: false
  property bool everRefreshed: false
  property var hosts: []
  property var counts: Model.emptyCounts()
  property string lastError: ""
  property string actionStatus: ""
  // "<context>/<container id>" while a start/stop/restart is in flight.
  property string pendingActionKey: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 3600)
  readonly property int timeoutSec: intSetting("timeoutSec", 10, 2, 120)
  readonly property bool showAll: boolSetting("showAll", true)
  readonly property bool showStats: boolSetting("showStats", true)
  readonly property var contexts: listSetting("contexts")
  readonly property bool busy: statusProcess.running || actionProcess.running
  readonly property bool healthy: counts.unhealthy === 0 && counts.unreachable === 0
  readonly property string summaryText: Model.summaryText(everRefreshed ? counts : null, installed)

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    return url.replace(/^file:\/\//, "").replace(/\/$/, "")
  }

  property string _statusOutput: ""
  property string _statusError: ""
  property string _actionOutput: ""
  property string _actionError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function stringSetting(name, fallback) {
    var v = setting(name, fallback)
    return v === undefined || v === null ? String(fallback) : String(v)
  }

  function boolSetting(name, fallback) {
    var v = setting(name, fallback)
    if (typeof v === "boolean") return v
    return String(v).toLowerCase() === "true"
  }

  // Multiselect values arrive as JS arrays or QML JSValue lists from the
  // settings form, but `omarchy bar set` flattens them to a comma-separated
  // string. Check for strings first: they have a numeric .length too, and
  // iterating one yields its characters.
  function listSetting(name) {
    var v = setting(name, [])
    var out = []
    if (typeof v === "string") {
      var parts = v.split(",")
      for (var j = 0; j < parts.length; j++) if (parts[j].trim() !== "") out.push(parts[j].trim())
    } else if (v && typeof v.length === "number") {
      for (var i = 0; i < v.length; i++) {
        var s = String(v[i] || "").trim()
        if (s !== "") out.push(s)
      }
    }
    return out
  }

  // Set when a refresh was asked for mid-poll; honoured as soon as it ends so
  // a start/stop never waits a whole interval to show up.
  property bool _refreshPending: false

  function refresh() {
    if (statusProcess.running) { _refreshPending = true; return }
    _refreshPending = false
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    var cmd = [pluginDir + "/bin/dockarchy-status", "--timeout", String(timeoutSec)]
    if (showAll) cmd.push("--all")
    if (showStats) cmd.push("--stats")
    if (contexts.length > 0) {
      cmd.push("--")
      for (var i = 0; i < contexts.length; i++) cmd.push(contexts[i])
    }
    statusProcess.command = cmd
    statusProcess.running = true
    // refresh() bails while a poll is in flight, so this only re-arms when a
    // fresh process actually starts — a hung one can never push the deadline.
    pollWatchdog.restart()
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.error || "Failed to read docker status"
      console.warn("dockarchy", lastError)
      return
    }
    installed = parsed.installed !== false
    hosts = parsed.hosts
    counts = parsed.counts
    everRefreshed = true
    lastError = ""
  }

  function findContainer(contextName, ref) {
    var ctx = String(contextName || "")
    var wanted = String(ref || "")
    for (var h = 0; h < hosts.length; h++) {
      var host = hosts[h]
      if (ctx !== "" && host.name !== ctx) continue
      for (var c = 0; c < host.containers.length; c++) {
        var container = host.containers[c]
        if (container.name === wanted || container.id === wanted || container.shortId === wanted) return { host: host, container: container }
      }
    }
    return null
  }

  function actionKey(host, container) {
    if (!host || !container) return ""
    return String(host.name) + "/" + String(container.id)
  }

  function isPending(host, container) {
    var key = actionKey(host, container)
    return key !== "" && key === pendingActionKey
  }

  function containerAction(host, container, verb) {
    if (!host || !container || actionProcess.running) return
    var allowed = ["start", "stop", "restart", "pause", "unpause"]
    if (allowed.indexOf(verb) === -1) return
    _actionOutput = ""
    _actionError = ""
    pendingActionKey = actionKey(host, container)
    actionStatus = capitalize(verb) + "ing " + container.name + "…"
    actionProcess.command = ["timeout", String(Math.max(timeoutSec, 30)), "docker", "--context", String(host.name), verb, String(container.id)]
    actionProcess.running = true
  }

  function toggleContainer(host, container) {
    if (!container) return
    if (container.state === "paused") containerAction(host, container, "unpause")
    else containerAction(host, container, container.running ? "stop" : "start")
  }

  function restartContainer(host, container) {
    containerAction(host, container, "restart")
  }

  // Terminal-bound actions: reuse Omarchy's TUI launcher so the window gets the
  // same styling and app-id handling as btop, lazydocker and friends.
  function openLogs(host, container) {
    if (!host || !container) return
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.dockarchy-logs",
      "docker", "--context", String(host.name), "logs", "--follow", "--tail", "200", String(container.id)])
  }

  function openShell(host, container) {
    if (!host || !container || !container.running) return
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.dockarchy-shell",
      "docker", "--context", String(host.name), "exec", "-it", String(container.id),
      "sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh"])
  }

  function openLazydocker(host) {
    var cmd = ["omarchy-launch-tui", "--app-id=org.omarchy.lazydocker", "env"]
    if (host && host.name) cmd.push("DOCKER_CONTEXT=" + String(host.name))
    cmd.push("lazydocker")
    Quickshell.execDetached(cmd)
  }

  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function capitalize(s) {
    s = String(s || "")
    return s.length === 0 ? s : s.charAt(0).toUpperCase() + s.substring(1)
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  onRefreshIntervalSecChanged: refreshTimer.restart()
  onShowAllChanged: refresh()
  onShowStatsChanged: refresh()
  onContextsChanged: refresh()

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0 && stdout.trim() !== "") root.applyStatus(stdout)
      else root.lastError = root.elide(stderr || stdout || "dockarchy-status exited with " + exitCode)
      if (root._refreshPending) delayedRefresh.restart()
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true; onStreamFinished: root._actionOutput = text }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) {
      var stdout = String(actionStdout.text || root._actionOutput || "")
      var stderr = String(actionStderr.text || root._actionError || "")
      root.pendingActionKey = ""
      if (exitCode !== 0) {
        root.actionStatus = root.elide(Model.shortError(stderr || stdout) || "docker command failed")
      } else {
        root.actionStatus = ""
      }
      actionStatusTimer.restart()
      delayedRefresh.restart()
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 6000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  // A poll is skipped while the previous one still runs, so a collector that
  // never returns (a wedged ssh session, say) would silently freeze the widget.
  // The script already bounds each docker call; this is the belt to its braces.
  Timer {
    id: pollWatchdog
    interval: (root.timeoutSec + 15) * 1000
    repeat: false
    onTriggered: {
      if (!statusProcess.running) return
      console.warn("dockarchy: status collector hung, killing it")
      statusProcess.running = false
      root.refreshing = false
    }
  }
}
