import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything the OneDrive widget knows, from three sources the client already
// provides: the monitor-status.json it publishes in --monitor mode (cycle
// state and outcomes), its systemd user service (paused or running), and its
// journal (per-file progress, which the status file does not carry).
Item {
  id: root

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/onedrive"
  readonly property string statusPath: configDir + "/monitor-status.json"
  readonly property string unit: "onedrive"

  property bool installed: true
  property bool serviceActive: false

  // Optimistic pause/resume, like the Dropbox and Tailscale services: -1
  // follows the real unit state, 0/1 while a stop/start is still settling.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? serviceActive : (_desired === 1)

  // monitor-status.json, parsed; null when the file is absent or unreadable.
  property var status: null
  property string _statusText: ""

  // Live activity from the journal.
  property string phase: ""          // "" | scan | remote
  property var transfer: null        // { direction, path, percent, eta, atMs }
  property var recent: []            // newest first: { name, folder, path, direction, ok, tsMs }
  // The run: one burst of work with announced totals, from the first
  // "Number of items to download" / "New items to upload" line until the
  // cycle ends or everything announced has finished. File counts, not bytes,
  // since the client announces counts.
  property bool runActive: false
  property double runStartedAtMs: 0
  property double runLastEventMs: 0
  property int runTotalDownload: 0
  property int runTotalUpload: 0
  property int runDoneDownload: 0
  property int runDoneUpload: 0
  property int runFailed: 0
  property var runCompletions: []
  property double tickMs: Date.now()
  readonly property var runEstimate: Model.runEstimate({
    active: runActive, startedAtMs: runStartedAtMs,
    totalDownload: runTotalDownload, totalUpload: runTotalUpload,
    doneDownload: runDoneDownload, doneUpload: runDoneUpload, failed: runFailed,
    completions: runCompletions
  }, tickMs)
  readonly property int runBarMinSec: intSetting("runBarMinSec", 60, 0, 86400)
  // Shown only for a run worth watching: known totals, a rate, and a
  // projected duration past the threshold.
  readonly property bool runShown: !!runEstimate && !runEstimate.finished && runEstimate.rate > 0
    && runEstimate.remainingSec >= 0 && (runEstimate.elapsedSec + runEstimate.remainingSec) >= runBarMinSec
  readonly property int pendingUploads: Math.max(0, runTotalUpload - runDoneUpload)
  property double lastJournalTsMs: 0
  // journald cursor of the last entry seen, so a restarted follow resumes
  // exactly after it. Comparing timestamps instead would drop distinct
  // lines that share a stamp.
  property string lastJournalCursor: ""
  property string lastError: ""
  property double lastErrorAtMs: 0
  property string actionStatus: ""

  property var quota: null
  property double quotaFetchedAtMs: 0
  property string quotaError: ""
  property string syncDir: home + "/OneDrive"

  // Whether the unit starts with the desktop (systemctl --user is-enabled).
  property bool unitEnabled: false
  property bool unitEnabledKnown: false
  readonly property bool unitBusy: enabledProcess.running || enableProcess.running
  property string version: ""
  // Result of `onedrive --display-sync-status`, a few plain lines.
  property string syncStatusText: ""
  readonly property bool syncStatusBusy: syncStatusProcess.running
  readonly property bool notifyOnFailure: Model.boolValue(setting("notifyOnFailure", true), true)
  property double lastNotifyMs: 0
  property string notifiedCycleKey: ""

  // Client update check: the AUR package (what yay can install) and the
  // upstream GitHub release, compared with the installed package.
  readonly property string packageName: "onedrive-abraunegg"
  readonly property bool checkUpdatesEnabled: Model.boolValue(setting("checkUpdates", true), true)
  readonly property int updateCheckHours: intSetting("updateCheckHours", 6, 1, 168)
  property var updateInfo: null   // { installed, aur, upstream, aurNewer, upstreamNewer }
  property double updateCheckedAtMs: 0
  property string updateError: ""
  readonly property bool updateBusy: updateProcess.running
  readonly property bool updateAvailable: !!updateInfo && updateInfo.aurNewer === true
  readonly property string updateVersion: updateInfo ? String(updateInfo.aurNewer ? updateInfo.aur : updateInfo.upstream) : ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 3, 600)
  readonly property int recentLimit: intSetting("recentLimit", 12, 1, 50)
  readonly property int quotaRefreshMin: intSetting("quotaRefreshMin", 30, 1, 1440)
  readonly property bool busy: controlProcess.running
  readonly property bool quotaBusy: quotaProcess.running

  readonly property string processState: status && status.process ? String(status.process.state || "") : ""
  readonly property string reachability: status && status.conditions ? String(status.conditions.onedrive_reachability || "") : ""
  readonly property string lastCycleResult: status && status.sync && status.sync.last_cycle ? String(status.sync.last_cycle.result || "") : ""
  readonly property int lastCycleFailures: status && status.sync && status.sync.last_cycle
    ? (Number(status.sync.last_cycle.download_failures || 0) + Number(status.sync.last_cycle.upload_failures || 0) + Number(status.sync.last_cycle.recycle_bin_failures || 0))
    : 0
  readonly property int successfulCycles: status && status.sync ? Number(status.sync.successful_cycle_count || 0) : 0
  readonly property double lastSuccessfulSyncMs: status && status.sync ? Model.parseIsoMs(status.sync.last_successful_sync_at) : 0
  readonly property int monitorIntervalSec: status && status.mode ? Number(status.mode.monitor_interval_seconds || 0) : 0

  // One word the panel and bar icon key off. A transfer in flight counts as
  // syncing even between scheduled cycles, since inotify-driven uploads run
  // while the status file still says idle.
  readonly property string state: {
    if (!installed) return "missing"
    if (!active) return "paused"
    if (transfer || runShown) return "syncing"
    if (!status) return "starting"
    if (reachability === "unreachable") return "offline"
    if (processState === "syncing") return "syncing"
    if (processState === "degraded") return "degraded"
    if (processState === "idle") return "idle"
    return "starting"
  }

  // Answers the IPC status() call, so it stays English.
  readonly property string statusText: {
    var s = state
    if (s === "syncing" && runShown) return "Syncing " + Math.round(runEstimate.fraction * 100) + "% (" + runEstimate.done + "/" + runEstimate.total + " files, " + Math.round(runEstimate.remainingSec / 60) + " min left)"
    if (s === "syncing" && transfer) return (transfer.direction === "upload" ? "Uploading " : "Downloading ") + transfer.percent + "% " + Model.fileName(transfer.path)
    if (s === "idle") return "Up to date"
    if (s === "paused") return "Paused"
    if (s === "missing") return "Not installed"
    return s.charAt(0).toUpperCase() + s.substring(1)
  }

  // Journal lines older than the shell's start only feed the recent list;
  // their progress figures describe transfers that already ended.
  readonly property double startedAtMs: Date.now()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function refresh() {
    statusFile.reload()
    if (!activeProcess.running) activeProcess.running = true
  }

  function applyStatus(text) {
    var raw = String(text || "")
    if (raw === _statusText && status) return
    _statusText = raw
    var parsed = Model.parseStatus(raw)
    var hadStatus = status !== null
    status = parsed
    noteCycleOutcome(parsed, hadStatus)
    // A completed cycle means nothing is mid-flight any more.
    if (parsed && processState !== "syncing" && transfer && Date.now() - transfer.atMs > 5000) transfer = null
    startJournal()
  }

  function handleJournalLine(line) {
    var entry = Model.parseJournalLine(line)
    if (!entry) return
    if (entry.tsMs > 0) lastJournalTsMs = entry.tsMs
    if (entry.cursor) lastJournalCursor = entry.cursor
    var event = Model.parseMessage(entry.message)
    if (!event) return
    var at = entry.tsMs || Date.now()
    var historical = entry.tsMs > 0 && entry.tsMs < startedAtMs - 2000
    if (event.type === "finished") {
      recent = Model.pushRecent(recent, {
        name: Model.fileName(event.path),
        folder: Model.folderOf(event.path),
        path: event.path,
        direction: event.direction,
        ok: event.ok,
        tsMs: at
      }, recentLimit)
      if (!historical && transfer && transfer.path === event.path) transfer = null
      if (!runActive) startRun(at)
      if (event.ok) {
        if (event.direction === "upload") runDoneUpload += 1
        else runDoneDownload += 1
      } else {
        runFailed += 1
      }
      noteCompletion(at)
      return
    }
    if (event.type === "pending") {
      if (!runActive) startRun(at)
      if (event.direction === "upload") runTotalUpload += event.count
      else runTotalDownload += event.count
      runLastEventMs = at
      return
    }
    if (event.type === "cycleStart") {
      startRun(at)
      phase = "scan"
      return
    }
    if (event.type === "cycleEnd") {
      phase = ""
      transfer = null
      finishRun()
      if (!historical) refresh()
      return
    }
    if (historical) return
    if (event.type === "progress") {
      if (event.done) {
        if (transfer && transfer.path === event.path) transfer = Object.assign({}, transfer, { percent: 100, eta: "", atMs: Date.now() })
        return
      }
      transfer = { direction: event.direction, path: event.path, percent: event.percent, eta: event.eta, atMs: Date.now() }
    } else if (event.type === "phase") {
      phase = event.phase
    } else if (event.type === "error") {
      lastError = elide(event.text)
      lastErrorAtMs = Date.now()
      notify(lastError)
    }
  }

  function startRun(at) {
    runActive = true
    runStartedAtMs = at
    runLastEventMs = at
    runTotalDownload = 0
    runTotalUpload = 0
    runDoneDownload = 0
    runDoneUpload = 0
    runFailed = 0
    runCompletions = []
  }

  function finishRun() {
    runActive = false
  }

  function noteCompletion(at) {
    runLastEventMs = at
    var list = runCompletions.slice(Math.max(0, runCompletions.length - 599))
    list.push(at)
    runCompletions = list
  }

  // The follow starts once the status file has answered, so a run already
  // under way is replayed from its cycle start and the whole-run bar is right
  // from the first frame. Without a cycle in progress, a short tail seeds
  // the recent list.
  function startJournal() {
    if (journal.running) return
    var since = status && status.process ? Model.parseIsoMs(status.process.current_cycle_started_at) : 0
    var args = ["journalctl", "--user", "-u", unit, "-o", "json", "-f", "--no-pager"]
    if (lastJournalCursor) args.push("--after-cursor=" + lastJournalCursor)
    else if (since > 0) args.push("--since=@" + Math.floor(since / 1000))
    else args.push("-n", "300")
    journal.command = args
    journal.running = true
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 160 ? value.substring(0, 157) + "…" : value
  }

  function pause() { runControl("stop", 0) }
  function resume() { runControl("start", 1) }
  function restart() { runControl("restart", 1) }
  function toggleRunning() { if (active) pause(); else resume() }

  function runControl(verb, desired) {
    if (!installed || controlProcess.running) return
    _desired = desired
    if (verb === "restart") {
      transfer = null
      phase = ""
      finishRun()
    }
    controlProcess.command = ["systemctl", "--user", verb, unit]
    controlProcess.running = true
  }

  function refreshQuota(force) {
    if (!installed || quotaProcess.running) return
    if (!force && quota && Date.now() - quotaFetchedAtMs < quotaRefreshMin * 60000) return
    quotaError = ""
    quotaProcess.running = true
    quotaTimeout.restart()
  }

  function fileUri(path) {
    var parts = String(path || "").split("/")
    for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
    return "file://" + parts.join("/")
  }

  function openFile(entry) {
    if (!entry || !entry.path) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", "--select", fileUri(syncDir + "/" + entry.path)])
  }

  function openFolder() {
    Quickshell.execDetached(["uwsm-app", "--", "xdg-open", syncDir])
  }

  // A cycle that ends badly is announced once, and only when it ended while
  // the shell was watching, so an old failure is not re-reported after a
  // shell restart.
  function noteCycleOutcome(parsed, hadStatus) {
    var cycle = parsed && parsed.sync ? parsed.sync.last_cycle : null
    if (!cycle) return
    var result = String(cycle.result || "")
    var key = result + "|" + String(cycle.completed_at || cycle.ended_at || cycle.finished_at || cycle.started_at || "")
      + "|" + String(parsed.sync.successful_cycle_count || 0) + "|" + String(parsed.sync.failed_cycle_count || "")
    if (!hadStatus) { notifiedCycleKey = key; return }
    if (key === notifiedCycleKey) return
    notifiedCycleKey = key
    if (result === "partial_failure") notify("The last sync cycle completed with failures")
    else if (result === "service_unreachable") notify("Microsoft OneDrive was unreachable")
  }

  // Desktop notification for failures, at most one every five minutes.
  function notify(text) {
    if (!notifyOnFailure || !text) return
    var now = Date.now()
    if (now - lastNotifyMs < 300000) return
    lastNotifyMs = now
    Quickshell.execDetached(["notify-send", "-a", "OneDrive", "-u", "normal", "OneDrive", String(text)])
  }

  function refreshEnabled() {
    if (!installed || enabledProcess.running) return
    enabledProcess.running = true
  }

  function setStartAtLogin(on) {
    if (!installed || enableProcess.running) return
    enableProcess.command = ["systemctl", "--user", on ? "enable" : "disable", unit]
    enableProcess.running = true
  }

  function refreshVersion() {
    if (!installed || versionProcess.running) return
    versionProcess.running = true
  }

  function checkUpdates(force) {
    if (!installed || !checkUpdatesEnabled || updateProcess.running) return
    if (!force && updateCheckedAtMs > 0 && Date.now() - updateCheckedAtMs < updateCheckHours * 3600000) return
    updateError = ""
    updateProcess.running = true
    updateTimeout.restart()
  }

  // yay needs a password and builds in the foreground, so it runs in a
  // terminal; the service restarts onto the new binary afterwards.
  function installUpdate() {
    if (!installed) return
    var script = "yay -S --needed " + packageName + " && systemctl --user restart " + unit
      + "; echo; read -r -p 'Press Enter to close'"
    Quickshell.execDetached(["omarchy-launch-tui", "bash", "-c", script])
  }

  function checkSyncStatus() {
    if (!installed || syncStatusProcess.running) return
    syncStatusText = ""
    syncStatusProcess.running = true
    syncStatusTimeout.restart()
  }

  function openConfig() {
    Quickshell.execDetached(["omarchy-launch-editor", configDir + "/config"])
  }

  function openSyncList() {
    Quickshell.execDetached(["omarchy-launch-editor", configDir + "/sync_list"])
  }

  // Re-authentication is interactive (a URL to open and a response to
  // paste), so it runs in a terminal with the service stopped around it.
  function reauth() {
    var script = "systemctl --user stop " + unit + "; onedrive --reauth; systemctl --user start " + unit
      + "; echo; read -r -p 'Press Enter to close'"
    Quickshell.execDetached(["omarchy-launch-tui", "bash", "-c", script])
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyStatus(text())
    onLoadFailed: {
      root._statusText = ""
      root.status = null
      root.startJournal()
    }
  }

  FileView {
    id: configFile
    path: root.configDir + "/config"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.syncDir = Model.parseSyncDir(text(), root.home)
  }

  // The client replaces the status file atomically, which swaps the inode;
  // should the watch fail to rearm, this still catches up, and it keeps the
  // unit state fresh.
  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A transfer line with no follow-up for two minutes is stale (the client
  // was killed mid-file, or the journal line format changed).
  Timer {
    interval: 15000
    repeat: true
    running: root.transfer !== null
    onTriggered: if (root.transfer && Date.now() - root.transfer.atMs > 120000) root.transfer = null
  }

  // Old errors fade from the hero after ten minutes, but stay in the panel.
  Timer {
    interval: 60000
    repeat: true
    running: root.lastError !== ""
    onTriggered: if (Date.now() - root.lastErrorAtMs > 600000) root.lastError = ""
  }

  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1500
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 6) {
        ticks = 0
        running = false
        root._desired = -1
      }
    }
  }

  Timer {
    id: journalRestart
    interval: 3000
    repeat: false
    onTriggered: root.startJournal()
  }

  // Drives the run estimate while a run is on, and retires a run once all
  // announced files are done and nothing has happened for a while. A run
  // that goes silent for ten minutes is over too, whatever the counts say.
  Timer {
    interval: 1000
    repeat: true
    running: root.runActive
    onTriggered: {
      root.tickMs = Date.now()
      var est = root.runEstimate
      var quietMs = root.tickMs - root.runLastEventMs
      if ((est && est.finished && quietMs > 15000 && !root.transfer) || quietMs > 600000) root.finishRun()
    }
  }

  Timer {
    id: updateTimeout
    interval: 60000
    repeat: false
    onTriggered: if (updateProcess.running) updateProcess.running = false
  }

  // First update check two minutes after the shell starts, then hourly
  // ticks that only run a check once the configured interval has passed.
  Timer {
    interval: 120000
    repeat: false
    running: root.installed && root.checkUpdatesEnabled
    onTriggered: root.checkUpdates(false)
  }
  Timer {
    interval: 3600000
    repeat: true
    running: root.installed && root.checkUpdatesEnabled
    onTriggered: root.checkUpdates(false)
  }

  Process {
    id: updateProcess
    running: false
    command: ["bash", "-c",
      "installed=$(pacman -Q " + root.packageName + " 2>/dev/null | awk '{print $2}'); "
      + "aur=$(curl -fsS --max-time 15 --max-filesize 200000 'https://aur.archlinux.org/rpc/v5/info?arg[]=" + root.packageName + "' | jq -r '.results[0].Version // empty'); "
      + "upstream=$(curl -fsS --max-time 15 --max-filesize 500000 -H 'Accept: application/vnd.github+json' https://api.github.com/repos/abraunegg/onedrive/releases/latest | jq -r '.tag_name // empty'); "
      + "printf 'installed=%s\\naur=%s\\nupstream=%s\\n' \"$installed\" \"$aur\" \"$upstream\"; "
      + "iv=${installed%-*}; av=${aur%-*}; uv=${upstream#v}; "
      + "[ -n \"$iv\" ] && [ -n \"$av\" ] && printf 'aur_newer=%s\\n' \"$(vercmp \"$av\" \"$iv\")\"; "
      + "[ -n \"$iv\" ] && [ -n \"$uv\" ] && printf 'upstream_newer=%s\\n' \"$(vercmp \"$uv\" \"$iv\")\"; true"]
    stdout: StdioCollector { id: updateStdout; waitForEnd: true }
    stderr: StdioCollector { id: updateStderr; waitForEnd: true }
    onExited: function(exitCode) {
      updateTimeout.stop()
      var parsed = Model.parseUpdateCheck(String(updateStdout.text || ""))
      root.updateCheckedAtMs = Date.now()
      if (parsed) {
        root.updateInfo = parsed
        root.updateError = ""
      } else {
        root.updateError = root.elide(String(updateStderr.text || "")) || "update check failed"
      }
    }
  }

  Timer {
    id: syncStatusTimeout
    interval: 180000
    repeat: false
    onTriggered: if (syncStatusProcess.running) syncStatusProcess.running = false
  }

  Process {
    id: enabledProcess
    running: false
    command: ["systemctl", "--user", "is-enabled", root.unit]
    stdout: StdioCollector { id: enabledStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(enabledStdout.text || "").trim()
      root.unitEnabled = out === "enabled" || out === "static" || out === "alias" || out === "linked"
      root.unitEnabledKnown = true
    }
  }

  Process {
    id: enableProcess
    running: false
    command: []
    stderr: StdioCollector { id: enableStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = root.elide(String(enableStderr.text || "") || "systemctl failed")
        root.lastErrorAtMs = Date.now()
      }
      root.refreshEnabled()
    }
  }

  Process {
    id: versionProcess
    running: false
    command: ["onedrive", "--version"]
    stdout: StdioCollector { id: versionStdout; waitForEnd: true }
    onExited: root.version = Model.parseVersion(String(versionStdout.text || ""))
  }

  Process {
    id: syncStatusProcess
    running: false
    command: ["onedrive", "--display-sync-status"]
    stdout: StdioCollector { id: syncStatusStdout; waitForEnd: true }
    stderr: StdioCollector { id: syncStatusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      syncStatusTimeout.stop()
      var text = Model.summaryLines(String(syncStatusStdout.text || "") + "\n" + String(syncStatusStderr.text || ""), 3, 200)
      root.syncStatusText = text !== "" ? text : (exitCode === 0 ? "ok" : "failed")
    }
  }

  Timer {
    id: quotaTimeout
    interval: 45000
    repeat: false
    onTriggered: if (quotaProcess.running) quotaProcess.running = false
  }

  Process {
    id: installedProcess
    running: true
    command: ["bash", "-c", "command -v onedrive >/dev/null"]
    onExited: function(exitCode) { root.installed = exitCode === 0 }
  }

  Process {
    id: activeProcess
    running: false
    command: ["systemctl", "--user", "is-active", root.unit]
    stdout: StdioCollector { id: activeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(activeStdout.text || "").trim()
      var on = exitCode === 0 || out === "activating" || out === "reloading"
      root.serviceActive = on
      if (root._desired !== -1 && on === (root._desired === 1)) root._desired = -1
    }
  }

  // Follows the unit's journal for the life of the shell. The 300 lines of
  // history seed the recent-files list, so the panel is not empty after a
  // shell restart. One JSON object per line keeps file names with odd
  // characters intact.
  Process {
    id: journal
    running: false
    command: []
    stdout: SplitParser { onRead: function(line) { root.handleJournalLine(line) } }
    onExited: journalRestart.restart()
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stderr: StdioCollector { id: controlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = root.elide(String(controlStderr.text || "") || "systemctl failed")
        root.lastErrorAtMs = Date.now()
      }
      settleTimer.ticks = 0
      settleTimer.restart()
    }
  }

  Process {
    id: quotaProcess
    running: false
    command: ["onedrive", "--display-quota"]
    stdout: StdioCollector { id: quotaStdout; waitForEnd: true }
    stderr: StdioCollector { id: quotaStderr; waitForEnd: true }
    onExited: function(exitCode) {
      quotaTimeout.stop()
      var parsed = Model.parseQuota(String(quotaStdout.text || ""))
      if (exitCode === 0 && parsed.ok) {
        root.quota = parsed
        root.quotaFetchedAtMs = Date.now()
        root.quotaError = ""
      } else {
        root.quotaError = root.elide(String(quotaStderr.text || "")) || "quota"
      }
    }
  }
}
