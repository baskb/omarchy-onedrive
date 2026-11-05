import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// OneDrive in the bar: one cloud icon with the sync percentage and a thin
// progress line while a long run is on, and one panel with the run, the
// current file, the sync details, recent files, pause/resume, and a settings
// view behind the gear where every part can be switched off.
Panel {
  id: root
  moduleName: "baskb.onedrive"
  ipcTarget: "baskb.onedrive"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Items inside the panel's lazily built content, null until it first opens.
  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property Item fileColumn: panel.loadedContent ? panel.loadedContent.fileColumn : null
  readonly property Item settingsColumn: panel.loadedContent ? panel.loadedContent.settingsColumn : null

  // A setting changed in the panel shows at once; the bar hands the saved
  // copy back through `settings` once shell.json has been rewritten.
  property var overrides: ({})
  onSettingsChanged: overrides = ({})
  readonly property var effectiveSettings: {
    var out = {}
    var base = settings || {}
    for (var k in base) out[k] = base[k]
    for (var o in overrides) out[o] = overrides[o]
    return out
  }

  function opt(name, fallback) {
    var v = effectiveSettings[name]
    return v === undefined || v === null ? fallback : v
  }
  function optBool(name, fallback) { return Model.boolValue(opt(name, fallback), fallback) }
  function optInt(name, fallback, min, max) {
    var n = parseInt(String(opt(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }
  function saveSetting(key, value) {
    var next = {}
    for (var k in overrides) next[k] = overrides[k]
    next[key] = value
    overrides = next
    Quickshell.execDetached(["omarchy-shell", "shell", "setBarWidget", root.moduleName, String(key), JSON.stringify(value), "{}"])
  }

  // The settings view, top to bottom. Headers and info rows are not focusable.
  readonly property var settingRows: [
    { key: "display", type: "header" },
    { key: "showPercentInBar", type: "bool", def: true },
    { key: "showBarProgress", type: "bool", def: true },
    { key: "showRunCard", type: "bool", def: true },
    { key: "runBarMinSec", type: "int", def: 60, min: 0, max: 3600, step: 10 },
    { key: "showTransferCard", type: "bool", def: true },
    { key: "showSyncDetails", type: "bool", def: true },
    { key: "showStorage", type: "bool", def: false },
    { key: "showRecent", type: "bool", def: true },
    { key: "recentLimit", type: "int", def: 12, min: 1, max: 50, step: 1 },
    { key: "showActions", type: "bool", def: true },
    { key: "notifyOnFailure", type: "bool", def: true },
    { key: "client", type: "header" },
    { key: "startAtLogin", type: "system", def: true },
    { key: "checkUpdates", type: "bool", def: true },
    { key: "updateCheckHours", type: "int", def: 6, min: 1, max: 168, step: 1 },
    { key: "update", type: "info" },
    { key: "checkUpdate", type: "action", glyph: "󰓦" },
    { key: "installUpdate", type: "action", glyph: "󰇚" },
    { key: "openConfig", type: "action", glyph: "󰏫" },
    { key: "openSyncList", type: "action", glyph: "󰈙" },
    { key: "reauth", type: "action", glyph: "󰍂" },
    { key: "version", type: "info" }
  ]

  readonly property bool showPercentInBar: optBool("showPercentInBar", true)
  readonly property bool showBarProgress: optBool("showBarProgress", true)
  readonly property bool showRunCard: optBool("showRunCard", true)
  readonly property bool showTransferCard: optBool("showTransferCard", true)
  readonly property bool showSyncDetails: optBool("showSyncDetails", true)
  readonly property bool showStorage: optBool("showStorage", false)
  readonly property bool showRecent: optBool("showRecent", true)
  readonly property bool showActions: optBool("showActions", true)

  property bool settingsOpen: false
  property string focusSection: "header"   // header | actions | files | settings
  property int headerIndex: 0              // 0 pause switch, 1 gear
  property int actionIndex: 0
  property int fileIndex: 0
  property int settingIndex: 1
  property bool cursorActive: false
  property double nowMs: Date.now()

  readonly property var actions: {
    var list = [
      { id: "folder", key: "action.openFolder", glyph: "󰉋" },
      { id: "restart", key: "action.restart", glyph: "󰜉" },
      { id: "status", key: "action.syncStatus", glyph: "󰓦" }
    ]
    if (showStorage) list.push({ id: "quota", key: "action.quota", glyph: "󰋊" })
    if (onedrive.updateAvailable) list.push({ id: "update", key: "action.update", glyph: "󰇚" })
    return list
  }
  readonly property int actionCount: actions.length
  readonly property bool actionsShown: showActions && onedrive.installed
  readonly property bool filesShown: showRecent && onedrive.recent.length > 0

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Commons.Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string state: onedrive.state
  readonly property bool syncing: state === "syncing"
  readonly property bool attention: state === "degraded" || state === "offline" || onedrive.lastError !== ""
  readonly property color iconColor: onedrive.active ? foreground : dim
  readonly property color barIconColor: onedrive.active ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && onedrive.installed
  readonly property string homeDir: Quickshell.env("HOME")
  readonly property real runFraction: onedrive.runEstimate ? onedrive.runEstimate.fraction : 0

  // The bar figure is the whole run while one is worth watching, else the
  // file in flight.
  readonly property string barLabel: {
    if (!showPercentInBar) return ""
    if (onedrive.runShown) return Commons.I18n.formatNumber(Math.floor(runFraction * 100)) + "%"
    if (onedrive.transfer) return Commons.I18n.formatNumber(onedrive.transfer.percent) + "%"
    return ""
  }
  readonly property string runLeftText: onedrive.runShown
    ? strings.t("run.left").arg(Model.formatDuration(onedrive.runEstimate.remainingSec, strings.t, Commons.I18n.formatNumber))
    : ""

  readonly property string heroMeta: {
    var t = onedrive.transfer
    if (state === "syncing") {
      if (onedrive.runShown) return strings.t("state.syncing") + " · " + runLeftText
      if (t) return strings.t(t.direction === "upload" ? "meta.uploading" : "meta.downloading").arg(Model.fileName(t.path))
      if (onedrive.phase === "remote") return strings.t("state.remote")
      if (onedrive.phase === "scan") return strings.t("state.scanning")
      return strings.t("state.syncing")
    }
    if (state === "idle" && onedrive.lastSuccessfulSyncMs > 0)
      return strings.t("meta.lastSync").arg(Model.relativeTime(onedrive.lastSuccessfulSyncMs, nowMs, strings.t, Commons.I18n.formatNumber))
    return strings.t("state." + state)
  }

  readonly property string barTooltip: strings.t("title") + " · " + heroMeta
  readonly property string toggleHint: onedrive.active ? strings.t("action.pause") : strings.t("action.resume")

  readonly property string lastCycleText: {
    var result = onedrive.lastCycleResult
    if (result === "") return strings.t("info.never")
    var text = strings.t("result." + result, result)
    if (onedrive.lastCycleFailures > 0) text += " (" + Commons.I18n.formatNumber(onedrive.lastCycleFailures) + ")"
    return text
  }

  readonly property string storageText: {
    if (onedrive.quotaBusy && !onedrive.quota) return strings.t("info.loading")
    if (onedrive.quota && onedrive.quota.total > 0)
      return strings.t("info.usedOfTotal").arg(Model.formatBytes(onedrive.quota.used, Commons.I18n.formatNumber)).arg(Model.formatBytes(onedrive.quota.total, Commons.I18n.formatNumber))
    if (onedrive.quota) return Model.formatBytes(onedrive.quota.used, Commons.I18n.formatNumber)
    if (onedrive.quotaError !== "") return strings.t("error.quota")
    return "—"
  }
  readonly property real storageFraction: onedrive.quota && onedrive.quota.total > 0
    ? Math.max(0, Math.min(1, onedrive.quota.used / onedrive.quota.total)) : 0

  // The settings view's "Client update" line.
  readonly property string updateText: {
    if (onedrive.updateBusy) return strings.t("update.checking")
    var u = onedrive.updateInfo
    if (!u) return onedrive.updateError !== "" ? strings.t("update.failed") : strings.t("update.never")
    var when = Model.relativeTime(onedrive.updateCheckedAtMs, nowMs, strings.t, Commons.I18n.formatNumber)
    var text
    if (u.aurNewer) text = strings.t("update.available").arg(u.aur)
    else if (u.upstreamNewer) text = strings.t("update.upstreamOnly").arg(u.upstream)
    else text = strings.t("update.upToDate")
    return text + " · " + when
  }

  readonly property string folderText: onedrive.syncDir.indexOf(homeDir) === 0
    ? "~" + onedrive.syncDir.substring(homeDir.length) : onedrive.syncDir

  // ---- keyboard cursor -------------------------------------------------

  function settingVisible(index) {
    var row = settingRows[index]
    if (!row) return false
    if (row.key === "installUpdate") return onedrive.updateAvailable
    return true
  }

  function settingFocusable(index) {
    var row = settingRows[index]
    return !!row && settingVisible(index) && row.type !== "header" && row.type !== "info"
  }

  function nextSettingIndex(from, dir) {
    var i = from
    for (var n = 0; n < settingRows.length; n++) {
      i += dir
      if (i < 0 || i >= settingRows.length) return from
      if (settingFocusable(i)) return i
    }
    return from
  }

  function ensureCursor() {
    if (settingsOpen) {
      focusSection = "settings"
      if (!settingFocusable(settingIndex)) settingIndex = nextSettingIndex(-1, 1)
      return
    }
    if (focusSection === "settings") focusSection = "header"
    if (focusSection === "files" && !filesShown) focusSection = actionsShown ? "actions" : "header"
    if (focusSection === "actions" && !actionsShown) focusSection = "header"
    if (fileIndex >= onedrive.recent.length) fileIndex = Math.max(0, onedrive.recent.length - 1)
    if (fileIndex < 0) fileIndex = 0
    actionIndex = Math.max(0, Math.min(actionCount - 1, actionIndex))
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (focusSection === "settings") {
      if (dy !== 0) { settingIndex = nextSettingIndex(settingIndex, dy); scrollCursorIntoView() }
      else if (dx !== 0) adjustSetting(settingIndex, dx)
      return
    }
    if (focusSection === "header") {
      if (dx !== 0) headerIndex = headerIndex === 0 ? 1 : 0
      else if (dy > 0) {
        if (actionsShown) focusSection = "actions"
        else if (filesShown) { focusSection = "files"; fileIndex = 0; scrollCursorIntoView() }
      }
      return
    }
    if (focusSection === "actions") {
      if (dx !== 0) actionIndex = Math.max(0, Math.min(actionCount - 1, actionIndex + dx))
      else if (dy < 0) setHeaderCursor(0)
      else if (dy > 0 && filesShown) { focusSection = "files"; fileIndex = 0; scrollCursorIntoView() }
      return
    }
    if (focusSection === "files") {
      if (dy < 0 && fileIndex === 0) { focusSection = actionsShown ? "actions" : "header"; return }
      if (dy !== 0) {
        fileIndex = Math.max(0, Math.min(onedrive.recent.length - 1, fileIndex + dy))
        scrollCursorIntoView()
      }
    }
  }

  function setHeaderCursor(index) {
    cursorActive = true
    focusSection = "header"
    headerIndex = index === undefined ? headerIndex : index
    if (panelFlick) panelFlick.contentY = 0
  }

  function setActionCursor(index) {
    cursorActive = true
    focusSection = "actions"
    actionIndex = index
  }

  function setFileCursor(index) {
    cursorActive = true
    focusSection = "files"
    fileIndex = index
    scrollCursorIntoView()
  }

  function setSettingCursor(index) {
    cursorActive = true
    focusSection = "settings"
    settingIndex = index
  }

  function toggleRunning() {
    if (onedrive.installed && !onedrive.busy) onedrive.toggleRunning()
  }

  function toggleSettings() {
    settingsOpen = !settingsOpen
    if (panelFlick) panelFlick.contentY = 0
    if (settingsOpen) {
      focusSection = "settings"
      settingIndex = nextSettingIndex(-1, 1)
      onedrive.refreshEnabled()
      onedrive.refreshVersion()
      onedrive.checkUpdates(false)
    } else {
      focusSection = "header"
      headerIndex = 1
    }
  }

  function runAction(index) {
    var action = actions[index]
    if (!action) return
    if (action.id === "folder") onedrive.openFolder()
    else if (action.id === "restart") onedrive.restart()
    else if (action.id === "status") onedrive.checkSyncStatus()
    else if (action.id === "quota") onedrive.refreshQuota(true)
    else if (action.id === "update") onedrive.installUpdate()
  }

  function activateSetting(index) {
    var row = settingRows[index]
    if (!row) return
    if (row.type === "bool") saveSetting(row.key, !optBool(row.key, row.def))
    else if (row.type === "system") onedrive.setStartAtLogin(!onedrive.unitEnabled)
    else if (row.type === "action") {
      if (row.key === "openConfig") onedrive.openConfig()
      else if (row.key === "openSyncList") onedrive.openSyncList()
      else if (row.key === "reauth") onedrive.reauth()
      else if (row.key === "checkUpdate") onedrive.checkUpdates(true)
      else if (row.key === "installUpdate") onedrive.installUpdate()
    }
  }

  function adjustSetting(index, dir) {
    var row = settingRows[index]
    if (!row || row.type !== "int") return
    var value = optInt(row.key, row.def, row.min, row.max) + dir * row.step
    saveSetting(row.key, Math.max(row.min, Math.min(row.max, value)))
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "settings") activateSetting(settingIndex)
    else if (focusSection === "header") { if (headerIndex === 1) toggleSettings(); else toggleRunning() }
    else if (focusSection === "actions") runAction(actionIndex)
    else if (focusSection === "files") onedrive.openFile(selectedFile())
  }

  function selectedFile() {
    if (onedrive.recent.length === 0) return null
    return onedrive.recent[Math.max(0, Math.min(fileIndex, onedrive.recent.length - 1))]
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
    if (focusSection === "files" && fileColumn && fileIndex >= 0 && fileIndex < fileColumn.children.length)
      scrollItemIntoView(fileColumn.children[fileIndex])
    else if (focusSection === "settings" && settingsColumn && settingIndex >= 0 && settingIndex < settingsColumn.children.length)
      scrollItemIntoView(settingsColumn.children[settingIndex])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    settingsOpen = false
    focusSection = "header"
    headerIndex = 0
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    onedrive.refresh()
    if (showStorage) onedrive.refreshQuota(false)
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }
  onFileIndexChanged: scrollCursorIntoView()
  onSettingIndexChanged: scrollCursorIntoView()

  Service {
    id: onedrive
    settings: root.effectiveSettings
  }

  Connections {
    target: onedrive
    function onRecentChanged() { root.ensureCursor() }
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function settings(): void { root.open(); if (!root.settingsOpen) root.toggleSettings() }
    function refresh(): string { onedrive.refresh(); onedrive.refreshQuota(true); return "ok" }
    function pause(): string { onedrive.pause(); return "ok" }
    function resume(): string { onedrive.resume(); return "ok" }
    function restart(): string { onedrive.restart(); return "ok" }
    function folder(): string { onedrive.openFolder(); return "ok" }
    function check(): string { onedrive.checkSyncStatus(); return "ok" }
    function checkResult(): string { return onedrive.syncStatusBusy ? "checking" : onedrive.syncStatusText }
    function checkUpdates(): string { onedrive.checkUpdates(true); return "ok" }
    function updates(): string { return root.updateText }
    function status(): string { return onedrive.statusText }
    function set(key: string, valueJson: string): string {
      try { root.saveSetting(key, JSON.parse(valueJson)); return "ok" } catch (e) { return "invalid value: " + e }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelText: root.barLabel
    tooltipText: root.barTooltip
    iconComponent: Component {
      Item {
        OneDriveIcon {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize / aspectRatio * 1.15
          color: root.barIconColor
          badgeColor: root.urgent
          crossed: onedrive.installed && !onedrive.active
          warning: root.attention
          pulsing: root.syncing
        }

        // A thin line under the cloud that fills with the run.
        Rectangle {
          id: barTrack
          visible: root.showBarProgress && onedrive.runShown
          x: (parent.width - width) / 2
          y: parent.height - height - 1
          width: Math.round(button.iconSize * 1.2)
          height: 2
          radius: 1
          color: root.barIconColor
          opacity: 0.3
        }
        Rectangle {
          visible: barTrack.visible
          x: barTrack.x
          y: barTrack.y
          width: Math.round(barTrack.width * root.runFraction)
          height: barTrack.height
          radius: 1
          color: root.barIconColor
          Behavior on width { NumberAnimation { duration: Style.duration(300); easing.type: Easing.OutCubic } }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleRunning()
      else if (buttonCode === Qt.MiddleButton) onedrive.openFolder()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(600))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias fileColumn: fileColumn
      property alias settingsColumn: settingsColumn
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; root.ensureCursor(); return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: { if (root.settingsOpen) root.toggleSettings(); else root.close() }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "p") root.toggleRunning()
        else if (k === "o") onedrive.openFolder()
        else if (k === "r") onedrive.restart()
        else if (k === "c") onedrive.checkSyncStatus()
        else if (k === "q" && root.showStorage) onedrive.refreshQuota(true)
        else if (k === "s") root.toggleSettings()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
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

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor

            PanelHero {
              id: hero
              width: parent.width
              title: root.settingsOpen ? strings.t("settings.title") : strings.t("title")
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: onedrive.active ? 1.0 : 0.5
              iconComponent: Component {
                OneDriveIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                  badgeColor: root.urgent
                  crossed: onedrive.installed && !onedrive.active
                  warning: root.attention
                  pulsing: root.syncing
                }
              }
              trailingControl: Component {
                Row {
                  spacing: Style.space(10)

                  PanelActionButton {
                    id: gearButton
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰒓"
                    tooltipText: root.settingsOpen ? strings.t("settings.close") : strings.t("settings.open")
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    fontSize: Style.font.subtitle * 1.3
                    hasCursor: header.ringVisible && root.headerIndex === 1
                    onHovered: function(on) { if (on) root.setHeaderCursor(1) }
                    onClicked: root.toggleSettings()
                  }

                  ToggleSwitch {
                    id: powerSwitch
                    anchors.verticalCenter: parent.verticalCenter
                    visible: onedrive.installed
                    checked: onedrive.active
                    busy: onedrive.busy
                    hasCursor: header.ringVisible && root.headerIndex === 0
                    foreground: hero.foreground
                    onHovered: function(on) { if (on) root.setHeaderCursor(0) }
                    onToggled: root.toggleRunning()

                    PanelToolTip {
                      visible: powerSwitch.containsMouse
                      text: root.toggleHint
                      fontFamily: hero.fontFamily
                    }
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !onedrive.installed
            width: parent.width
            text: strings.t("hint.notInstalled")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: onedrive.lastError !== ""
            width: parent.width
            text: onedrive.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          // ---------------------------------------------------- status view
          Column {
            id: mainView
            visible: !root.settingsOpen
            width: parent.width
            spacing: Style.space(12)

            // The whole run: announced files done so far and the time left,
            // only when the run is projected past the configured threshold.
            Column {
              id: runCard
              visible: root.showRunCard && onedrive.runShown
              width: parent.width
              spacing: Style.space(6)
              readonly property var est: onedrive.runEstimate || ({ done: 0, total: 0, fraction: 0, remainingSec: -1 })

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: strings.t("run.title")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: strings.t("run.progress")
                      .arg(Commons.I18n.formatNumber(runCard.est.done))
                      .arg(Commons.I18n.formatNumber(runCard.est.total))
                      + " · " + root.runLeftText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: Commons.I18n.formatNumber(Math.floor(runCard.est.fraction * 100)) + "%"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  Layout.alignment: Qt.AlignVCenter
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: height / 2
                color: root.track

                Rectangle {
                  width: parent.width * runCard.est.fraction
                  height: parent.height
                  radius: height / 2
                  color: root.foreground
                  Behavior on width {
                    NumberAnimation { duration: Style.duration(300); easing.type: Easing.OutCubic }
                  }
                }
              }
            }

            // The file moving right now, with its progress bar.
            Column {
              id: transferCard
              visible: root.showTransferCard && onedrive.transfer !== null
              width: parent.width
              spacing: Style.space(6)
              readonly property var transfer: onedrive.transfer || ({ direction: "upload", path: "", percent: 0, eta: "" })

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: Model.directionGlyph(transferCard.transfer.direction)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: Model.fileName(transferCard.transfer.path)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideMiddle
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: strings.t(transferCard.transfer.direction === "upload" ? "transfer.upload" : "transfer.download")
                      + " · " + Model.folderOf(transferCard.transfer.path)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: Commons.I18n.formatNumber(transferCard.transfer.percent) + "%"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  Layout.alignment: Qt.AlignVCenter
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: root.track

                Rectangle {
                  width: parent.width * transferCard.transfer.percent / 100
                  height: parent.height
                  radius: height / 2
                  color: root.foreground
                  Behavior on width {
                    NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: Model.shortEta(transferCard.transfer.eta) !== ""
                width: parent.width
                text: strings.t("transfer.eta").arg(Model.shortEta(transferCard.transfer.eta))
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignRight
              }
            }

            Column {
              visible: onedrive.installed && (root.showSyncDetails || root.showStorage)
              width: parent.width
              spacing: Style.spacing.labelGap

              InfoPair {
                visible: root.showSyncDetails
                label: strings.t("info.lastSync")
                value: onedrive.lastSuccessfulSyncMs > 0
                  ? Model.relativeTime(onedrive.lastSuccessfulSyncMs, root.nowMs, strings.t, Commons.I18n.formatNumber)
                  : strings.t("info.never")
              }
              InfoPair { visible: root.showSyncDetails; label: strings.t("info.lastCycle"); value: root.lastCycleText }
              InfoPair {
                visible: root.showSyncDetails
                label: strings.t(onedrive.runActive ? "info.thisRun" : "info.lastRun")
                value: strings.t("cycle.summary")
                  .arg(Commons.I18n.formatNumber(onedrive.runDoneUpload))
                  .arg(Commons.I18n.formatNumber(onedrive.runDoneDownload))
                  .arg(Commons.I18n.formatNumber(onedrive.runFailed))
              }
              InfoPair {
                visible: root.showSyncDetails && onedrive.pendingUploads > 0
                label: strings.t("info.pending")
                value: Commons.I18n.formatNumber(onedrive.pendingUploads)
              }
              InfoPair {
                visible: root.showSyncDetails && onedrive.successfulCycles > 0
                label: strings.t("info.cycles")
                value: Commons.I18n.formatNumber(onedrive.successfulCycles)
              }
              InfoPair {
                visible: root.showSyncDetails && onedrive.monitorIntervalSec > 0
                label: strings.t("info.interval")
                value: strings.t("info.everySeconds").arg(Commons.I18n.formatNumber(onedrive.monitorIntervalSec))
              }
              InfoPair { visible: root.showSyncDetails; label: strings.t("info.folder"); value: root.folderText }
              InfoPair {
                visible: onedrive.updateAvailable
                label: strings.t("info.clientUpdate")
                value: strings.t("update.available").arg(onedrive.updateVersion)
              }
              InfoPair { visible: root.showStorage; label: strings.t("info.storage"); value: root.storageText }

              Rectangle {
                visible: root.showStorage && root.storageFraction > 0
                width: parent.width
                height: Style.space(3)
                radius: height / 2
                color: root.track

                Rectangle {
                  width: parent.width * root.storageFraction
                  height: parent.height
                  radius: height / 2
                  color: root.storageFraction > 0.9 ? root.urgent : root.foreground
                  opacity: 0.8
                }
              }
            }

            RowLayout {
              visible: root.actionsShown
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.actions
                Button {
                  required property var modelData
                  required property int index
                  text: strings.t(modelData.key)
                  iconText: modelData.glyph
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  Layout.fillWidth: true
                  tooltipText: modelData.id === "update" ? strings.t("action.update.hint").arg(onedrive.updateVersion) : strings.t(modelData.key + ".hint")
                  hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === index
                  enabled: !(modelData.id === "quota" && onedrive.quotaBusy) && !(modelData.id === "status" && onedrive.syncStatusBusy)
                  iconSpinning: modelData.id === "status" && onedrive.syncStatusBusy
                  onHovered: function(on) { if (on) root.setActionCursor(index) }
                  onClicked: root.runAction(index)
                }
              }
            }

            // What `onedrive --display-sync-status` answered.
            Column {
              visible: onedrive.syncStatusBusy || onedrive.syncStatusText !== ""
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: strings.t("status.title")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: onedrive.syncStatusBusy ? strings.t("status.checking") : onedrive.syncStatusText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                maximumLineCount: 4
                elide: Text.ElideRight
              }
            }

            PanelSeparator { visible: root.showRecent; foreground: root.foreground }

            Column {
              visible: root.showRecent
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: strings.t("recent.title")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                visible: onedrive.recent.length === 0
                width: parent.width
                text: strings.t("recent.empty")
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
              }

              Column {
                id: fileColumn
                visible: onedrive.recent.length > 0
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: onedrive.recent
                  FileRow {
                    required property var modelData
                    required property int index
                    width: fileColumn.width
                    entry: modelData
                    rowIndex: index
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("hint.keys")
              color: root.dim
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // -------------------------------------------------- settings view
          Column {
            id: settingsView
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.space(10)

            Column {
              id: settingsColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.settingRows
                SettingRow {
                  required property var modelData
                  required property int index
                  width: settingsColumn.width
                  row: modelData
                  rowIndex: index
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("settings.keys")
              color: root.dim
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  // One row of the settings view: a section header, a switch, a number, an
  // action button, or a read-only line, by the row's type.
  component SettingRow: Item {
    id: settingRow
    property var row: null
    property int rowIndex: 0
    readonly property string key: row ? String(row.key || "") : ""
    readonly property string type: row ? String(row.type || "") : ""
    readonly property bool hasCursor: root.cursorActive && root.focusSection === "settings" && root.settingIndex === rowIndex

    visible: root.settingVisible(rowIndex)
    implicitHeight: {
      if (type === "header") return sectionHeader.implicitHeight + Style.space(rowIndex === 0 ? 0 : 8)
      if (type === "bool" || type === "system") return toggleRow.implicitHeight
      if (type === "int") return numberRow.implicitHeight
      if (type === "action") return actionButton.implicitHeight
      return infoRow.implicitHeight
    }

    PanelSectionHeader {
      id: sectionHeader
      visible: settingRow.type === "header"
      anchors.bottom: parent.bottom
      width: parent.width
      text: strings.t("settings." + settingRow.key)
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Toggle {
      id: toggleRow
      visible: settingRow.type === "bool" || settingRow.type === "system"
      width: parent.width
      label: strings.t("setting." + settingRow.key)
      description: strings.t("setting." + settingRow.key + ".hint")
      checked: settingRow.type === "system"
        ? onedrive.unitEnabled
        : root.optBool(settingRow.key, settingRow.row && settingRow.row.def !== undefined ? settingRow.row.def : true)
      hasCursor: settingRow.hasCursor
      foreground: root.foreground
      fontFamily: root.fontFamily
      titleSize: Style.font.body
      opacity: settingRow.type === "system" && !onedrive.unitEnabledKnown ? 0.6 : 1
      onHovered: function(on) { if (on) root.setSettingCursor(settingRow.rowIndex) }
      onClicked: root.activateSetting(settingRow.rowIndex)
    }

    RowLayout {
      id: numberRow
      visible: settingRow.type === "int"
      width: parent.width
      spacing: Style.space(10)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: strings.t("setting." + settingRow.key)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: strings.t("setting." + settingRow.key + ".hint")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      NumberField {
        value: settingRow.type === "int" ? root.optInt(settingRow.key, settingRow.row.def, settingRow.row.min, settingRow.row.max) : 0
        from: settingRow.type === "int" ? settingRow.row.min : 0
        to: settingRow.type === "int" ? settingRow.row.max : 1
        stepSize: settingRow.type === "int" ? settingRow.row.step : 1
        foreground: root.foreground
        fontFamily: root.fontFamily
        hasCursor: settingRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { if (on) root.setSettingCursor(settingRow.rowIndex) }
        onModified: function(v) { root.saveSetting(settingRow.key, v) }
      }
    }

    Button {
      id: actionButton
      visible: settingRow.type === "action"
      width: parent.width
      text: settingRow.key === "installUpdate" ? strings.t("setting.installUpdate").arg(onedrive.updateVersion) : strings.t("setting." + settingRow.key)
      iconText: settingRow.row && settingRow.row.glyph ? String(settingRow.row.glyph) : ""
      tooltipText: strings.t("setting." + settingRow.key + ".hint")
      bordered: true
      leftAlign: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      hasCursor: settingRow.hasCursor
      onHovered: function(on) { if (on) root.setSettingCursor(settingRow.rowIndex) }
      onClicked: root.activateSetting(settingRow.rowIndex)
    }

    InfoPair {
      id: infoRow
      visible: settingRow.type === "info"
      width: parent.width
      label: strings.t("settings." + settingRow.key)
      value: settingRow.key === "version" ? (onedrive.version !== "" ? onedrive.version : "—")
        : (settingRow.key === "update" ? root.updateText : "")
    }
  }

  component FileRow: CursorSurface {
    id: fileRow
    property var entry: null
    property int rowIndex: 0
    readonly property string fileName: entry ? String(entry.name || "") : ""
    readonly property bool failed: entry ? entry.ok === false : false

    hasCursor: root.cursorActive && root.focusSection === "files" && root.fileIndex === rowIndex
    foreground: root.foreground

    implicitHeight: fileContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setFileCursor(fileRow.rowIndex)
      onClicked: onedrive.openFile(fileRow.entry)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.fileGlyph(fileRow.fileName)
        color: fileRow.failed ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: fileContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: fileRow.fileName
          color: fileRow.failed ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: {
            if (!fileRow.entry) return ""
            var parts = [Model.directionGlyph(fileRow.entry.direction) + " " + Model.relativeTime(fileRow.entry.tsMs, root.nowMs, strings.t, Commons.I18n.formatNumber)]
            if (fileRow.failed) parts.push(strings.t("recent.failed"))
            parts.push(String(fileRow.entry.folder || "/"))
            return parts.join(" · ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignRight
  }
}
