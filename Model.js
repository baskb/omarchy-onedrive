// Pure helpers for the OneDrive bar widget: parsing the journal lines the
// OneDrive Client for Linux (abraunegg) writes in --monitor mode, its
// monitor-status.json, and the output of `onedrive --display-quota`.
// No QML here, so `node Model.test.js` can exercise every parser.

var PROGRESS = /^(Uploading|Downloading): (.+?) \.\.\. (\d{1,3})%\s*\|\s*(?:ETA\s+(\S+)|DONE in (\S+))/
var FINISHED = /^(Uploading|Downloading)(?: (?:modified |new )?file)?: (.+?) \.\.\. (done|failed!?)$/
var PENDING_UPLOAD = /^(?:New items|Changed local items) to upload to Microsoft OneDrive: (\d+)/
var PENDING_DOWNLOAD = /^Number of items to download from Microsoft OneDrive: (\d+)/
var CYCLE_START = /^Starting a sync with Microsoft OneDrive/
var CYCLE_END = /^Sync with Microsoft OneDrive (?:is complete|was interrupted)/
var REMOTE = /^Syncing changes from Microsoft OneDrive/
var SCAN = /^(?:Performing a database consistency|Scanning the local file system|Performing a last examination|Process(?:ing|ed) \d+ applicable|Performing initial synchronisation)/
var ERROR = /^ERROR: (.+)$/

var IMAGE_EXTENSIONS = { jpg: true, jpeg: true, png: true, gif: true, webp: true, avif: true, heic: true, svg: true, bmp: true, tif: true, tiff: true }
var VIDEO_EXTENSIONS = { mp4: true, mov: true, mkv: true, webm: true, avi: true, m4v: true, mpg: true, mpeg: true, wmv: true }
var AUDIO_EXTENSIONS = { mp3: true, wav: true, flac: true, ogg: true, m4a: true, aac: true }
var DOCUMENT_EXTENSIONS = { pdf: true, txt: true, md: true, doc: true, docx: true, xls: true, xlsx: true, ppt: true, pptx: true, odt: true, ods: true, odp: true, rtf: true, csv: true }

function clampPercent(raw) {
  var n = parseInt(raw, 10)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(100, n))
}

// One journal MESSAGE → an event the service applies, or null for noise.
function parseMessage(message) {
  var text = String(message || "").trim()
  if (text === "") return null
  var m
  if ((m = PROGRESS.exec(text))) {
    return {
      type: "progress",
      direction: m[1] === "Uploading" ? "upload" : "download",
      path: m[2],
      percent: clampPercent(m[3]),
      eta: m[4] || "",
      done: !!m[5]
    }
  }
  if ((m = FINISHED.exec(text))) {
    return {
      type: "finished",
      direction: m[1] === "Uploading" ? "upload" : "download",
      path: m[2],
      ok: m[3] === "done"
    }
  }
  if ((m = PENDING_UPLOAD.exec(text))) return { type: "pending", direction: "upload", count: parseInt(m[1], 10) || 0 }
  if ((m = PENDING_DOWNLOAD.exec(text))) return { type: "pending", direction: "download", count: parseInt(m[1], 10) || 0 }
  if (CYCLE_START.test(text)) return { type: "cycleStart" }
  if (CYCLE_END.test(text)) return { type: "cycleEnd", interrupted: text.indexOf("interrupted") >= 0 }
  if (REMOTE.test(text)) return { type: "phase", phase: "remote" }
  if (SCAN.test(text)) return { type: "phase", phase: "scan" }
  if ((m = ERROR.exec(text))) return { type: "error", text: m[1] }
  return null
}

// A `journalctl -o json` line → { message, tsMs } or null.
function parseJournalLine(line) {
  var text = String(line || "").trim()
  if (text === "" || text.charAt(0) !== "{") return null
  try {
    var obj = JSON.parse(text)
    if (!obj || typeof obj.MESSAGE !== "string") return null
    var us = Number(obj.__REALTIME_TIMESTAMP)
    return {
      message: obj.MESSAGE,
      tsMs: isFinite(us) ? Math.floor(us / 1000) : 0,
      cursor: typeof obj.__CURSOR === "string" ? obj.__CURSOR : ""
    }
  } catch (e) {
    return null
  }
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  try {
    var parsed = JSON.parse(text)
    return parsed && typeof parsed === "object" && parsed.process ? parsed : null
  } catch (e) {
    return null
  }
}

