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

  readonly property var mediaService: shell ? shell.firstPartyServiceFor("omarchy.media") : null
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null

  readonly property string currentTitle: activePlayer ? String(activePlayer.trackTitle || "") : ""
  readonly property string currentArtist: activePlayer ? String(activePlayer.trackArtist || "") : ""
  readonly property string currentAlbum: activePlayer ? String(activePlayer.trackAlbum || "") : ""
  readonly property string currentArtUrl: activePlayer ? String(activePlayer.trackArtUrl || "") : ""
  readonly property real currentDuration: activePlayer && activePlayer.length ? Number(activePlayer.length) : 0
  readonly property bool hasMedia: !!(activePlayer && (activePlayer.trackTitle || activePlayer.trackArtist))

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
    if (!activePlayer || !activePlayer.positionSupported) {
      livePosition = 0
      return
    }
    livePosition = Number(activePlayer.position) || 0
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
    interval: 1000
    repeat: true
    running: root.hasMedia && !!root.activePlayer && !!root.activePlayer.isPlaying && root.lyricsMode === "synced"
    triggeredOnStart: true
    onTriggered: root.syncPosition()
  }

  // Also sync immediately on play/pause/seek-visible changes
  Connections {
    target: activePlayer
    enabled: !!root.activePlayer
    function onIsPlayingChanged() { if (root.lyricsMode === "synced") root.syncPosition() }
  }

  onActivePlayerChanged: {
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
