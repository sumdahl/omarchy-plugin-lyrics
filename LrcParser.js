// LrcParser.js — pure helpers, no QML dependencies
.pragma library

function parse(syncedLyrics) {
  if (!syncedLyrics || typeof syncedLyrics !== "string") return []
  var lines = syncedLyrics.split("\n")
  var result = []
  var tsRe = /\[(\d+):(\d+)(?:\.(\d+))?\]/g
  var metaRe = /^\[(ar|ti|al|by|offset):/i

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var trimmed = String(line).trim()
    if (trimmed === "") continue
    if (metaRe.test(trimmed)) continue

    var times = []
    var m
    tsRe.lastIndex = 0
    while ((m = tsRe.exec(line)) !== null) {
      var min = parseInt(m[1], 10)
      var sec = parseInt(m[2], 10)
      var frac = m[3] || ""
      if (!isFinite(min) || !isFinite(sec) || min < 0 || sec < 0 || sec >= 60) continue
      var ms = 0
      if (frac.length === 1) ms = parseInt(frac, 10) * 100
      else if (frac.length === 2) ms = parseInt(frac, 10) * 10
      else if (frac.length === 3) ms = parseInt(frac, 10)
      else if (frac.length > 3) ms = parseInt(frac.substring(0, 3), 10)
      var time = min * 60 + sec + ms / 1000
      if (!isFinite(time) || time < 0) continue
      times.push(time)
    }
    if (times.length === 0) continue

    // Strip all timestamps to get lyric text
    var text = String(line).replace(tsRe, "").trim()
    if (text.length === 0) continue

    for (var t = 0; t < times.length; t++) {
      result.push({ time: times[t], text: text })
    }
  }

  result.sort(function(a, b) { return a.time - b.time })
  return result
}

function findCurrentIndex(lines, position) {
  if (!lines || lines.length === 0) return -1
  var pos = Number(position)
  if (!isFinite(pos) || pos < 0) pos = 0

  // Binary search: last index where time <= pos
  var low = 0
  var high = lines.length - 1
  var ans = -1
  while (low <= high) {
    var mid = (low + high) >> 1
    if (lines[mid].time <= pos) {
      ans = mid
      low = mid + 1
    } else {
      high = mid - 1
    }
  }
  return ans
}
