import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "x99.dockarchy"
  ipcTarget: "x99.dockarchy"
  manageIpc: false

  // Keyboard cursor walks one flat list of rows — compose group headers and
  // containers alike — across every host section, so j/k never has to know
  // where one server ends and the next begins.
  property int cursorIndex: 0
  property bool cursorActive: false
  property string query: ""
  property bool searchOpen: false
  property bool menuOpen: false
  property bool confirmOpen: false

  // Folded groups/hosts and per-host "hide stopped" live in the widget's
  // shell.json entry as comma-separated lists, so they survive restarts.
  readonly property var collapsedGroups: docker.listSetting("collapsedGroups")
  readonly property var collapsedHosts: docker.listSetting("collapsedHosts")
  readonly property var hideStoppedHosts: docker.listSetting("hideStoppedHosts")
  readonly property string sortBy: docker.stringSetting("sortBy", "State")

  // Merge a patch into the widget's settings entry through the shell, which
  // rewrites shell.json; `settings` then flows back in and rebuilds the view.
  function persist(patch) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var k in patch) {
      var v = patch[k]
      entry[k] = v && typeof v.length === "number" && typeof v !== "string" ? v.join(",") : v
    }
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function listToggle(list, value) {
    var next = []
    var found = false
    for (var i = 0; i < list.length; i++) {
      if (list[i] === value) found = true
      else next.push(list[i])
    }
    if (!found) next.push(value)
    return next
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  // Attention colour for glyphs: the theme's urgent red is loud for "a host
  // did not answer", so blend it towards the text colour. Textual error
  // messages keep plain `urgent` so they still read as errors.
  readonly property color warning: blend(foreground, urgent, 0.55)
  readonly property color barWarning: blend(barForeground, urgent, 0.55)

  function blend(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property string barFormat: docker.stringSetting("barFormat", "{running}")
  readonly property string barLabel: docker.everRefreshed && docker.installed ? Model.formatBar(barFormat, docker.counts) : ""
  readonly property int panelWidth: docker.intSetting("panelWidth", 700, 300, 1400)
  readonly property int panelMaxHeight: docker.intSetting("panelMaxHeight", 800, 300, 1600)
  readonly property bool alternateRows: docker.boolSetting("alternateRows", false)
  readonly property color stripeFill: Util.alpha(foreground, 0.05)
  readonly property bool alarming: docker.everRefreshed && !docker.healthy
  readonly property color barIconColor: docker.installed && docker.counts.running > 0 ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool filtering: query.trim() !== ""

  // hosts -> filtered by query -> compose groups. Each view host carries
  // `groups` ([{project, containers, counts, key, collapsed, header}]) and
  // `matches` (containers left after filtering).
  readonly property var viewHosts: buildViewHosts()
  // [{kind: "group"|"container", host, group, container?}] in display order.
  readonly property var rows: flattenRows()
  readonly property var selected: selectedRow()

  function buildViewHosts() {
    var out = []
    for (var h = 0; h < docker.hosts.length; h++) {
      var host = docker.hosts[h]
      var hideStopped = hideStoppedHosts.indexOf(host.name) !== -1 && !filtering
      var visible = []
      var hiddenCount = 0
      for (var i = 0; i < host.containers.length; i++) {
        if (hideStopped && !host.containers[i].running) hiddenCount++
        else visible.push(host.containers[i])
      }
      var containers = Model.sortContainers(Model.filterContainers(visible, query), sortBy)
      var groups = Model.groupContainers(containers, docker.groupByProject)
      for (var g = 0; g < groups.length; g++) {
        groups[g].key = Model.groupKey(host.name, groups[g].project)
        groups[g].header = groups[g].project !== ""
        groups[g].collapsed = groups[g].header && !filtering && collapsedGroups.indexOf(groups[g].key) !== -1
      }
      out.push({
        host: host, groups: groups, matches: containers.length, hiddenStopped: hiddenCount,
        hideStopped: hideStopped, collapsed: !filtering && collapsedHosts.indexOf(host.name) !== -1,
        hidden: filtering && containers.length === 0
      })
    }
    return out
  }

  function flattenRows() {
    var out = []
    for (var h = 0; h < viewHosts.length; h++) {
      var view = viewHosts[h]
      if (view.hidden) continue
      out.push({ kind: "host", host: view.host, view: view, key: "host:" + view.host.name })
      if (view.collapsed) continue
      for (var g = 0; g < view.groups.length; g++) {
        var group = view.groups[g]
        if (group.header) out.push({ kind: "group", host: view.host, group: group, key: group.key })
        if (group.collapsed) continue
        for (var c = 0; c < group.containers.length; c++) {
          var container = group.containers[c]
          out.push({ kind: "container", host: view.host, group: group, container: container, key: view.host.name + "/" + container.id })
        }
      }
    }
    return out
  }

  function selectedRow() {
    if (rows.length === 0) return null
    return rows[Math.max(0, Math.min(cursorIndex, rows.length - 1))]
  }

  function ensureCursor() {
    if (cursorIndex >= rows.length) cursorIndex = Math.max(0, rows.length - 1)
    if (cursorIndex < 0) cursorIndex = 0
  }

  function moveCursor(delta) {
    cursorActive = true
    if (rows.length === 0) return
    cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + delta))
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
  }

  function rowIndexOf(key) {
    for (var i = 0; i < rows.length; i++) if (rows[i].key === key) return i
    return -1
  }

  // ⏎ / space: containers toggle start/stop, group and host headers fold.
  function activateCursor() {
    var row = selected
    if (!row) return
    if (row.kind === "group") toggleCollapsed(row.group)
    else if (row.kind === "host") toggleHostCollapsed(row.host)
    else docker.toggleContainer(row.host, row.container)
  }

  function toggleCollapsed(group) {
    if (!group || !group.header) return
    persist({ collapsedGroups: listToggle(collapsedGroups, group.key) })
  }

  function setAllCollapsed(value) {
    var next = []
    if (value) {
      for (var h = 0; h < viewHosts.length; h++)
        for (var g = 0; g < viewHosts[h].groups.length; g++)
          if (viewHosts[h].groups[g].header) next.push(viewHosts[h].groups[g].key)
    }
    persist({ collapsedGroups: next })
  }

  function toggleHostCollapsed(host) {
    if (!host) return
    persist({ collapsedHosts: listToggle(collapsedHosts, host.name) })
  }

  function toggleHideStopped(host) {
    if (!host) return
    persist({ hideStoppedHosts: listToggle(hideStoppedHosts, host.name) })
  }

  function cycleSort() {
    persist({ sortBy: Model.nextSortMode(sortBy) })
  }

  function openFirstPort(row) {
    if (!row || row.kind !== "container" || row.container.published.length === 0) return
    docker.openPort(row.host, row.container.published[0])
  }

  // x on a container: kill it if running, remove it if not — after asking.
  function requestDestroy(row) {
    if (!row || row.kind !== "container") return
    var verb = row.container.running ? "kill" : "rm"
    confirm.pendingVerb = verb
    confirm.pendingRow = row
    confirm.message = (verb === "kill" ? "Kill " : "Remove ") + row.container.name + " on " + row.host.name + "?"
    confirm.confirmText = verb === "kill" ? "Kill" : "Remove"
    confirm.selectedIndex = 0
    confirm.opened = true
    root.confirmOpen = true
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  function finishConfirm(accepted) {
    var row = confirm.pendingRow
    var verb = confirm.pendingVerb
    confirm.opened = false
    confirm.pendingRow = null
    confirm.pendingVerb = ""
    root.confirmOpen = false
    if (accepted && row) docker.containerAction(row.host, row.container, verb)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openMenu(row) {
    if (!row || row.kind !== "container") return
    var item = rowItems[row.key]
    if (item && item.openMenu) item.openMenu()
  }

  // Row-level verbs shared by keys and buttons; groups fan out to members.
  function rowAction(row, verb) {
    if (!row || row.kind === "host") return
    if (row.kind === "group") docker.groupAction(row.host, row.group, verb)
    else if (verb === "restart") docker.restartContainer(row.host, row.container)
    else docker.containerAction(row.host, row.container, verb)
  }

  function rowLogs(row) {
    if (!row || row.kind === "host") return
    if (row.kind === "group") docker.openGroupLogs(row.host, row.group)
    else docker.openLogs(row.host, row.container)
  }

  function openSearch() {
    searchOpen = true
    Qt.callLater(function() { if (searchField) { searchField.forceActiveFocus(); searchField.selectAll() } })
  }

  function closeSearch(clear) {
    if (clear) query = ""
    searchOpen = query !== ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  readonly property string footerText: {
    if (confirmOpen) return "←/→ choose · ⏎ confirm · Esc cancel"
    if (menuOpen) return "↑/↓ move · ⏎ choose · Esc close"
    if (searchField && searchField.activeFocus) return "type to filter · ↑/↓ move · ⏎ back to list · Esc clear"
    var row = selected
    var sort = " · t sort: " + sortBy
    if (row && row.kind === "host") return "j/k move · ⏎ fold host · h hide/show stopped · L lazydocker · / search" + sort
    if (row && row.kind === "group") return "j/k move · ⏎ fold · u up · d down · r restart · l logs · z fold all · / search" + sort
    return "j/k move · ⏎ start/stop · l logs · s shell · r restart · o open port · m menu · x kill/remove · / search" + sort
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    var row = selected
    if (!row) return
    var item = rowItems[row.key]
    if (item) scrollItemIntoView(item)
  }

  // Row items register themselves here so the cursor can find its delegate
  // without walking nested Repeater children.
  property var rowItems: ({})
  function registerRow(key, item) { rowItems[key] = item }
  function unregisterRow(key) { delete rowItems[key] }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    docker.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    query = ""
    searchOpen = false
  }
  onRowsChanged: ensureCursor()
  onQueryChanged: { cursorIndex = 0; if (filtering) cursorActive = true }

  Service {
    id: docker
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { docker.refresh(); return "ok" }
    function status(): string { return docker.summaryText }
    function version(): string { return "0.5.0" }
    function running(): string { return String(docker.counts.running) }
    function settings(): string { return JSON.stringify({ settings: root.settings, contexts: docker.contexts }) }
    function rows(): string {
      var out = []
      for (var i = 0; i < root.rows.length; i++) {
        var r = root.rows[i]
        var mark = (i === root.cursorIndex && root.cursorActive ? "> " : "  ")
        var label = r.kind === "host" ? "# " + r.host.name + (r.view.collapsed ? " (folded)" : "") + (r.view.hiddenStopped ? " (" + r.view.hiddenStopped + " hidden)" : "")
          : r.kind === "group" ? "  [" + r.group.project + " " + Model.groupSummary(r.group) + "]"
          : "    " + r.container.name + " (" + r.container.state + ")"
        out.push(mark + label + " @" + r.host.name)
      }
      return out.join("\n")
    }
    function search(text: string): string { root.open(); root.query = text; root.openSearch(); return "ok" }
    // omarchy-shell x99.dockarchy sort <State|Name|CPU|Memory|next>
    function sort(mode: string): string {
      var next = mode === "next" ? Model.nextSortMode(root.sortBy) : mode
      if (Model.SORT_MODES.indexOf(next) === -1) return "unknown sort mode: " + mode
      root.persist({ sortBy: next })
      return next
    }
    // omarchy-shell x99.dockarchy action <context> <container name or id> <start|stop|restart|pause|unpause>
    function action(context: string, container: string, verb: string): string {
      var found = docker.findContainer(context, container)
      if (!found) return "unknown container: " + context + "/" + container
      if (docker.actionRunning) return "busy"
      docker.containerAction(found.host, found.container, verb)
      return docker.pendingActionKey !== "" ? "ok" : "rejected"
    }
    // omarchy-shell x99.dockarchy project <context> <project> <start|stop|restart>
    function project(context: string, project: string, verb: string): string {
      for (var h = 0; h < root.viewHosts.length; h++) {
        var view = root.viewHosts[h]
        if (view.host.name !== context) continue
        for (var g = 0; g < view.groups.length; g++) {
          if (view.groups[g].project !== project) continue
          if (docker.actionRunning) return "busy"
          docker.groupAction(view.host, view.groups[g], verb)
          return docker.pendingActionKey !== "" ? "ok" : "rejected"
        }
      }
      return "unknown project: " + context + "/" + project
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.alarming
    activeColor: root.barWarning
    text: root.barLabel !== "" && !vertical ? "󰡨 " + root.barLabel : "󰡨"
    // Grow the slot to whatever the label paints instead of guessing per char.
    slotSize: vertical ? Style.bar.iconSlot : Math.max(Style.bar.iconSlot, button.glyphPaintedWidth + Style.space(14))
    tooltipText: docker.summaryText
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) docker.openLazydocker(null)
      else if (buttonCode === Qt.MiddleButton) docker.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: panel.fittedContentHeight(topBlock.implicitHeight + column.implicitHeight + footer.implicitHeight + Style.space(12), Style.space(root.panelMaxHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.menuOpen || root.confirmOpen
      onDeleteRequested: root.requestDestroy(root.selected)
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy > 0 ? 1 : -1)
        // PanelKeyCatcher turns `l`/→ into a horizontal move before textKey
        // ever sees it; on a row that means "open logs".
        else if (dx > 0) root.rowLogs(root.selected)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var row = root.selected
        if (t === "/") root.openSearch()
        else if (t === "R") docker.refresh()
        else if (t === "r") root.rowAction(row, "restart")
        else if (t === "u") root.rowAction(row, "start")
        else if (t === "d") root.rowAction(row, "stop")
        else if (t === "z") root.setAllCollapsed(root.collapsedGroups.length === 0)
        else if (t === "t") root.cycleSort()
        else if (t === "h" && row) root.toggleHideStopped(row.host)
        else if (t === "o") root.openFirstPort(row)
        else if (t === "m") root.openMenu(row)
        else if (t === "i" && row && row.kind === "container") docker.openInspect(row.host, row.container)
        else if (t === "s" && row && row.kind === "container") docker.openShell(row.host, row.container)
        else if (t === "c" && row && row.kind === "container") docker.copyToClipboard(row.container.name)
        else if (t === "L") docker.openLazydocker(row ? row.host : null)
      }

      // Destructive actions ask first. The dialog fills the panel; keys reach
      // it through this focus item while the catcher is blocked.
      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        z: 50
        property string pendingVerb: ""
        property var pendingRow: null
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.finishConfirm(false)
        onConfirmed: root.finishConfirm(true)

        Item {
          id: confirmKeys
          focus: confirm.opened
          Keys.onPressed: function(event) { if (confirm.handleKey(event)) event.accepted = true }
        }
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: 0

      // Hero and search stay put; only the host list scrolls.
      Column {
        id: topBlock
        Layout.fillWidth: true
        spacing: Style.space(10)

        PanelHero {
          id: hero
          width: parent.width
          title: "Docker"
          meta: docker.summaryText
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: docker.installed && docker.counts.running > 0 ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: "󰡨"
              color: root.alarming ? root.warning : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            Row {
              spacing: Style.space(4)

              PanelActionButton {
                iconText: "󰍉"
                tooltipText: "Search (/)"
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                onClicked: root.openSearch()
              }

              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Refresh (R)"
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                enabled: !docker.refreshing
                onClicked: docker.refresh()

                NumberAnimation on rotation {
                  running: docker.refreshing
                  from: 0; to: 360; duration: 900
                  loops: Animation.Infinite
                }
                onRotationChanged: if (!docker.refreshing && rotation !== 0) rotation = 0
              }

              PanelActionButton {
                iconText: "󰆍"
                tooltipText: "Open lazydocker (L)"
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                onClicked: docker.openLazydocker(null)
              }
            }
          }
        }

        TextField {
          id: searchField
          visible: root.searchOpen
          width: parent.width
          foreground: root.foreground
          placeholderText: "Filter by name, image, project, status…"
          text: root.query
          onTextChanged: root.query = text
          onActiveFocusChanged: if (!activeFocus && root.query === "") root.searchOpen = false
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Down) { root.moveCursor(1); event.accepted = true }
            else if (event.key === Qt.Key_Up) { root.moveCursor(-1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.closeSearch(false); event.accepted = true }
            else if (event.key === Qt.Key_Escape) { root.closeSearch(true); event.accepted = true }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: docker.actionStatus !== "" || docker.lastError !== ""
          width: parent.width
          text: docker.actionStatus !== "" ? docker.actionStatus : docker.lastError
          color: docker.lastError !== "" && docker.actionStatus === "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      Item { Layout.fillWidth: true; implicitHeight: Style.space(12) }

      Flickable {
        id: panelFlick
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          CursorSurface {
            visible: !docker.installed
            width: parent.width
            implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: missingText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "Docker CLI is not installed or not on PATH. Run `omarchy install docker`."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          Text {
            visible: docker.installed && docker.everRefreshed && docker.hosts.length === 0
            width: parent.width
            text: "No Docker contexts found."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: root.filtering && root.rows.length === 0 && docker.hosts.length > 0
            width: parent.width
            text: "No container matches \"" + root.query.trim() + "\"."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            model: root.viewHosts
            HostSection {
              required property var modelData
              required property int index
              width: column.width
              visible: !modelData.hidden
              view: modelData
              host: modelData.host
              hostIndex: index
            }
          }
        }
      }

      // Sticky footer: stays visible however long the container list gets,
      // and describes the keys that apply to the selected row.
      Column {
        id: footer
        Layout.fillWidth: true
        spacing: Style.space(6)

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.footerText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
      }
    }
  }

  component HostSection: Column {
    id: section
    property var view: null
    property var host: null
    property int hostIndex: 0
    readonly property string hostName: host ? String(host.name) : ""
    readonly property string hint: host ? Model.errorHint(host.error) : ""
    spacing: Style.space(10)

    PanelSeparator {
      width: parent.width
      foreground: root.foreground
    }

    HostRow {
      width: parent.width
      host: section.host
      view: section.view
    }

    CursorSurface {
      visible: section.host && !section.host.ok
      width: parent.width
      implicitHeight: errorColumn.implicitHeight + Style.spacing.rowPaddingX
      foreground: root.foreground

      Column {
        id: errorColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(12)
        spacing: Style.space(4)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: section.host ? Model.shortError(section.host.error) : ""
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: section.hint !== ""
          width: parent.width
          text: section.hint
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    Text {
      visible: section.host && section.host.ok && section.host.containers.length === 0 && !(section.view && section.view.collapsed)
      width: parent.width
      text: docker.showAll ? "No containers on this host." : "No running containers on this host."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }

    Column {
      visible: !(section.view && section.view.collapsed)
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: section.view ? section.view.groups : []
        Column {
          id: groupColumn
          required property var modelData
          width: parent.width
          spacing: Style.space(6)

          GroupRow {
            visible: groupColumn.modelData.header
            width: parent.width
            host: section.host
            group: groupColumn.modelData
          }

          Repeater {
            model: groupColumn.modelData.collapsed ? [] : groupColumn.modelData.containers
            ContainerRow {
              required property var modelData
              required property int index
              width: parent.width
              host: section.host
              group: groupColumn.modelData
              container: modelData
              indented: groupColumn.modelData.header
              striped: root.alternateRows && index % 2 === 1
            }
          }
        }
      }
    }
  }

  // Host header: a cursor row that folds the whole host and toggles whether
  // its stopped containers are listed.
  component HostRow: CursorSurface {
    id: hostRow
    property var host: null
    property var view: null
    readonly property string hostName: host ? String(host.name) : ""
    readonly property string key: hostName !== "" ? "host:" + hostName : ""
    readonly property int flatIndex: key !== "" ? root.rowIndexOf(key) : -1
    readonly property bool folded: view && view.collapsed
    readonly property bool hidingStopped: view && view.hideStopped

    hasCursor: root.cursorActive && root.cursorIndex === flatIndex && flatIndex >= 0
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: hostContent.implicitHeight + Style.spacing.rowPaddingX

    Component.onCompleted: if (key !== "") root.registerRow(key, hostRow)
    Component.onDestruction: if (key !== "") root.unregisterRow(key)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse && hostRow.flatIndex >= 0) root.setCursor(hostRow.flatIndex)
      onClicked: root.toggleHostCollapsed(hostRow.host)
    }

    RowLayout {
      id: hostContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: hostRow.folded ? "󰅂" : "󰅀"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        text: Model.hostGlyph(hostRow.host)
        color: hostRow.host && hostRow.host.ok ? root.foreground : root.warning
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        PanelSectionHeader {
          Layout.fillWidth: true
          text: hostRow.hostName.toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: hostRow.host && hostRow.host.endpoint !== ""
          text: hostRow.host ? hostRow.host.endpoint : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: hostRow.host && hostRow.host.ok
        text: {
          if (!hostRow.host) return ""
          var base = hostRow.host.counts.running + "/" + hostRow.host.counts.total
          if (root.filtering && hostRow.view) return hostRow.view.matches + " match · " + base
          if (hostRow.view && hostRow.view.hiddenStopped > 0) return base + " · " + hostRow.view.hiddenStopped + " hidden"
          return base
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      PanelActionButton {
        iconText: hostRow.hidingStopped ? "󰈉" : "󰈈"
        tooltipText: hostRow.hidingStopped ? "Show stopped containers (h)" : "Hide stopped containers (h)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        visible: hostRow.host && hostRow.host.ok && !root.filtering
        onClicked: root.toggleHideStopped(hostRow.host)
      }

      PanelActionButton {
        iconText: "󰆍"
        tooltipText: "lazydocker on " + hostRow.hostName
        foreground: root.foreground
        fontFamily: root.fontFamily
        visible: hostRow.host && hostRow.host.ok
        onClicked: docker.openLazydocker(hostRow.host)
      }
    }
  }

  // Compose project header: fold/unfold, counts, and whole-project actions.
  component GroupRow: CursorSurface {
    id: groupRow
    property var host: null
    property var group: null
    readonly property string key: group ? group.key : ""
    readonly property int flatIndex: key !== "" ? root.rowIndexOf(key) : -1
    readonly property bool pending: docker.isGroupPending(host, group)
    readonly property bool anyRunning: group && group.counts.running > 0
    readonly property bool allRunning: group && group.counts.running === group.counts.total
    readonly property bool unhealthy: group && group.counts.unhealthy > 0

    hasCursor: root.cursorActive && root.cursorIndex === flatIndex && flatIndex >= 0
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: groupContent.implicitHeight + Style.spacing.rowPaddingX

    Component.onCompleted: if (key !== "") root.registerRow(key, groupRow)
    Component.onDestruction: if (key !== "") root.unregisterRow(key)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse && groupRow.flatIndex >= 0) root.setCursor(groupRow.flatIndex)
      onClicked: root.toggleCollapsed(groupRow.group)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: groupRow.group && groupRow.group.collapsed ? "󰅂" : "󰅀"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
        opacity: groupRow.pending ? 0.45 : 1.0

        SequentialAnimation on opacity {
          running: groupRow.pending
          loops: Animation.Infinite
          NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
        }
      }

      ColumnLayout {
        id: groupContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: groupRow.group ? groupRow.group.project : ""
          color: groupRow.anyRunning ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.groupSummary(groupRow.group) + (groupRow.group && groupRow.group.workingDir ? " · " + groupRow.group.workingDir : "")
          color: groupRow.unhealthy ? root.warning : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      PanelActionButton {
        iconText: "󰈙"
        tooltipText: "Project logs"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: docker.openGroupLogs(groupRow.host, groupRow.group)
      }

      PanelActionButton {
        iconText: "󰑐"
        tooltipText: "Restart project"
        visible: groupRow.anyRunning
        enabled: !docker.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: docker.groupAction(groupRow.host, groupRow.group, "restart")
      }

      PanelActionButton {
        iconText: groupRow.allRunning ? "󰓛" : "󰐊"
        tooltipText: groupRow.allRunning ? "Stop project (d)" : "Start project (u)"
        enabled: !docker.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: docker.groupAction(groupRow.host, groupRow.group, groupRow.allRunning ? "stop" : "start")
      }
    }
  }

  component ContainerRow: CursorSurface {
    id: row
    property var host: null
    property var group: null
    property var container: null
    property bool striped: false
    property bool indented: false
    readonly property string key: host && container ? String(host.name) + "/" + String(container.id) : ""
    readonly property int flatIndex: key !== "" ? root.rowIndexOf(key) : -1
    readonly property bool pending: docker.isPending(host, container) || docker.isGroupPending(host, group)
    readonly property bool unhealthy: container && (container.health === "unhealthy" || container.state === "dead")
    readonly property color stateColor: {
      if (!container) return root.dim
      if (unhealthy) return root.warning
      if (container.running) return root.foreground
      return root.dim
    }
    readonly property string statusText: {
      if (!container) return ""
      var s = container.status
      if (container.project !== "" && !(group && group.header)) s = container.project + " · " + s
      if (container.service !== "" && group && group.header && container.service !== container.name) s = container.service + " · " + s
      return s
    }
    property int menuIndex: 0
    readonly property var menuItems: buildMenuItems()

    // Everything the row can do, in one list, so mouse menu and keys agree.
    function buildMenuItems() {
      if (!container) return []
      var items = []
      var ports = container.published || []
      for (var p = 0; p < ports.length && p < 4; p++) {
        items.push({ icon: "󰖟", label: "Open " + Model.portUrl(host ? host.endpoint : "", ports[p]), kind: "port", port: ports[p] })
      }
      items.push({ icon: "󰈙", label: "Logs", kind: "logs" })
      if (container.running) items.push({ icon: "󰆍", label: "Shell", kind: "shell" })
      items.push({ icon: "󰋽", label: "Inspect", kind: "inspect" })
      if (container.running) items.push({ icon: "󰑐", label: "Restart", kind: "restart" })
      items.push({ icon: container.running ? "󰓛" : "󰐊", label: container.running ? "Stop" : "Start", kind: "toggle" })
      items.push({ icon: "󰆏", label: "Copy name", kind: "copy-name" })
      items.push({ icon: "󰆏", label: "Copy ID  " + container.shortId, kind: "copy-id" })
      items.push({ icon: "󰅖", label: container.running ? "Kill…" : "Remove…", kind: "destroy", destructive: true })
      return items
    }

    function openMenu() {
      if (menuItems.length === 0) return
      menuIndex = 0
      if (flatIndex >= 0) root.setCursor(flatIndex)
      menuPopup.open()
    }

    function runMenuItem(item) {
      menuPopup.close()
      if (!item) return
      var r = { kind: "container", host: host, group: group, container: container, key: key }
      if (item.kind === "port") docker.openPort(host, item.port)
      else if (item.kind === "logs") docker.openLogs(host, container)
      else if (item.kind === "shell") docker.openShell(host, container)
      else if (item.kind === "inspect") docker.openInspect(host, container)
      else if (item.kind === "restart") docker.restartContainer(host, container)
      else if (item.kind === "toggle") docker.toggleContainer(host, container)
      else if (item.kind === "copy-name") docker.copyToClipboard(container.name)
      else if (item.kind === "copy-id") docker.copyToClipboard(container.id)
      else if (item.kind === "destroy") root.requestDestroy(r)
    }

    hasCursor: root.cursorActive && root.cursorIndex === flatIndex && flatIndex >= 0
    foreground: root.foreground
    fill: root.hoverFill
    color: hasCursor ? fill : (current ? currentFill : (striped ? root.stripeFill : "transparent"))

    implicitHeight: Math.max(content.implicitHeight, toggleButton.implicitHeight) + Style.spacing.rowPaddingX

    Component.onCompleted: if (key !== "") root.registerRow(key, row)
    Component.onDestruction: if (key !== "") root.unregisterRow(key)

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && row.flatIndex >= 0) root.setCursor(row.flatIndex)
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) docker.copyToClipboard(row.container.name)
        else if (mouse.button === Qt.RightButton) row.openMenu()
      }
    }

    Popup {
      id: menuPopup
      x: Math.max(0, Math.min(row.width - width - Style.space(6), row.width * 0.55))
      y: row.height - Style.space(4)
      width: Style.space(300)
      padding: 0
      modal: false
      focus: true
      closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
      onOpenedChanged: {
        root.menuOpen = opened
        if (opened) Qt.callLater(function() { menuContent.forceActiveFocus() })
        else if (root.opened && !root.confirmOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }
      background: BorderSurface {
        color: Color.background
        borderSpec: Border.flat(root.dim, 1)
        radius: Style.cornerRadius
      }

      contentItem: Column {
        id: menuContent
        width: parent.width
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { menuPopup.close(); event.accepted = true }
          else if (event.key === Qt.Key_Down || event.text === "j") { row.menuIndex = Math.min(row.menuItems.length - 1, row.menuIndex + 1); event.accepted = true }
          else if (event.key === Qt.Key_Up || event.text === "k") { row.menuIndex = Math.max(0, row.menuIndex - 1); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { row.runMenuItem(row.menuItems[row.menuIndex]); event.accepted = true }
        }

        Repeater {
          model: row.menuItems
          MenuChoice {
            required property var modelData
            required property int index
            width: parent.width
            icon: String(modelData.icon || "")
            label: String(modelData.label || "")
            destructive: modelData.destructive === true
            selected: row.menuIndex === index
            onHovered: row.menuIndex = index
            onChosen: row.runMenuItem(modelData)
          }
        }
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(row.indented ? 22 : 10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        id: stateGlyph
        textFormat: Text.PlainText
        text: Model.stateGlyph(row.container)
        color: row.stateColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
        opacity: row.pending ? 0.45 : 1.0

        SequentialAnimation on opacity {
          running: row.pending
          loops: Animation.Infinite
          NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
        }
      }

      ColumnLayout {
        id: content
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.container ? row.container.name : ""
          color: row.container && row.container.running ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        RowLayout {
          Layout.fillWidth: true
          visible: row.container && (row.container.image !== "" || row.container.published.length > 0)
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            Layout.maximumWidth: implicitWidth
            text: row.container ? row.container.image : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Repeater {
            model: row.container ? row.container.published.slice(0, 4) : []
            PortChip {
              required property var modelData
              port: modelData
              host: row.host
            }
          }

          Text {
            visible: row.container && row.container.published.length > 4
            text: "+" + (row.container ? row.container.published.length - 4 : 0)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item { Layout.fillWidth: true }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: row.statusText
          color: row.unhealthy ? root.warning : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Item {
        id: statsColumn
        visible: docker.showStats && row.container && row.container.running && row.container.stats !== null
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(58)
        implicitWidth: Style.space(58)
        implicitHeight: statsInner.implicitHeight

        Column {
          id: statsInner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "󰘚 " + Model.cpuText(row.container)
            color: row.container && row.container.stats && row.container.stats.cpu >= 80 ? root.warning : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "󰍛 " + Model.memText(row.container)
            color: row.container && row.container.stats && row.container.stats.memPerc >= 80 ? root.warning : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }
        }

        MouseArea {
          id: statsMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
          visible: statsMouse.containsMouse
          text: Model.statsTooltip(row.container)
          fontFamily: root.fontFamily
        }
      }

      PanelActionButton {
        iconText: "󰈙"
        tooltipText: "Logs"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: docker.openLogs(row.host, row.container)
      }

      PanelActionButton {
        iconText: "󰆍"
        tooltipText: "Shell"
        visible: row.container && row.container.running
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: docker.openShell(row.host, row.container)
      }

      PanelActionButton {
        iconText: "󰑐"
        tooltipText: "Restart"
        visible: row.container && row.container.running
        enabled: !docker.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: docker.restartContainer(row.host, row.container)
      }

      PanelActionButton {
        id: toggleButton
        iconText: row.container && row.container.running ? "󰓛" : "󰐊"
        tooltipText: row.container && row.container.running ? "Stop" : (row.container && row.container.state === "paused" ? "Unpause" : "Start")
        enabled: !docker.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: docker.toggleContainer(row.host, row.container)
      }
    }
  }

  // "8080->80" that opens http://host:8080 in the browser.
  component PortChip: Text {
    id: chip
    property var port: null
    property var host: null
    readonly property string url: Model.portUrl(host ? host.endpoint : "", port)
    textFormat: Text.PlainText
    text: port ? port.host + "→" + port.container : ""
    color: chipMouse.containsMouse ? root.foreground : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: chipMouse.containsMouse

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      anchors.margins: -Style.space(2)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: docker.openUrl(chip.url)
    }

    PanelToolTip {
      visible: chipMouse.containsMouse
      text: chip.url
      fontFamily: root.fontFamily
    }
  }

  component MenuChoice: CursorSurface {
    id: choice
    signal chosen()
    signal hovered()
    property string icon: ""
    property string label: ""
    property bool selected: false
    property bool destructive: false

    foreground: root.foreground
    hasCursor: selected
    implicitHeight: Style.space(34)
    radius: 0

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: choice.hovered()
      onClicked: choice.chosen()
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(10)

      Text {
        text: choice.icon
        color: choice.destructive ? root.warning : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: choice.label
        color: choice.destructive ? root.warning : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideMiddle
      }
    }
  }
}
