// WordTimingEstimator.js — pure word timing estimation from line-level LRC
// No QML, no MPRIS, no network, no timers. Deterministic, lightweight.
// Future AudioWordAligner can replace estimateWords without changing Service/UI.
.pragma library

// Short function words receive slightly less weight
var FUNCTION_WORDS = {
  "a": true, "an": true, "the": true, "i": true, "to": true, "of": true,
  "in": true, "on": true, "and": true, "or": true, "is": true, "are": true,
  "was": true, "were": true, "be": true, "been": true, "have": true, "has": true,
  "had": true, "do": true, "does": true, "did": true, "for": true, "with": true,
  "at": true, "by": true, "as": true, "it": true, "we": true, "you": true,
  "he": true, "she": true, "my": true, "your": true, "me": true, "us": true
}

function tokenize(text) {
  if (!text || typeof text !== "string") return []
  var trimmed = text.trim()
  if (trimmed === "") return []
  var raw = trimmed.match(/\S+/g)
  if (!raw) return []
  var out = []
  for (var i = 0; i < raw.length; i++) {
    var tok = raw[i]
    // Filter punctuation-only tokens — keep only if contains letter/number
    // Use conservative ASCII + extended Latin to avoid QML engine Unicode property issues
    var hasAlnum = /[A-Za-z0-9\u00C0-\u024F\u0400-\u04FF]/.test(tok)
    if (!hasAlnum) continue
    out.push(tok)
  }
  return out
}

function normalizedLength(word) {
  var s = String(word || "")
  // Strip leading/trailing punctuation for weight
  var stripped = s.replace(/^[^A-Za-z0-9\u00C0-\u024F\u0400-\u04FF]+|[^A-Za-z0-9\u00C0-\u024F\u0400-\u04FF]+$/g, "")
  if (stripped.length > 0) s = stripped
  if (s.length === 0) s = word
  return s.length
}

function isFunctionWord(word) {
  var n = String(word || "").toLowerCase().replace(/^[^A-Za-z0-9\u00C0-\u024F\u0400-\u04FF]+|[^A-Za-z0-9\u00C0-\u024F\u0400-\u04FF]+$/g, "")
  return !!FUNCTION_WORDS[n]
}

function estimateWords(text, lineStart, lineEnd) {
  var start = Number(lineStart)
  var end = Number(lineEnd)
  if (!isFinite(start) || start < 0) return []
  // Final line or missing end → no reliable boundary → fallback to line highlight
  if (!isFinite(end) || end <= start) return []

  var duration = end - start
  // Very short line with multiple words would be meaningless
  // But don't reject long lines solely by word count — check feasibility after weighting
  var tokens = tokenize(text)
  if (tokens.length === 0) return []
  if (tokens.length === 1) return [] // single word → line highlight sufficient

  // If duration is too short for word separation, fallback
  // Approx 0.15s per word minimum meaningful
  if (duration < 0.6 && tokens.length > 1) {
    // Allow 2 words in 0.6s (0.3s each) but not 5 words in 0.5s
    if (duration / tokens.length < 0.18) return []
  }

  // Compute weights
  var weights = []
  var total = 0
  for (var i = 0; i < tokens.length; i++) {
    var w = tokens[i]
    var len = normalizedLength(w)
    if (len <= 0) len = w.length
    var weight = len
    // Function words slightly less
    if (isFunctionWord(w)) weight *= 0.75
    else if (len > 6) weight *= 1.1
    // Tiny punctuation influence (proportional, not fixed)
    var last = w.charAt(w.length - 1)
    if (last === ",") weight *= 1.04
    else if (last === "." || last === "!" || last === "?" || last === ";" || last === ":") weight *= 1.06
    // Clamp weight to avoid absurd dominance but keep proportional
    if (weight < 0.5) weight = 0.5
    weights.push(weight)
    total += weight
  }
  if (total <= 0) return []

  // Generate intervals conserving total duration
  var words = []
  var cur = start
  for (var j = 0; j < tokens.length; j++) {
    var dur = duration * (weights[j] / total)
    var wStart = cur
    var wEnd = cur + dur
    // Last word must end exactly at lineEnd (conservation)
    if (j === tokens.length - 1) wEnd = end
    words.push({ text: tokens[j], start: wStart, end: wEnd })
    cur = wEnd
  }

  // Validate final intervals — every word must be ordered and inside line window
  for (var k = 0; k < words.length; k++) {
    var wd = words[k]
    if (!isFinite(wd.start) || !isFinite(wd.end) || wd.start >= wd.end) return []
    if (wd.start < start - 0.001 || wd.end > end + 0.001) return []
    if (k > 0 && words[k-1].end > wd.start + 0.001) return []
  }

  return words
}

function findCurrentWordIndex(words, position) {
  if (!words || words.length === 0) return -1
  var pos = Number(position)
  if (!isFinite(pos)) return -1

  // Before first word
  if (pos < words[0].start) return -1
  // After or at last word's end → last word (or -1 if beyond? For karaoke, keep last highlighted)
  if (pos >= words[words.length - 1].end) return words.length - 1

  // Binary search: last word where start <= pos < end, or start <= pos if between
  var low = 0, high = words.length - 1, ans = -1
  while (low <= high) {
    var mid = (low + high) >> 1
    var w = words[mid]
    if (pos >= w.start) {
      // pos is at or after this word's start
      // Check if pos < end → this word is active
      // If pos >= end, look for later word that has started
      if (pos < w.end) {
        ans = mid
        // Don't break, but we found candidate; however there could be earlier? No, start <= pos and pos < end uniquely identifies
        break
      } else {
        // pos past this word's end, but before next word's start? Could be gap.
        // For karaoke, between words we keep previous word as current until next starts
        ans = mid
        low = mid + 1
      }
    } else {
      high = mid - 1
    }
  }
  // If we ended in gap between words (pos >= words[ans].end but < next start), keep ans as previous
  // Ensure ans is the greatest index with start <= pos
  if (ans !== -1) {
    // Verify that pos is indeed >= words[ans].start
    // But if pos is in gap, this is still the previous word which is desired
    return ans
  }
  // Fallback linear for correctness (small n)
  for (var i = words.length - 1; i >= 0; i--) {
    if (pos >= words[i].start) return i
  }
  return -1
}
