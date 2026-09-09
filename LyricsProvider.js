// LyricsProvider.js — pure helpers for LRCLIB + cache + normalization
.pragma library

var LRCLIB_BASE = "https://lrclib.net"

function sanitize(value) {
  return String(value || "").trim()
}

function collapseWhitespace(value) {
  return sanitize(value).replace(/\s+/g, " ")
}

function stripSuffixes(value) {
  var s = collapseWhitespace(value)
  // Remove common video/metadata suffixes conservatively
  s = s.replace(/\s*\(Official Video\)\s*$/i, "")
  s = s.replace(/\s*\(Official Music Video\)\s*$/i, "")
  s = s.replace(/\s*\(Official Lyric Video\)\s*$/i, "")
  s = s.replace(/\s*\(Lyric Video\)\s*$/i, "")
  s = s.replace(/\s*\(Audio\)\s*$/i, "")
  s = s.replace(/\s*\(Visualizer\)\s*$/i, "")
  // Remove trailing " - Remastered" / " (Remastered YYYY)" variants
  s = s.replace(/\s*-\s*Remastered(\s+\d{4})?\s*$/i, "")
  s = s.replace(/\s*\(Remastered(\s+\d{4})?\)\s*$/i, "")
  s = s.replace(/\s*\[Remastered[^\]]*\]\s*$/i, "")
  return s.trim()
}

function normalizeField(value) {
  return stripSuffixes(collapseWhitespace(value))
}

function normalizedLower(value) {
  return normalizeField(value).toLowerCase()
}

function escapeRegExp(value) {
  return String(value || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// A browser reports the uploading channel as the artist, so what arrives is
// "Cigarettes After Sex - Topic" rather than "Cigarettes After Sex". LRCLIB
// matches on the real name and returns nothing for the channel form.
function cleanArtist(value) {
  var a = normalizeField(value)
  a = a.replace(/\s*[-\u2013\u2014]\s*Topic\s*$/i, "")
  a = a.replace(/\s*VEVO\s*$/i, "")
  a = a.replace(/\s*[-\u2013\u2014]\s*Official(\s+Channel)?\s*$/i, "")
  return collapseWhitespace(a)
}

// A browser also hands over the whole video title. Drop the decoration a music
// service would never have attached, and the "Artist - " the title repeats.
function cleanTitle(value, artist) {
  var t = collapseWhitespace(value)
  t = t.replace(/\s*[\(\[][^\)\]]*\b(Official|Lyric|Lyrics|Visualizer|Audio|Video|MV|HD|HQ|4K)\b[^\)\]]*[\)\]]/gi, " ")
  t = t.replace(/\s*\|[^|]*$/, "")
  t = collapseWhitespace(t)
  var a = cleanArtist(artist)
  if (a) t = t.replace(new RegExp("^" + escapeRegExp(a) + "\\s*[-\u2013\u2014:]\\s*", "i"), "")
  return stripSuffixes(collapseWhitespace(t))
}

// The single place that turns whatever the player reported into the fields
// LRCLIB is asked about, so the request, the search fallback, the candidate
// scoring and the cache key all agree on what the track is called.
function resolveFields(title, artist, album) {
  var a = cleanArtist(artist)
  var t = cleanTitle(title, artist)
  // With no artist at all the title is usually "Artist - Title".
  if (!a) {
    var split = t.match(/^(.{1,80}?)\s+[-\u2013\u2014]\s+(.+)$/)
    if (split) {
      a = collapseWhitespace(split[1])
      t = collapseWhitespace(split[2])
    }
  }
  return { title: t, artist: a, album: normalizeField(album) }
}

