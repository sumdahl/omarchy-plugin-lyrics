# sumiran.lyrics — Synced Lyrics for Omarchy

Standalone Omarchy bar-widget + service. Shows synced (karaoke) or plain lyrics for **any MPRIS player** via [LRCLIB](https://lrclib.net).

**ID:** `sumiran.lyrics` · `keepLoaded:true` · `bar-widget` `󰎆` → `KeyboardPanel` popup. No daemon. Needs the `playerctl` package when the host does not hand this plugin its media service (see Supported Players).

## Location

```
~/.config/omarchy/plugins/sumiran.lyrics/
```

Registered in `~/.config/omarchy/shell.json`:

```json
{ "plugins": [{ "id": "sumiran.lyrics" }],
  "bar": { "layout": { "right": [{ "id": "sumiran.lyrics" }, …] } } }
```

Reload: `omarchy restart shell` · Remove: delete both entries → restart.

## Usage

- **Bar icon** dim when no track → click to open. Middle-click play/pause, wheel prev/next.
- **Popup** `360px` centered, capped `280px`: title · artist · `SYNCED`/`PLAIN` badge.
  - Synced: karaoke `ListView` centered highlight (accent, bold, scale 1.02), auto-scroll with 3s manual cooldown.
  - Plain: scrollable text, no fake sync.
  - States: `Play a track…` (idle), `Loading…`, `Lyrics not found`, `Unable to fetch…` (offline/error).
- **IPC**: `omarchy-shell sumiran.lyrics-service status` → `{hasMedia,title,artist,album,duration,route,isPlaying,mode,status,lines,currentIndex,currentWordIndex,position}`. Also `refetch`/`clear`.

## Supported Players

Any MPRIS player. Tested: Spotify, Brave (YouTube), mpv. Not Spotify-only.

Track metadata arrives by whichever of three routes the running Omarchy allows, most direct first. `mediaRoute` in the IPC status reports the live one.

1. **`service`** — `firstPartyServiceFor("omarchy.media")` straight off this plugin's shell. Omarchy 4.0.2 and earlier handed every plugin service the real shell; from 4.0.3 this is granted only to plugins declaring kind `bar`, so a bar-widget no longer gets it.
2. **`widget`** — mirrored in from the bar widget, which on some hosts reaches `omarchy.media` when the service cannot.
3. **`playerctl`** — read from MPRIS directly, touching no host API, so it keeps working across changes to the plugin sandbox. This is the route in use on Omarchy 4.0.3. It needs the `playerctl` package, available from the Arch repositories.

Each route falls through to the next on its own, and a more direct one takes over again as soon as it becomes available.

Metadata from a browser is cleaned before lookup: LRCLIB matches on real artist names, not channel names, so `resolveFields()` strips `- Topic` and `VEVO` suffixes, bracketed `(Official Video)`-style decoration, a trailing `| Channel`, and an `Artist - ` prefix the title repeats. It also splits `Artist - Title` when the artist field is empty.

## Provider

**LRCLIB** only (MVP):

- `GET /api/get?artist_name=&track_name=&album_name=&duration=` (URL-encoded, suffix-stripped `Remastered`/`Official Video`). `→ synced→plain→notfound` by `isUsableSynced` (`[mm:ss.xx]` + ≥10 chars).
- `404/empty → GET /api/search?q=…` scored (title 40, artist 30, album 10, duration ±2s 20, synced +5, threshold ≥50) → best or `notfound`.
- Network errors (`Could not resolve`, `exit 6/7`) → `offline`, never crashes.

## Cache

`~/.cache/omarchy-lyrics/<djb2-hash>.json` hash of `artist|title|album|round(duration)` lowercased/normalized. `mkdir -p` + `printf` + `cat`; corrupt/missing → refetch; write failures ignored.

## Synced vs Plain

- **Synced**: parsed `LrcParser` (`[00:12.34]`, `[01:02]`, `[00:10][00:12]text`, `[ar:` ignored), sorted, binary search `findCurrentIndex`. `positionTimer 1000ms` when `synced&&playing`, source is `MPRIS position`. Each line enriched with estimated word timings via `WordTimingEstimator` (see below).
- **Plain**: `plainLyrics.split("\n")` displayed as readable list, no highlight.

## Estimated Word Karaoke

Word timing is **estimated from line-level LRC timestamps, not audio-derived** and may differ from actual vocal timing. `WordTimingEstimator` tokenizes robustly (preserves `can't`/`well-known`, handles Unicode, filters punctuation-only), weights by `normalized length` (function words `*0.75`, long `*1.1`, tiny punctuation `*1.04/1.06`), conserves `[lineStart, lineEnd]` (next line time; final line `words:[]`), validates `start<end` ordered inside line, falls back to line highlight when infeasible (single word, `duration<0.6` with dense words, missing `lineEnd`). `Service` exposes `currentWordIndex` via `Estimator.findCurrentWordIndex` (binary) derived from `livePosition`; `LyricsPanel` highlights completed/current/future words in active line (`Flow` of word `Text`, accent `1.0` current, `0.9` completed, `0.45` future, no scale to avoid reflow). No new timer, no audio analysis.

## Files

```
manifest.json            service+bar-widget, keepLoaded, defaults {autoFetch:true}
Service.qml              sole source of truth: lyricsLines/mode/currentIndex/currentWordIndex/status, stale-token, duration 0→real retry, position sync
Panel.qml                BarWidget + KeyboardPanel, passes lyricsService
LyricsPanel.qml          presentation only (Flow karaoke for active line, ListView line centering)
LyricsProvider.js        LRCLIB + cache + normalize (pragma library)
LrcParser.js             pure LRC parser (pragma library)
WordTimingEstimator.js   pure word estimation + findCurrentWordIndex (pragma library)
```

## Known Limitations

- Requires MPRIS player emitting `trackTitle/trackArtist` (browser needs media integration).
- LRCLIB coverage incomplete; instrumental/notfound → `notfound` state.
- No floating overlay, line click-to-seek, copy, or second provider (future).
- `canSeek false` players ignore seek but UI stays consistent via `positionSupported` guard.

## Validation

```bash
qmllint Service.qml Panel.qml LyricsPanel.qml  # 0
omarchy-shell sumiran.lyrics-service status | jq .
# Shesmovedon → synced 42 lines
# Sentimental/Sleep Together → plain
# Hell's Kitchen → notfound
# Seek/pause/track-change/rapid A→B→C → currentIndex follows, no stale overwrite
# Shell restart while playing → ready via cache
```

Phase 3 `qmllint 0`, JS `new Function` OK, multi-monitor `KeyboardPanel` OK.

License: MIT
