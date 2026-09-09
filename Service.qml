import QtQuick
import Quickshell
import Quickshell.Io

import "LyricsProvider.js" as Provider
import "LrcParser.js" as Parser
import "WordTimingEstimator.js" as Estimator

// sumiran.lyrics service — owns lyrics state, observes omarchy.media
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")

  // --- Media input -------------------------------------------------------
  //
  // Track metadata reaches this service by whichever of three routes the
  // running Omarchy still permits, most-direct first. Each degrades to the
  // next on its own, so a host that tightens (or loosens) what a plugin
  // service may touch changes which route carries the data, not whether
  // lyrics work.
  //
  //   "service"   omarchy.media read straight off our own scoped shell.
  //               Omarchy <= 4.0.2 handed every plugin service the real
  //               shell; 4.0.3 grants this only to plugins declaring kind
  //               "bar" (shell.qml pluginHasBarCapabilities).
  //   "widget"    pushed in by our bar widget, which reaches omarchy.media
  //               through bar.shell even when this service cannot.
  //   "playerctl" polled off MPRIS directly. Touches no host API at all, so
  //               it outlives any future change to the plugin sandbox.
  readonly property var mediaService: {
    if (!shell || typeof shell.firstPartyServiceFor !== "function") return null
    try {
      return shell.firstPartyServiceFor("omarchy.media") || null
    } catch (e) {
      return null
    }
  }
  readonly property var activePlayer: mediaService ? (mediaService.activePlayer || null) : null

  // Set by pushMedia()/pushPosition() from Panel.qml, and by the playerctl
  // poller. Null means "this route has nothing", which is what makes the
  // fallback chain below collapse cleanly.
  property var widgetMedia: null
  property var polledMedia: null

  readonly property string mediaRoute: activePlayer ? "service"
    : (widgetMedia ? "widget" : (polledMedia ? "playerctl" : "none"))

  // Position is deliberately excluded: it ticks, and re-evaluating the whole
  // snapshot on every tick would churn every binding that depends on it.
  readonly property var mediaTrack: {
    if (activePlayer) return {
      title: String(activePlayer.trackTitle || ""),
      artist: String(activePlayer.trackArtist || ""),
      album: String(activePlayer.trackAlbum || ""),
      artUrl: String(activePlayer.trackArtUrl || ""),
      duration: activePlayer.length ? Number(activePlayer.length) : 0,
      isPlaying: !!activePlayer.isPlaying,
      positionSupported: !!activePlayer.positionSupported
    }
    if (widgetMedia) return widgetMedia
    if (polledMedia) return polledMedia
    return null
  }

  readonly property string currentTitle: mediaTrack ? String(mediaTrack.title || "") : ""
  readonly property string currentArtist: mediaTrack ? String(mediaTrack.artist || "") : ""
  readonly property string currentAlbum: mediaTrack ? String(mediaTrack.album || "") : ""
  readonly property string currentArtUrl: mediaTrack ? String(mediaTrack.artUrl || "") : ""
  readonly property real currentDuration: mediaTrack ? (Number(mediaTrack.duration) || 0) : 0
  readonly property bool hasMedia: !!(mediaTrack && (mediaTrack.title || mediaTrack.artist))
  readonly property bool isPlaying: !!(mediaTrack && mediaTrack.isPlaying)
  readonly property bool positionSupported: activePlayer
    ? !!activePlayer.positionSupported
    : !!(mediaTrack && mediaTrack.positionSupported)

  // Only the routes that cannot push on their own need polling.
  readonly property bool needsPlayerctl: !activePlayer && !widgetMedia

  // Called by our bar widget. Passing null retracts the route, so the service
  // falls through to playerctl rather than holding a stale track.
  function pushMedia(data) {
    if (!data || !(data.title || data.artist)) {
      widgetMedia = null
      return
    }
    widgetMedia = {
      title: String(data.title || ""),
      artist: String(data.artist || ""),
      album: String(data.album || ""),
      artUrl: String(data.artUrl || ""),
      duration: Number(data.duration) || 0,
      isPlaying: !!data.isPlaying,
      positionSupported: data.positionSupported !== false,
      position: Number(data.position) || 0,
      positionAt: Number(data.positionAt) || Date.now()
    }
  }

  function pushPosition(position, isPlaying) {
    if (!widgetMedia) return
    var next = {}
    for (var k in widgetMedia) next[k] = widgetMedia[k]
    next.position = Number(position) || 0
    next.positionAt = Date.now()
    next.isPlaying = !!isPlaying
    widgetMedia = next
    syncPosition()
  }

  // Position for the routes that carry it as a sampled value, advanced by the
  // wall clock since the sample so word timing stays smooth between polls.
  function sampledPosition(src) {
    if (!src) return 0
    var base = Number(src.position) || 0
    var at = Number(src.positionAt) || 0
    if (src.isPlaying && at > 0) base += (Date.now() - at) / 1000
    return base < 0 ? 0 : base
  }

  function currentPosition() {
    if (activePlayer) return Number(activePlayer.position) || 0
    return sampledPosition(widgetMedia || polledMedia)
  }

  // Lyrics state
  property var lyricsLines: [] // [{time,text,words:[{text,start,end}], end}]
  property string lyricsMode: "none"   // "synced" | "plain" | "notfound" | "none"
  property int currentIndex: -1
  property int currentWordIndex: -1
  property string status: "idle"       // "idle" | "loading" | "ready" | "error" | "offline" | "notfound"
  property string statusMessage: ""
  property string plainLyrics: ""

  property real livePosition: 0

  // Visual line completion (presentation only) — does not modify words[] timestamps
  // When position enters final ~15% of line, treat remaining words as completed for polished karaoke
  readonly property bool isLineCompleting: {
    if (lyricsMode !== "synced" || currentIndex < 0 || !lyricsLines || currentIndex >= lyricsLines.length) return false
    var line = lyricsLines[currentIndex]
    if (!line || !line.words || line.words.length <= 1) return false
    var s = Number(line.time)
    var e = Number(line.end)
    if (!isFinite(s) || !isFinite(e) || e <= s) return false
    var dur = e - s
    var win = dur * 0.15
    if (win < 0.25) win = 0.25
    if (win > 0.75) win = 0.75
    // If window covers most of line, keep subtle — require at least 20% of line remains normal
    // For very short lines, the clamp already ensures window < dur for dur>0.31; otherwise handled by fallback words:[] 
    return livePosition >= e - win
  }

  // Request token for stale-response protection
  property int requestSerial: 0
  property int activeRequestId: 0
  property string activeRequestSig: ""
  property bool pendingSearch: false

  // Duration retry: if first metadata had no duration, allow one retry when duration appears
  property bool retriedDuration: false

  function trackSignature() {
    return [currentTitle, currentArtist, currentAlbum, String(Math.round(currentDuration))].join("\u001f")
  }

  property string _lastSignature: ""

  onCurrentTitleChanged: handleTrackSignal()
  onCurrentArtistChanged: handleTrackSignal()
  onCurrentAlbumChanged: handleTrackSignal()
  onCurrentDurationChanged: handleDurationChange()

  function handleTrackSignal() {
    var sig = trackSignature()
    if (sig === _lastSignature) return
    // If only duration changed from 0 -> real, handle as retry not full clear
    _lastSignature = sig
    onTrackChanged()
  }

  function handleDurationChange() {
    var sig = trackSignature()
    if (sig === _lastSignature) return
    var oldSig = _lastSignature
    _lastSignature = sig
    if (!hasMedia) { onTrackChanged(); return }
    // Duration became available after initial fetch that may have failed
    if (!retriedDuration && oldSig && sig) {
      var oldParts = oldSig.split("\u001f")
      var newParts = sig.split("\u001f")
      // old duration was 0, new is non-zero, title/artist/album same
      if (oldParts[0] === newParts[0] && oldParts[1] === newParts[1] && oldParts[2] === newParts[2] && oldParts[3] === "0" && newParts[3] !== "0") {
        if (status === "notfound" || status === "error" || status === "idle") {
          retriedDuration = true
          startFetch()
          return
        }
      }
    }
    onTrackChanged()
  }

  function onTrackChanged() {
    if (!hasMedia) {
      invalidateRequests()
      clearLyrics()
      retriedDuration = false
      return
    }
    retriedDuration = false
    clearLyricsForNewTrack()
    startFetch()
  }

  function clearLyrics() {
    lyricsLines = []
    lyricsMode = "none"
    currentIndex = -1
    currentWordIndex = -1
    status = "idle"
    statusMessage = ""
    plainLyrics = ""
  }

  function clearLyricsForNewTrack() {
    lyricsLines = []
    lyricsMode = "none"
    currentIndex = -1
    currentWordIndex = -1
    status = "loading"
    statusMessage = "Fetching lyrics..."
    plainLyrics = ""
    livePosition = 0
    syncPosition()
  }

  function invalidateRequests() {
    activeRequestId = 0
    activeRequestSig = ""
    pendingSearch = false
    // Don't kill Process immediately; stale check will ignore responses
  }

  function startFetch() {
    if (!hasMedia) return
    var sig = trackSignature()
    // Avoid refetch for same sig if already ready and same track (scaffold: check activeRequestSig)
    if (activeRequestSig === sig && (status === "ready" || status === "notfound")) return

    requestSerial += 1
    activeRequestId = requestSerial
    activeRequestSig = sig
    pendingSearch = false
    var reqId = activeRequestId
    var title = currentTitle
    var artist = currentArtist
    var album = currentAlbum
    var duration = currentDuration

    // Try cache first
    tryCache(reqId, sig, title, artist, album, duration)
  }

  function tryCache(reqId, sig, title, artist, album, duration) {
    var path = Provider.cacheFilePathExpanded(home, title, artist, album, duration)
    cacheReadProc.command = ["bash", "-c", "if [ -f " + shellQuote(path) + " ]; then cat " + shellQuote(path) + "; else exit 2; fi"]
    // Store context for onExited
    cacheReadProc.reqId = reqId
    cacheReadProc.sig = sig
    cacheReadProc.title = title
    cacheReadProc.artist = artist
    cacheReadProc.album = album
    cacheReadProc.duration = duration
    cacheReadProc.running = true
  }

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function handleCacheResult(reqId, sig, title, artist, album, duration, exitCode, text) {
    if (reqId !== activeRequestId || sig !== activeRequestSig) return // stale
    if (exitCode === 0 && text && text.trim().length > 0) {
      var parsed = Provider.parseGetResponseText(text)
      // Cache stores normalized result {mode,syncedLyrics,plainLyrics,source,cachedAt}
      if (parsed && (parsed.mode === "synced" || parsed.mode === "plain" || parsed.mode === "notfound")) {
        // Validate synced still usable if mode synced
        if (parsed.mode === "synced" && !Provider.isUsableSynced(parsed.syncedLyrics)) {
          // Corrupt cache entry → ignore and fetch again
          fetchFromNetwork(reqId, sig, title, artist, album, duration)
          return
        }
        if (parsed.mode === "plain" && !Provider.isUsablePlain(parsed.plainLyrics)) {
          fetchFromNetwork(reqId, sig, title, artist, album, duration)
          return
        }
        applyResult(reqId, sig, parsed)
        return
      }
      // Corrupt JSON or unexpected shape → fetch again
      fetchFromNetwork(reqId, sig, title, artist, album, duration)
      return
    }
    if (exitCode === 2) {
      // No cache file → network
      fetchFromNetwork(reqId, sig, title, artist, album, duration)
      return
    }
    // Read failure → try network anyway
    fetchFromNetwork(reqId, sig, title, artist, album, duration)
  }

  function fetchFromNetwork(reqId, sig, title, artist, album, duration) {
    if (reqId !== activeRequestId || sig !== activeRequestSig) return
    var url = Provider.buildGetUrl(title, artist, album, duration)
    getProc.reqId = reqId
    getProc.sig = sig
    getProc.title = title
    getProc.artist = artist
    getProc.album = album
    getProc.duration = duration
    getProc.command = ["curl", "-fsS", "--max-time", "10", url]
    getProc.running = true
  }

  function fetchSearchFallback(reqId, sig, title, artist, album, duration) {
    if (reqId !== activeRequestId || sig !== activeRequestSig) return
    pendingSearch = true
    var url = Provider.buildSearchUrl(title, artist, album)
    searchProc.reqId = reqId
    searchProc.sig = sig
    searchProc.title = title
    searchProc.artist = artist
    searchProc.album = album
    searchProc.duration = duration
    searchProc.command = ["curl", "-fsS", "--max-time", "10", url]
    searchProc.running = true
  }

  function applyResult(reqId, sig, result) {
    if (reqId !== activeRequestId || sig !== activeRequestSig) return // stale
    // Don't overwrite if track already changed
    if (sig !== activeRequestSig) return

    if (!result || result.mode === "notfound") {
      lyricsLines = []
      plainLyrics = ""
      lyricsMode = "notfound"
      status = "notfound"
      statusMessage = "No lyrics found"
      currentIndex = -1
      currentWordIndex = -1
      // Cache notfound as well to avoid repeat lookups
      writeCache(sig, result || { mode: "notfound", syncedLyrics: "", plainLyrics: "", source: "lrclib" })
      return
    }
    if (result.mode === "synced") {
      var lines = Parser.parse(result.syncedLyrics)
      if (lines.length === 0) {
        // Treat as plain/notfound fallback if parse yields nothing
        if (Provider.isUsablePlain(result.plainLyrics)) {
          lyricsLines = []
          plainLyrics = String(result.plainLyrics)
          lyricsMode = "plain"
          status = "ready"
          statusMessage = ""
          currentIndex = -1
          currentWordIndex = -1
          writeCache(sig, result)
          return
        }
        lyricsLines = []
        plainLyrics = ""
        lyricsMode = "notfound"
        status = "notfound"
        statusMessage = "No lyrics found"
        currentIndex = -1
        currentWordIndex = -1
        writeCache(sig, { mode: "notfound", syncedLyrics: "", plainLyrics: "", source: "lrclib" })
        return
      }
      // Enrich with estimated word timings (fallback to [] when infeasible)
      // Word timing is estimated from line timestamps, not audio-derived.
      for (var i = 0; i < lines.length; i++) {
        var s = Number(lines[i].time)
        var e = (i + 1 < lines.length) ? Number(lines[i + 1].time) : NaN
        var ws = Estimator.estimateWords(lines[i].text, s, e)
        lines[i].words = ws
        lines[i].end = e
      }
      lyricsLines = lines
      plainLyrics = Provider.isUsablePlain(result.plainLyrics) ? String(result.plainLyrics) : ""
      lyricsMode = "synced"
      status = "ready"
      statusMessage = ""
      updateCurrentIndex()
      writeCache(sig, result)
      return
    }
    if (result.mode === "plain") {
      lyricsLines = []
      plainLyrics = String(result.plainLyrics)
      lyricsMode = "plain"
      status = "ready"
      statusMessage = ""
      currentIndex = -1
      currentWordIndex = -1
      writeCache(sig, result)
      return
    }
    // Unknown → notfound
    lyricsLines = []
    plainLyrics = ""
    lyricsMode = "notfound"
    status = "notfound"
    statusMessage = "No lyrics found"
    currentIndex = -1
    currentWordIndex = -1
  }

  function applyError(reqId, sig, message, isOffline) {
    if (reqId !== activeRequestId || sig !== activeRequestSig) return
    // Don't overwrite if already handled by newer request
    if (sig !== activeRequestSig) return
    lyricsLines = []
    plainLyrics = ""
    lyricsMode = "none"
    status = isOffline ? "offline" : "error"
    statusMessage = message || (isOffline ? "Offline" : "Failed to fetch lyrics")
    currentIndex = -1
    currentWordIndex = -1
  }

  function writeCache(sig, result) {
    var path = Provider.cacheFilePathExpanded(home, currentTitle, currentArtist, currentAlbum, currentDuration)
    // Only cache if current sig still matches; avoid caching stale track's result under new track's file
    if (sig !== activeRequestSig) return
    var payload = {
      mode: result.mode,
      syncedLyrics: result.syncedLyrics || "",
      plainLyrics: result.plainLyrics || "",
      source: result.source || "lrclib",
      cachedAt: new Date().toISOString(),
      title: currentTitle,
      artist: currentArtist,
      album: currentAlbum,
      duration: Math.round(currentDuration)
    }
    var json = JSON.stringify(payload)
    // Write via bash: mkdir -p dir && printf '%s' json > file
    var dir = home + "/.cache/omarchy-lyrics"
    // Use printf to avoid echo interpretation
    var cmd = "mkdir -p " + shellQuote(dir) + " && printf '%s' " + shellQuote(json) + " > " + shellQuote(path)
    cacheWriteProc.command = ["bash", "-c", cmd]
    cacheWriteProc.running = true
  }

  // --- Position sync ---
  function syncPosition() {
    if (!hasMedia || !positionSupported) {
      livePosition = 0
      return
    }
    livePosition = currentPosition()
    if (lyricsMode === "synced") updateCurrentIndex()
  }

  function updateCurrentIndex() {
    if (lyricsMode !== "synced" || !lyricsLines || lyricsLines.length === 0) {
      if (currentIndex !== -1) currentIndex = -1
      if (currentWordIndex !== -1) currentWordIndex = -1
      return
    }
    var idx = Parser.findCurrentIndex(lyricsLines, livePosition)
    if (idx !== currentIndex) currentIndex = idx
    // Word karaoke: estimated timing derived from line timestamps, not audio.
    var words = []
    if (idx >= 0 && idx < lyricsLines.length && lyricsLines[idx] && lyricsLines[idx].words) words = lyricsLines[idx].words
    var wIdx = Estimator.findCurrentWordIndex(words, livePosition)
    // console.log("updateCurrentIndex pos", livePosition, "idx", idx, "words", words.length, "wIdx", wIdx, "line", idx>=0?lyricsLines[idx].text:"")
    if (wIdx !== currentWordIndex) currentWordIndex = wIdx
  }

  onLivePositionChanged: {
    if (lyricsMode === "synced") updateCurrentIndex()
  }

  onLyricsLinesChanged: updateCurrentIndex()

  Timer {
    id: positionTimer
    repeat: true
    // A sampled route needs finer ticks than a live one to keep word timing
    // smooth between samples.
    interval: root.activePlayer ? 1000 : 250
    running: root.hasMedia && root.isPlaying && root.lyricsMode === "synced"
    triggeredOnStart: true
    onTriggered: root.syncPosition()
  }

  // Also sync immediately on play/pause/seek-visible changes
  Connections {
    target: root.activePlayer
    enabled: !!root.activePlayer
    function onIsPlayingChanged() { if (root.lyricsMode === "synced") root.syncPosition() }
  }

  onMediaTrackChanged: {
    syncPosition()
    // checkTrackSignal handles lifecycle; also ensure position sync after switch
    if (hasMedia) {
      var sig = trackSignature()
      if (sig !== _lastSignature) {
        _lastSignature = sig
        onTrackChanged()
      }
    } else {
      invalidateRequests()
      clearLyrics()
    }
  }

  Component.onCompleted: {
    _lastSignature = trackSignature()
    syncPosition()
    if (hasMedia) startFetch()
  }

  // --- Processes ---
  Process {
    id: cacheReadProc
    property int reqId: 0
    property string sig: ""
    property string title: ""
    property string artist: ""
    property string album: ""
    property real duration: 0
    stdout: StdioCollector { id: cacheReadOut; waitForEnd: true }
    onExited: function(code) {
      var text = String(cacheReadOut.text || "")
      root.handleCacheResult(reqId, sig, title, artist, album, duration, code, text)
    }
  }

  Process {
    id: getProc
    property int reqId: 0
    property string sig: ""
    property string title: ""
    property string artist: ""
    property string album: ""
    property real duration: 0
    stdout: StdioCollector { id: getOut; waitForEnd: true }
    stderr: StdioCollector { id: getErr; waitForEnd: true }
    onExited: function(code) {
      if (reqId !== root.activeRequestId || sig !== root.activeRequestSig) return
      var text = String(getOut.text || "")
      var err = String(getErr.text || "")
      if (code === 0 && text.trim().length > 0) {
        var raw = Provider.parseGetResponseText(text)
        if (!raw) {
          root.fetchSearchFallback(reqId, sig, title, artist, album, duration)
          return
        }
        var res = Provider.normalizeResult(raw)
        if (res.mode === "notfound") {
          root.fetchSearchFallback(reqId, sig, title, artist, album, duration)
          return
        }
        root.applyResult(reqId, sig, res)
        return
      }
      // 404 or empty → try search fallback if not already tried
      if (code !== 0 && (text.trim() === "" || code === 22)) {
        // curl -f exits 22 on 404
        root.fetchSearchFallback(reqId, sig, title, artist, album, duration)
        return
      }
      // Network error → offline/error
      var isOffline = err.indexOf("Could not resolve") !== -1 || err.indexOf("Failed to connect") !== -1 || err.indexOf("Network is unreachable") !== -1 || code === 6 || code === 7
      root.applyError(reqId, sig, isOffline ? "Offline — cannot fetch lyrics" : "Failed to fetch lyrics", isOffline)
    }
  }

  Process {
    id: searchProc
    property int reqId: 0
    property string sig: ""
    property string title: ""
    property string artist: ""
    property string album: ""
    property real duration: 0
    stdout: StdioCollector { id: searchOut; waitForEnd: true }
    stderr: StdioCollector { id: searchErr; waitForEnd: true }
    onExited: function(code) {
      if (reqId !== root.activeRequestId || sig !== root.activeRequestSig) return
      var text = String(searchOut.text || "")
      var err = String(searchErr.text || "")
      if (code === 0 && text.trim().length > 0) {
        var arr = Provider.parseGetResponseText(text)
        // search returns array
        var best = Provider.pickBestSearchCandidate(arr, title, artist, album, duration)
        if (!best) {
          root.applyResult(reqId, sig, { mode: "notfound", syncedLyrics: "", plainLyrics: "", source: "lrclib" })
          return
        }
        var res = Provider.normalizeResult(best)
        root.applyResult(reqId, sig, res)
        return
      }
      var isOffline = String(searchErr.text || "").indexOf("Could not resolve") !== -1 || code === 6 || code === 7
      if (code !== 0 && isOffline) {
        root.applyError(reqId, sig, "Offline — cannot fetch lyrics", true)
        return
      }
      root.applyResult(reqId, sig, { mode: "notfound", syncedLyrics: "", plainLyrics: "", source: "lrclib" })
    }
  }

  Process { id: cacheWriteProc }

  // --- playerctl route ---------------------------------------------------
  //
  // Last-resort media source: straight MPRIS, no host API. Runs only while no
  // better route is supplying data, so on a host where omarchy.media is
  // reachable this never spawns anything.
  readonly property string fieldSeparator: String.fromCharCode(31)

  readonly property string playerctlScript: [
    "sep=$(printf '\\037')",
    // Prefer a player that is actually playing; fall back to the first one.
    "name=$(playerctl -l 2>/dev/null | while read -r n; do",
    "  [ \"$(playerctl -p \"$n\" status 2>/dev/null)\" = \"Playing\" ] && { printf '%s' \"$n\"; break; }",
    "done)",
    "[ -n \"$name\" ] || name=$(playerctl -l 2>/dev/null | head -n1)",
    "[ -n \"$name\" ] || exit 2",
    "m=$(playerctl -p \"$name\" metadata --format \"{{status}}${sep}{{mpris:length}}${sep}{{xesam:title}}${sep}{{xesam:artist}}${sep}{{xesam:album}}${sep}{{mpris:artUrl}}\" 2>/dev/null) || exit 2",
    "[ -n \"$m\" ] || exit 2",
    "p=$(playerctl -p \"$name\" position 2>/dev/null) || p=0",
    "printf '%s%s%s' \"$m\" \"$sep\" \"$p\""
  ].join("\n")

  function parsePlayerctl(text) {
    var parts = String(text || "").split(root.fieldSeparator)
    if (parts.length < 7) return null
    var title = String(parts[2] || "").trim()
    var artist = String(parts[3] || "").trim()
    if (!title && !artist) return null
    // mpris:length is microseconds; the rest of this service works in seconds.
    var lengthUs = Number(parts[1])
    return {
      title: title,
      artist: artist,
      album: String(parts[4] || "").trim(),
      artUrl: String(parts[5] || "").trim(),
      duration: isFinite(lengthUs) && lengthUs > 0 ? lengthUs / 1000000 : 0,
      isPlaying: String(parts[0] || "").trim() === "Playing",
      positionSupported: true,
      position: Number(parts[6]) || 0,
      positionAt: Date.now()
    }
  }

  Timer {
    id: playerctlTimer
    // Sampling only has to be fine-grained while synced lyrics are scrolling.
    interval: root.lyricsMode === "synced" && root.isPlaying ? 1000 : 3000
    repeat: true
    running: root.needsPlayerctl
    triggeredOnStart: true
    onTriggered: if (!playerctlProc.running) playerctlProc.running = true
  }

  Process {
    id: playerctlProc
    command: ["bash", "-c", root.playerctlScript]
    stdout: StdioCollector { id: playerctlOut; waitForEnd: true }
    onExited: function(code) {
      if (!root.needsPlayerctl) return
      root.polledMedia = code === 0 ? root.parsePlayerctl(String(playerctlOut.text || "")) : null
      root.syncPosition()
    }
  }

  IpcHandler {
    target: "sumiran.lyrics-service"

    function status(): string {
      return JSON.stringify({
        hasMedia: root.hasMedia,
        title: root.currentTitle,
        artist: root.currentArtist,
        album: root.currentAlbum,
        artUrl: root.currentArtUrl,
        duration: root.currentDuration,
        route: root.mediaRoute,
        isPlaying: root.isPlaying,
        mode: root.lyricsMode,
        status: root.status,
        lines: root.lyricsLines ? root.lyricsLines.length : 0,
        currentIndex: root.currentIndex,
        currentWordIndex: root.currentWordIndex,
        isCompleting: root.isLineCompleting,
        position: root.livePosition,
        requestId: root.activeRequestId,
        pendingSearch: root.pendingSearch
      })
    }

    function clear(): string {
      root.invalidateRequests()
      root.clearLyrics()
      return "ok"
    }

    function refetch(): string {
      if (!root.hasMedia) return "no-media"
      root.requestSerial += 1
      root.activeRequestId = root.requestSerial
      root.activeRequestSig = root.trackSignature()
      root.clearLyricsForNewTrack()
      root.startFetch()
      return "ok"
    }

    function debugCachePath(): string {
      return Provider.cacheFilePathExpanded(root.home, root.currentTitle, root.currentArtist, root.currentAlbum, root.currentDuration)
    }
  }
}