// `onedrive --display-quota` prints "Used:      95.70 GB (102757936438 bytes)"
// style lines; the byte counts in parentheses are the reliable part.
function parseQuota(raw) {
  var text = String(raw || "")
  var out = { used: 0, total: 0, remaining: 0, deleted: 0, state: "", ok: false }
  var re = /^(Deleted|Remaining|Total|Used):\s+.*?\((\d+) bytes\)/gm
  var m
  while ((m = re.exec(text))) {
    var value = Number(m[2])
    if (!isFinite(value)) continue
    if (m[1] === "Used") out.used = value
    else if (m[1] === "Total") out.total = value
    else if (m[1] === "Remaining") out.remaining = value
    else if (m[1] === "Deleted") out.deleted = value
    out.ok = true
  }
  var s = /^State:\s+(\S+)/m.exec(text)
  if (s) out.state = s[1]
  return out
}

// Status timestamps carry seven fractional digits; trim to three so every
// JS engine parses them.
function parseIsoMs(value) {
  var text = String(value || "").trim()
  if (text === "") return 0
  var ms = Date.parse(text.replace(/(\.\d{3})\d+/, "$1"))
  return isFinite(ms) ? ms : 0
}

// sync_dir = "~/OneDrive" in the client's config file; ~ expands to home.
function parseSyncDir(configText, home) {
  var m = /^\s*sync_dir\s*=\s*"?([^"\n]+?)"?\s*$/m.exec(String(configText || ""))
  var dir = m ? m[1].trim() : "~/OneDrive"
  if (dir === "~") dir = home
  else if (dir.indexOf("~/") === 0) dir = home + dir.substring(1)
  return dir.replace(/\/+$/, "")
}

function fileName(path) {
  var text = String(path || "")
  var index = text.lastIndexOf("/")
  return index >= 0 ? text.substring(index + 1) : text
}

function folderOf(path) {
  var text = String(path || "")
  var index = text.lastIndexOf("/")
  return index > 0 ? text.substring(0, index) : "/"
}

function fileExtension(name) {
  var value = String(name || "").toLowerCase()
  var index = value.lastIndexOf(".")
  return index >= 0 ? value.substring(index + 1) : ""
}

function fileGlyph(name) {
  var ext = fileExtension(name)
  if (IMAGE_EXTENSIONS[ext]) return "󰋩"
  if (VIDEO_EXTENSIONS[ext]) return "󰈫"
  if (AUDIO_EXTENSIONS[ext]) return "󰎈"
  if (DOCUMENT_EXTENSIONS[ext]) return "󰈙"
  return "󰈔"
}

function directionGlyph(direction) {
  return direction === "upload" ? "󰕒" : "󰇚"
}

function formatter(fmt) {
  return typeof fmt === "function" ? fmt : function(v, d) { return d === undefined ? String(v) : Number(v).toFixed(d) }
}

function translator(tr) {
  return typeof tr === "function" ? tr : function(key, english) { return english }
}

function formatBytes(bytes, fmt) {
  var f = formatter(fmt)
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return f(0) + " B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return f(Number(value.toFixed(decimals))) + " " + units[index]
}

function relativeTime(tsMs, nowMs, tr, fmt) {
  var t = translator(tr)
  var f = formatter(fmt)
  var ts = Number(tsMs || 0)
  if (!isFinite(ts) || ts <= 0) return t("time.unknown", "Unknown")
  var now = nowMs === undefined || nowMs === null ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts) / 1000))
  if (diff < 60) return t("time.justNow", "Just now")
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return t("time.minutesAgo", "%1m ago").replace("%1", f(minutes))
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return t("time.hoursAgo", "%1h ago").replace("%1", f(hours))
  var days = Math.floor(hours / 24)
  return t("time.daysAgo", "%1d ago").replace("%1", f(days))
}

// ETA strings arrive as HH:MM:SS or --:--:--; shorten for the bar.
function shortEta(eta) {
  var m = /^(\d\d):(\d\d):(\d\d)$/.exec(String(eta || ""))
  if (!m) return ""
  var h = parseInt(m[1], 10), min = parseInt(m[2], 10), s = parseInt(m[3], 10)
  if (h > 0) return h + "h " + min + "m"
  if (min > 0) return min + "m " + s + "s"
  return s + "s"
}

// Whole-run estimate from file counts. Completions is a list of timestamps
// (ms) of finished files, newest last. The rate prefers the last two minutes
// so a run that moves from big videos to small text files re-estimates
// quickly, and falls back to the run's overall average while the window is
// thin. Returns null until there is something to estimate.
function runEstimate(run, nowMs) {
  if (!run || !run.active) return null
  var total = Number(run.totalDownload || 0) + Number(run.totalUpload || 0)
  var done = Number(run.doneDownload || 0) + Number(run.doneUpload || 0) + Number(run.failed || 0)
  if (total <= 0) return null
  var now = Number(nowMs || Date.now())
  var elapsedSec = Math.max(0, (now - Number(run.startedAtMs || now)) / 1000)
  var completions = run.completions || []
  var windowSec = 120
  var inWindow = 0
  for (var i = completions.length - 1; i >= 0; i--) {
    if (now - completions[i] <= windowSec * 1000) inWindow++
    else break
  }
  var rate = 0
  if (inWindow >= 5) rate = inWindow / Math.min(windowSec, Math.max(1, elapsedSec))
  else if (elapsedSec >= 3 && done > 0) rate = done / elapsedSec
  var remaining = Math.max(0, total - done)
  var remainingSec = rate > 0 ? remaining / rate : -1
  return {
    total: total,
    done: Math.min(done, total),
    fraction: Math.max(0, Math.min(1, done / total)),
    elapsedSec: elapsedSec,
    rate: rate,
    remainingSec: remainingSec,
    finished: remaining === 0
  }
}

