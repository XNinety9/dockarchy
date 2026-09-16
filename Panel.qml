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

  // Keyboard cursor walks one flat list of rows across every host section so
  // j/k never has to know where one server ends and the next begins.
  property int cursorIndex: 0
  property bool cursorActive: false

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

  // [{host, container}] in display order — the model the cursor indexes into.
  readonly property var rows: flattenRows()

  function flattenRows() {
    var out = []
    for (var h = 0; h < docker.hosts.length; h++) {
      var host = docker.hosts[h]
      for (var c = 0; c < host.containers.length; c++) out.push({ host: host, container: host.containers[c] })
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

  function activateCursor() {
    var row = selectedRow()
    if (row) docker.toggleContainer(row.host, row.container)
  }

  function rowIndexOf(hostName, containerId) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].host.name === hostName && rows[i].container.id === containerId) return i
    }
    return -1
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
    var row = selectedRow()
    if (!row) return
    var item = rowItems[row.host.name + "/" + row.container.id]
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
  }
  onRowsChanged: ensureCursor()

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
    function version(): string { return "0.3.0" }
    function running(): string { return String(docker.counts.running) }
    function settings(): string { return JSON.stringify({ settings: root.settings, contexts: docker.contexts }) }
    // omarchy-shell x99.dockarchy action <context> <container name or id> <start|stop|restart|pause|unpause>
    function action(context: string, container: string, verb: string): string {
      var found = docker.findContainer(context, container)
      if (!found) return "unknown container: " + context + "/" + container
      docker.containerAction(found.host, found.container, verb)
      return docker.pendingActionKey !== "" ? "ok" : "rejected"
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight + footer.implicitHeight, Style.space(root.panelMaxHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy > 0 ? 1 : -1)
        // PanelKeyCatcher turns `l`/→ into a horizontal move before textKey
        // ever sees it; on a container row that means "open logs".
        else if (dx > 0) { var row = root.selectedRow(); if (row) docker.openLogs(row.host, row.container) }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var row = root.selectedRow()
        if (t === "R") docker.refresh()
        else if (t === "r" && row) docker.restartContainer(row.host, row.container)
        else if (t === "s" && row) docker.openShell(row.host, row.container)
        else if (t === "c" && row) docker.copyToClipboard(row.container.name)
        else if (t === "L") docker.openLazydocker(row ? row.host : null)
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: 0

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

          Repeater {
            model: docker.hosts
            HostSection {
              required property var modelData
              required property int index
              width: column.width
              host: modelData
              hostIndex: index
            }
          }
        }
      }

      // Sticky footer: stays visible however long the container list gets.
      Column {
        id: footer
        Layout.fillWidth: true
        spacing: Style.space(6)

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        Text {
          width: parent.width
          text: "j/k move · ⏎ start/stop · l logs · r restart · s shell · c copy name · R refresh · L lazydocker"
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
    property var host: null
    property int hostIndex: 0
    readonly property string hostName: host ? String(host.name) : ""
    readonly property string hint: host ? Model.errorHint(host.error) : ""
    spacing: Style.space(10)

    PanelSeparator {
      width: parent.width
      foreground: root.foreground
    }

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      Text {
        text: Model.hostGlyph(section.host)
        color: section.host && section.host.ok ? root.foreground : root.warning
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        PanelSectionHeader {
          Layout.fillWidth: true
          text: section.hostName.toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: section.host && section.host.endpoint !== ""
          text: section.host ? section.host.endpoint : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: section.host && section.host.ok
        text: section.host ? section.host.counts.running + "/" + section.host.counts.total : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      PanelActionButton {
        iconText: "󰆍"
        tooltipText: "lazydocker on " + section.hostName
        foreground: root.foreground
        fontFamily: root.fontFamily
        visible: section.host && section.host.ok
        onClicked: docker.openLazydocker(section.host)
      }
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
      visible: section.host && section.host.ok && section.host.containers.length === 0
      width: parent.width
      text: docker.showAll ? "No containers on this host." : "No running containers on this host."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }

    Column {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: section.host ? section.host.containers : []
        ContainerRow {
          required property var modelData
          required property int index
          width: parent.width
          host: section.host
          container: modelData
          striped: root.alternateRows && index % 2 === 1
        }
      }
    }
  }

  component ContainerRow: CursorSurface {
    id: row
    property var host: null
    property var container: null
    property bool striped: false
    readonly property string key: host && container ? String(host.name) + "/" + String(container.id) : ""
    readonly property int flatIndex: host && container ? root.rowIndexOf(host.name, container.id) : -1
    readonly property bool pending: docker.isPending(host, container)
    readonly property bool unhealthy: container && (container.health === "unhealthy" || container.state === "dead")
    readonly property color stateColor: {
      if (!container) return root.dim
      if (unhealthy) return root.warning
      if (container.running) return root.foreground
      return root.dim
    }
    readonly property string detailText: {
      if (!container) return ""
      var parts = []
      if (container.image !== "") parts.push(container.image)
      if (container.ports !== "") parts.push(container.ports)
      return parts.join(" · ")
    }
    readonly property string statusText: {
      if (!container) return ""
      var s = container.status
      if (container.project !== "") s = container.project + " · " + s
      return s
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
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && row.flatIndex >= 0) root.setCursor(row.flatIndex)
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) docker.copyToClipboard(row.container.name)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
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

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: row.detailText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
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
}