// Deterministic hash for cache filenames (djb2 -> hex)
function hashString(str) {
  var s = String(str || "")
  var h = 5381
  for (var i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0
  // Mix length to reduce collisions
  h = (h ^ s.length) >>> 0
  var hex = h.toString(16)
  while (hex.length < 8) hex = "0" + hex
  return hex
}

function buildCacheKey(title, artist, album, duration) {
  var f = resolveFields(title, artist, album)
  var t = String(f.title || "").toLowerCase()
  var a = String(f.artist || "").toLowerCase()
  var al = String(f.album || "").toLowerCase()
  var d = String(Math.round(Number(duration) || 0))
  return a + "|" + t + "|" + al + "|" + d
}

function cacheFileName(title, artist, album, duration) {
  return hashString(buildCacheKey(title, artist, album, duration)) + ".json"
}

// Called from QML with expanded HOME
function cacheFilePathExpanded(home, title, artist, album, duration) {
  var h = String(home || "").replace(/\/$/, "")
  return h + "/.cache/omarchy-lyrics/" + cacheFileName(title, artist, album, duration)
}

function buildGetUrl(title, artist, album, duration) {
  var n = normalizeForRequest(title, artist, album, duration)
  var url = LRCLIB_BASE + "/api/get"
    + "?artist_name=" + encodeURIComponent(n.artist)
    + "&track_name=" + encodeURIComponent(n.title)
    + "&album_name=" + encodeURIComponent(n.album)
    + "&duration=" + encodeURIComponent(String(Math.round(n.duration)))
  return url
}

function buildSearchUrl(title, artist, album) {
  var f = resolveFields(title, artist, album)
  var t = f.title
  var a = f.artist
  var al = f.album
  // LRCLIB search uses q=...; include artist+title for better match
  var q = ""
  if (a && t) q = a + " " + t
  else if (t) q = t
  else if (a) q = a
  var url = LRCLIB_BASE + "/api/search"
    + "?q=" + encodeURIComponent(q)
    + "&track_name=" + encodeURIComponent(t)
    + "&artist_name=" + encodeURIComponent(a)
    + "&album_name=" + encodeURIComponent(al)
  return url
}

function normalizeForRequest(title, artist, album, duration) {
  var f = resolveFields(title, artist, album)
  return {
    title: f.title,
    artist: f.artist,
    album: f.album,
    duration: Number(duration) || 0
  }
}

function isUsableSynced(s) {
  if (!s || typeof s !== "string") return false
  var t = s.trim()
  if (t.length < 10) return false
  // Must contain at least one timestamp line
  return /\[(\d+):(\d+)(?:\.(\d+))?\]/.test(t)
}

function isUsablePlain(s) {
  if (!s || typeof s !== "string") return false
  return s.trim().length >= 10
}

function normalizeResult(raw) {
  // raw is parsed JSON from LRCLIB /get (or search candidate)
  if (!raw || typeof raw !== "object") return { mode: "notfound", syncedLyrics: "", plainLyrics: "", source: "lrclib" }
  var synced = raw.syncedLyrics
  var plain = raw.plainLyrics
  if (isUsableSynced(synced)) return { mode: "synced", syncedLyrics: String(synced), plainLyrics: isUsablePlain(plain) ? String(plain) : "", source: "lrclib" }
  if (isUsablePlain(plain)) return { mode: "plain", syncedLyrics: "", plainLyrics: String(plain), source: "lrclib" }
  return { mode: "notfound", syncedLyrics: "", plainLyrics: "", source: "lrclib" }
}

function scoreCandidate(candidate, normTitle, normArtist, normAlbum, duration) {
  if (!candidate || typeof candidate !== "object") return -1
  var ct = normalizedLower(candidate.trackName || candidate.name || "")
  var ca = normalizedLower(candidate.artistName || "")
  var cal = normalizedLower(candidate.albumName || "")
  var dur = Number(candidate.duration)
  var score = 0
  var nt = normalizedLower(normTitle)
  var na = normalizedLower(normArtist)
  var nal = normalizedLower(normAlbum)

  if (nt && ct === nt) score += 40
  else if (nt && ct && (ct.indexOf(nt) !== -1 || nt.indexOf(ct) !== -1)) score += 15

  if (na && ca === na) score += 30
  else if (na && ca && (ca.indexOf(na) !== -1 || na.indexOf(ca) !== -1)) score += 10

  if (nal && cal && cal === nal) score += 10

  if (isFinite(dur) && isFinite(duration) && duration > 0) {
    var diff = Math.abs(dur - duration)
    if (diff <= 2) score += 20
    else if (diff <= 5) score += 10
    else if (diff <= 10) score += 3
    else score -= 10
  }

  // Prefer synced availability
  if (isUsableSynced(candidate.syncedLyrics)) score += 5
  else if (isUsablePlain(candidate.plainLyrics)) score += 1
  else score -= 20

  return score
}

function pickBestSearchCandidate(candidates, title, artist, album, duration) {
  if (!candidates || !Array.isArray(candidates) || candidates.length === 0) return null
  var picked = resolveFields(title, artist, album)
  var nTitle = picked.title
  var nArtist = picked.artist
  var nAlbum = picked.album
  var nDur = Number(duration) || 0
  var best = null
  var bestScore = -1
  for (var i = 0; i < candidates.length; i++) {
    var c = candidates[i]
    var s = scoreCandidate(c, nTitle, nArtist, nAlbum, nDur)
    if (s > bestScore) { bestScore = s; best = c }
  }
  // Require minimum score to avoid blind acceptance
  if (bestScore < 50) return null
  return best
}

function parseGetResponseText(text) {
  if (!text || typeof text !== "string") return null
  var t = text.trim()
  if (t.length === 0) return null
  try { return JSON.parse(t) } catch (e) { return null }
}