// "<1 min", "12 min", "1 h 05 min" style durations for the run ETA.
function formatDuration(seconds, tr, fmt) {
  var t = translator(tr)
  var f = formatter(fmt)
  var s = Number(seconds)
  if (!isFinite(s) || s < 0) return ""
  if (s < 60) return t("duration.underMinute", "<1 min")
  var minutes = Math.round(s / 60)
  if (minutes < 60) return t("duration.minutes", "%1 min").replace("%1", f(minutes))
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  return t("duration.hoursMinutes", "%1 h %2 min").replace("%1", f(hours)).replace("%2", (rest < 10 ? "0" : "") + f(rest))
}

// Recent list bookkeeping: newest first, one entry per path, bounded.
function pushRecent(list, entry, limit) {
  var out = [entry]
  for (var i = 0; i < list.length && out.length < limit; i++) {
    if (list[i].path !== entry.path) out.push(list[i])
  }
  return out
}

// Settings arrive from shell.json as JSON values, from the CLI as strings.
function boolValue(value, fallback) {
  if (value === true || value === false) return value
  var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
  if (s === "true" || s === "1" || s === "yes" || s === "on") return true
  if (s === "false" || s === "0" || s === "no" || s === "off") return false
  return !!fallback
}

// "onedrive v2.5.12" from `onedrive --version`.
function parseVersion(text) {
  var m = /onedrive\s+(v?\d[\w.\-]*)/i.exec(String(text || ""))
  return m ? m[1] : ""
}

// The last few meaningful lines of a client command, for showing a result
// in the panel. Boilerplate the client prints before every command is
// dropped, whitespace collapsed, and each line bounded.
var BOILERPLATE = /^(Reading configuration|Configuration file|D-Bus message bus|Using |Attempting to contact|Successfully reached|Configuring Global|Querying the change status|Note: |Loading|Sync Engine)/
function summaryLines(text, maxLines, maxLen) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\.{4,}/g, "").replace(/\s+/g, " ").trim()
    if (line === "" || BOILERPLATE.test(line)) continue
    out.push(line)
  }
  out = out.slice(Math.max(0, out.length - maxLines))
  for (var j = 0; j < out.length; j++) {
    if (out[j].length > maxLen) out[j] = out[j].substring(0, maxLen - 1) + "…"
  }
  return out.join("\n")
}

// Output of the update-check script: key=value lines with the installed
// package version, the AUR version, the upstream release tag, and vercmp
// results. Versions are validated before use since they come off the network.
var VERSION_SHAPE = /^[A-Za-z0-9][A-Za-z0-9.+:~_-]{0,39}$/
function parseUpdateCheck(text) {
  var fields = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^([a-z_]+)=(.*)$/.exec(lines[i].trim())
    if (m) fields[m[1]] = m[2].trim()
  }
  var installed = VERSION_SHAPE.test(fields.installed || "") ? fields.installed : ""
  var aur = VERSION_SHAPE.test(fields.aur || "") ? fields.aur : ""
  var upstream = VERSION_SHAPE.test(fields.upstream || "") ? fields.upstream.replace(/^v/, "") : ""
  if (installed === "" || (aur === "" && upstream === "")) return null
  return {
    installed: installed,
    aur: aur,
    upstream: upstream,
    aurNewer: aur !== "" && Number(fields.aur_newer) > 0,
    upstreamNewer: upstream !== "" && Number(fields.upstream_newer) > 0
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseUpdateCheck: parseUpdateCheck,
    boolValue: boolValue,
    parseVersion: parseVersion,
    summaryLines: summaryLines,
    parseMessage: parseMessage,
    parseJournalLine: parseJournalLine,
    parseStatus: parseStatus,
    parseQuota: parseQuota,
    parseIsoMs: parseIsoMs,
    parseSyncDir: parseSyncDir,
    fileName: fileName,
    folderOf: folderOf,
    fileGlyph: fileGlyph,
    directionGlyph: directionGlyph,
    formatBytes: formatBytes,
    relativeTime: relativeTime,
    shortEta: shortEta,
    runEstimate: runEstimate,
    formatDuration: formatDuration,
    pushRecent: pushRecent
  }
}
