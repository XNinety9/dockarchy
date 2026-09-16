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
  // "<context>/<container id>" (or "<context>//<project>" for a whole compose
  // group) while a start/stop/restart is in flight.
  property string pendingActionKey: ""

  // Previous poll, for change detection. Null until the first good poll so a
  // shell restart never fires a burst of "X is running" notifications.
  property var _lastSnapshot: null
  // "host/id" -> {until, verb} for containers the user just acted on; the
  // transition they asked for is theirs, not an incident.
  property var _userTouched: ({})
  // "type:key" -> last notified ms, to tame flapping health checks.
  property var _notified: ({})

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 3600)
  readonly property int timeoutSec: intSetting("timeoutSec", 10, 2, 120)
  readonly property bool showAll: boolSetting("showAll", true)
  readonly property bool showStats: boolSetting("showStats", true)
  readonly property bool groupByProject: boolSetting("groupByProject", true)
  readonly property bool showSparklines: boolSetting("showSparklines", true)
  readonly property var sparkMetrics: validMetrics(listSetting("sparkMetrics"))
  readonly property int sparkSamples: intSetting("sparkSamples", 20, 5, 240)
  readonly property bool runningAccent: boolSetting("runningAccent", false)
  // "host/id" -> {cpu: [], mem: []}, the last HISTORY_LENGTH polls.
  property var history: ({})
  // "Off" | "Problems" | "Problems and recoveries"
  readonly property string notifications: stringSetting("notifications", "Problems")
  readonly property var contexts: listSetting("contexts")
  readonly property bool busy: statusProcess.running || actionProcess.running
  readonly property bool actionRunning: actionProcess.running
  readonly property bool healthy: counts.unhealthy === 0 && counts.unreachable === 0
  readonly property string summaryText: Model.summaryText(everRefreshed ? counts : null, installed)

  // Notification icons are Nerd Font glyphs rendered to PNG in the theme's
  // colours at startup (and again when the theme changes). Until that has
  // happened, or if ImageMagick is missing, the PNGs shipped in assets/ serve.
  readonly property string iconDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/dockarchy"
  property bool iconsRendered: false
  readonly property string iconProblem: (iconsRendered ? iconDir : pluginDir + "/assets") + "/problem.png"
  readonly property string iconRecovery: (iconsRendered ? iconDir : pluginDir + "/assets") + "/recovery.png"

  function hexColor(c) {
    function h(v) { var s = Math.round(v * 255).toString(16); return s.length < 2 ? "0" + s : s }
    return "#" + h(c.r) + h(c.g) + h(c.b)
  }

  function renderIcons() {
    if (iconProcess.running) { iconRenderRetry.restart(); return }
    var fg = Color.foreground
    var urgent = Color.urgent
    var warn = Qt.rgba(fg.r + (urgent.r - fg.r) * 0.55, fg.g + (urgent.g - fg.g) * 0.55, fg.b + (urgent.b - fg.b) * 0.55, 1)
    iconProcess.command = [pluginDir + "/assets/render-icons", "--out", iconDir,
      "--fg", hexColor(fg), "--warn", hexColor(warn), "--ok", hexColor(Color.accent)]
    iconProcess.running = true
  }

  Component.onCompleted: renderIcons()

  Connections {
    target: Color
    function onForegroundChanged() { iconRenderRetry.restart() }
    function onAccentChanged() { iconRenderRetry.restart() }
  }

  Process {
    id: iconProcess
    running: false
    command: []
    onExited: function(exitCode) { root.iconsRendered = exitCode === 0 }
  }

  // Theme changes fire several colour signals in a row; render once.
  Timer {
    id: iconRenderRetry
    interval: 800
    repeat: false
    onTriggered: root.renderIcons()
  }

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
    if (showStats) history = Model.pushHistory(history, hosts, sparkSamples, Date.now())
    var snap = Model.snapshot(hosts)
    if (_lastSnapshot) notifyChanges(Model.diffSnapshots(_lastSnapshot, snap, currentUserTouched()))
    _lastSnapshot = snap
  }

  // Drop expired entries and return a plain key -> verb map for
  // Model.diffSnapshots.
  function currentUserTouched() {
    var now = Date.now()
    var live = {}
    var verbs = {}
    for (var k in _userTouched) if (_userTouched[k].until > now) { live[k] = _userTouched[k]; verbs[k] = _userTouched[k].verb }
    _userTouched = live
    return verbs
  }

  function markUserTouched(host, containers, verb) {
    var until = Date.now() + 90000
    currentUserTouched()
    var next = {}
    for (var k in _userTouched) next[k] = _userTouched[k]
    for (var i = 0; i < containers.length; i++) next[String(host.name) + "/" + String(containers[i].id)] = { until: until, verb: String(verb) }
    _userTouched = next
  }

  function notifyChanges(events) {
    if (notifications === "Off") return
    var now = Date.now()
    for (var i = 0; i < events.length; i++) {
      var e = events[i]
      if (e.kind === "recovery" && notifications !== "Problems and recoveries") continue
      var dedupe = e.type + ":" + (e.key || e.host)
      // Health checks flap; stops and host outages are discrete events.
      var quiet = (e.type === "unhealthy" || e.type === "healthy") ? 120000 : 20000
      if (_notified[dedupe] && now - _notified[dedupe] < quiet) continue
      _notified[dedupe] = now
      Quickshell.execDetached(["notify-send", "-a", "Dockarchy", "-u", e.kind === "problem" ? "critical" : "normal",
        "-i", e.kind === "problem" ? iconProblem : iconRecovery,
        "-h", "string:x-canonical-private-synchronous:dockarchy-" + dedupe,
        String(e.title), String(e.body || "")])
    }
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

  // Keep only known metric names, in the canonical order; default CPU+Memory.
  function validMetrics(names) {
    var out = []
    for (var i = 0; i < Model.METRIC_NAMES.length; i++) {
      if (names.indexOf(Model.METRIC_NAMES[i]) !== -1) out.push(Model.METRIC_NAMES[i])
    }
    return out.length > 0 ? out : ["CPU", "Memory"]
  }

  function historyFor(host, container) {
    if (!host || !container) return null
    var series = history[String(host.name) + "/" + String(container.id)]
    return series && series.cpu.length > 0 ? series : null
  }

  function actionKey(host, container) {
    if (!host || !container) return ""
    return String(host.name) + "/" + String(container.id)
  }

  function isPending(host, container) {
    var key = actionKey(host, container)
    return key !== "" && key === pendingActionKey
  }

  function groupActionKey(host, group) {
    if (!host || !group) return ""
    return String(host.name) + "//" + String(group.project)
  }

  function isGroupPending(host, group) {
    var key = groupActionKey(host, group)
    return key !== "" && key === pendingActionKey
  }

  function containerAction(host, container, verb) {
    if (!host || !container || actionProcess.running) return
    var allowed = ["start", "stop", "restart", "pause", "unpause", "kill", "rm"]
    if (allowed.indexOf(verb) === -1) return
    if (verb === "rm" && container.running) return
    _actionOutput = ""
    _actionError = ""
    pendingActionKey = actionKey(host, container)
    markUserTouched(host, [container], verb)
    actionStatus = (verb === "rm" ? "Removing " : verb === "stop" ? "Stopping " : capitalize(verb) + "ing ") + container.name + "…"
    actionProcess.command = ["timeout", String(Math.max(timeoutSec, 30)), "docker", "--context", String(host.name), verb, String(container.id)]
    actionProcess.running = true
  }

  // One docker invocation for the whole group, so a remote host sees a single
  // request rather than one per container.
  function groupAction(host, group, verb) {
    if (!host || !group || actionProcess.running) return
    var targets = []
    for (var i = 0; i < group.containers.length; i++) {
      var c = group.containers[i]
      if (verb === "start" && c.running) continue
      if ((verb === "stop" || verb === "restart") && !c.running) continue
      targets.push(c)
    }
    if (targets.length === 0) return
    _actionOutput = ""
    _actionError = ""
    pendingActionKey = groupActionKey(host, group)
    markUserTouched(host, targets, verb)
    actionStatus = capitalize(verb) + "ing " + (group.project || "standalone containers") + " (" + targets.length + ")…"
    var cmd = ["timeout", String(Math.max(timeoutSec, 60)), "docker", "--context", String(host.name), verb]
    for (var t = 0; t < targets.length; t++) cmd.push(String(targets[t].id))
    actionProcess.command = cmd
    actionProcess.running = true
  }

  // Terminal command for a host: docker is run on the server over the user's
  // ssh config for remote contexts, locally otherwise. `argv` is the docker
  // argv without the leading "docker".
  function dockerTerminalCommand(host, argv) {
    var ssh = host ? Model.sshArgv(host.endpoint) : null
    if (ssh) {
      var quoted = ["docker"]
      for (var i = 0; i < argv.length; i++) quoted.push(Model.shellQuote(argv[i]))
      // -t so an interactive docker exec gets a TTY through ssh.
      return ssh.slice(0, 1).concat(["-t"]).concat(ssh.slice(1)).concat([quoted.join(" ")])
    }
    var local = ["docker"]
    if (host && host.name) local.push("--context", String(host.name))
    return local.concat(argv)
  }

  // `docker inspect` is long: page it. The pipe means a shell on either side.
  function openInspect(host, container) {
    if (!host || !container) return
    var ssh = Model.sshArgv(host.endpoint)
    var cmd
    if (ssh) cmd = ssh.slice(0, 1).concat(["-t"]).concat(ssh.slice(1)).concat(["docker inspect " + Model.shellQuote(String(container.id)) + " | less -R"])
    else cmd = ["sh", "-c", "docker --context " + Model.shellQuote(String(host.name)) + " inspect " + Model.shellQuote(String(container.id)) + " | less -R"]
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.dockarchy-inspect"].concat(cmd))
  }

  function openUrl(url) {
    var u = String(url || "")
    if (u === "") return
    Quickshell.execDetached(["omarchy-launch-browser", u])
  }

  function openPort(host, port) {
    if (!host || !port) return
    openUrl(Model.portUrl(host.endpoint, port))
  }

  function openGroupLogs(host, group) {
    if (!host || !group || !group.project) return
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.dockarchy-logs"]
      .concat(dockerTerminalCommand(host, ["compose", "-p", String(group.project), "logs", "--follow", "--tail", "100"])))
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
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.dockarchy-logs"]
      .concat(dockerTerminalCommand(host, ["logs", "--follow", "--tail", "200", String(container.id)])))
  }

  function openShell(host, container) {
    if (!host || !container || !container.running) return
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.dockarchy-shell"]
      .concat(dockerTerminalCommand(host, ["exec", "-it", String(container.id),
        "sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh"])))
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
