import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var bar: null
  property var lyricsService: null

  readonly property bool hasMedia: lyricsService ? !!lyricsService.hasMedia : false
  readonly property string title: lyricsService ? String(lyricsService.currentTitle || "") : ""
  readonly property string artist: lyricsService ? String(lyricsService.currentArtist || "") : ""
  readonly property string album: lyricsService ? String(lyricsService.currentAlbum || "") : ""
  readonly property string artUrl: lyricsService ? String(lyricsService.currentArtUrl || "") : ""
  readonly property string mode: lyricsService ? String(lyricsService.lyricsMode || "none") : "none"
  readonly property string status: lyricsService ? String(lyricsService.status || "idle") : "idle"
  readonly property string statusMessage: lyricsService ? String(lyricsService.statusMessage || "") : ""
  readonly property var lines: lyricsService ? lyricsService.lyricsLines : []
  readonly property int currentIndex: lyricsService ? Number(lyricsService.currentIndex) : -1
  readonly property int currentWordIndex: lyricsService ? Number(lyricsService.currentWordIndex) : -1
  // Visual completion — does not modify words[]; reversible on seek
  readonly property bool isCompleting: lyricsService ? !!lyricsService.isLineCompleting : false
  readonly property string plainLyrics: lyricsService ? String(lyricsService.plainLyrics || "") : ""

  // Plain split for list display (keep empty lines for spacing)
  readonly property var plainLines: {
    if (!plainLyrics || plainLyrics.trim() === "") return []
    return plainLyrics.split("\n")
  }

  implicitHeight: column.implicitHeight
  // Allow manual scroll to suppress auto-centering briefly
  property bool userScrolling: false

  Timer {
    id: userScrollCooldown
    interval: 3000
    onTriggered: root.userScrolling = false
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(12)

    // Premium song header — album art + title + artist · album
    Column {
      width: parent.width
      spacing: Style.space(8)

      // Album art — 72px rounded, fallback glyph
      BorderSurface {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(72)
        height: Style.space(72)
        radius: 10
        color: Style.normalFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
        borderSpec: Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
        visible: root.hasMedia

        Image {
          id: art
          anchors.fill: parent
          anchors.margins: 2
          source: root.artUrl
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          visible: status === Image.Ready
          sourceSize.width: width * Screen.devicePixelRatio
          sourceSize.height: height * Screen.devicePixelRatio
        }

        Text {
          anchors.centerIn: parent
          visible: art.status !== Image.Ready
          text: art.status === Image.Loading ? "󰧑" : "󰝚"
          color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.display
        }
      }

      // Title — prominent, centered, elide
      Text {
        width: parent.width
        text: root.title !== "" ? root.title : (root.hasMedia ? "Unknown title" : "No track")
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : ""
        font.pixelSize: Style.font.heading
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        visible: root.hasMedia
      }

      // Artist · Album — artist stronger, album subtle
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(4)
        visible: root.hasMedia && (root.artist !== "" || root.album !== "")

        Text {
          text: root.artist
          visible: root.artist !== ""
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          text: "·"
          visible: root.artist !== "" && root.album !== ""
          color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          text: root.album
          visible: root.album !== ""
          color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }

      // Mode badge + loading — keep subtle, below identity
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)
        visible: root.hasMedia

        BorderSurface {
          visible: root.mode === "synced" || root.mode === "plain"
          radius: Style.spacing.labelGap
          color: root.mode === "synced" ? Color.accent : Style.normalFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
          implicitHeight: modeLabel.implicitHeight + Style.space(6)
          implicitWidth: modeLabel.implicitWidth + Style.space(12)

          Text {
            id: modeLabel
            anchors.centerIn: parent
            text: root.mode === "synced" ? "SYNCED" : root.mode === "plain" ? "PLAIN" : ""
            color: root.mode === "synced" ? Color.background : (root.bar ? root.bar.foreground : Color.foreground)
            font.family: root.bar ? root.bar.fontFamily : ""
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.status === "loading" ? "Loading…" : ""
          visible: text !== ""
          color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.caption
        }
      }

      // Idle state header (no media) — keep simple
      Text {
        width: parent.width
        text: "Play a track to see lyrics"
        visible: !root.hasMedia
        color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : ""
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }

    PanelSeparator {
      width: parent.width
      foreground: root.bar ? root.bar.foreground : Color.foreground
      visible: root.hasMedia
    }

    // Lyrics container — height controlled per mode
    Item {
      id: lyricsContainer
      width: parent.width
      height: containerHeight
      clip: true

      readonly property int maxHeight: Style.space(280)
      readonly property int minHeight: Style.space(80)
      readonly property int containerHeight: {
        if (!root.hasMedia) return Style.space(60)
        if (root.status === "loading") return Style.space(60)
        if (root.status === "notfound" || root.status === "error" || root.status === "offline") return Style.space(60)
        if (root.mode === "synced" && root.lines.length > 0) return Math.min(maxHeight, Math.max(minHeight, syncedList.contentHeight))
        if (root.mode === "plain" && root.plainLines.length > 0) return Math.min(maxHeight, Math.max(minHeight, plainList.contentHeight))
        return Style.space(60)
      }

      // ---------- idle ----------
      Text {
        anchors.centerIn: parent
        width: parent.width - Style.space(20)
        visible: !root.hasMedia
        text: ""
        // header already shows idle, keep container empty
      }

      // ---------- loading ----------
      Column {
        anchors.centerIn: parent
        width: parent.width
        spacing: Style.space(6)
        visible: root.hasMedia && root.status === "loading"

        Text {
          width: parent.width
          text: "Loading lyrics…"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }
        Text {
          width: parent.width
          text: root.title + (root.artist ? " — " + root.artist : "")
          visible: text !== ""
          color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }

      // ---------- notfound / error / offline ----------
      Column {
        anchors.centerIn: parent
        width: parent.width
        spacing: Style.space(4)
        visible: root.hasMedia && (root.status === "notfound" || root.status === "error" || root.status === "offline")

        Text {
          width: parent.width
          text: root.status === "notfound" ? "Lyrics unavailable" : root.status === "offline" ? "Unable to fetch lyrics" : "Unable to fetch lyrics"
          color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
        Text {
          width: parent.width
          text: root.statusMessage !== "" && root.statusMessage !== "No lyrics found" ? root.statusMessage : ""
          visible: (root.status === "offline" || root.status === "error") && text !== ""
          color: root.bar ? Qt.darker(root.bar.foreground, 1.7) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
        Text {
          width: parent.width
          text: root.title !== "" ? root.title + (root.artist ? " · " + root.artist : "") : ""
          visible: root.status === "notfound" && text !== ""
          color: root.bar ? Qt.darker(root.bar.foreground, 1.8) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }

      // ---------- synced ListView — premium large typography ----------
      ListView {
        id: syncedList
        anchors.fill: parent
        visible: root.hasMedia && root.mode === "synced" && root.lines.length > 0 && root.status === "ready"
        model: root.lines
        clip: true
        spacing: Style.space(6)
        boundsBehavior: Flickable.StopAtBounds

        // Keep current line centered (Spotify-like)
        preferredHighlightBegin: height / 2 - Style.space(18)
        preferredHighlightEnd: height / 2 + Style.space(18)
        highlightRangeMode: ListView.ApplyRange
        highlightMoveDuration: 300
        highlightMoveVelocity: 900
        highlightFollowsCurrentItem: true

        currentIndex: root.currentIndex >= 0 && root.currentIndex < count ? root.currentIndex : -1

        onMovementStarted: { root.userScrolling = true; userScrollCooldown.restart() }
        onFlickStarted: { root.userScrolling = true; userScrollCooldown.restart() }

        Connections {
          target: root
          function onCurrentIndexChanged() {
            if (syncedList.visible && root.mode === "synced" && root.currentIndex >= 0) {
              if (root.userScrolling) return
              Qt.callLater(function() {
                if (!root.userScrolling && syncedList.visible) syncedList.positionViewAtIndex(root.currentIndex, ListView.Center)
              })
            }
          }
        }

        onVisibleChanged: if (visible && root.currentIndex >= 0) Qt.callLater(function() { if (!root.userScrolling) syncedList.positionViewAtIndex(root.currentIndex, ListView.Center) })
        onCountChanged: if (visible && root.currentIndex >= 0) Qt.callLater(function() { if (!root.userScrolling) syncedList.positionViewAtIndex(root.currentIndex, ListView.Center) })

        delegate: Item {
          required property var modelData
          required property int index
          width: ListView.view.width
          implicitHeight: lineText.implicitHeight + Style.space(10)

          Text {
            id: lineText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            text: modelData.text || ""
            // Strong hierarchy: current dominates, surrounding recedes
            color: {
              if (root.currentIndex === index) return Color.accent
              return root.bar ? Qt.darker(root.bar.foreground, 1.6) : Color.foreground
            }
            font.family: root.bar ? root.bar.fontFamily : ""
            // Large premium sizes: current display (24), surrounding heading (16)
            font.pixelSize: root.currentIndex === index ? Style.font.display : Style.font.heading
            font.bold: root.currentIndex === index
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            opacity: {
              if (root.currentIndex === -1) return 1.0
              if (root.currentIndex === index) return 1.0
              return 0.52
            }
          }
        }
      }

      // ---------- plain ListView — large readable ----------
      ListView {
        id: plainList
        anchors.fill: parent
        visible: root.hasMedia && root.mode === "plain" && root.plainLines.length > 0 && root.status === "ready"
        model: root.plainLines
        clip: true
        spacing: Style.space(4)
        boundsBehavior: Flickable.StopAtBounds

        delegate: Text {
          required property var modelData
          required property int index
          width: ListView.view.width - Style.space(12)
          x: Style.space(6)
          text: modelData
          visible: text.trim() !== "" || index === 0
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.title
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.WordWrap
          opacity: text.trim() === "" ? 0.0 : 0.92
          height: text.trim() === "" ? Style.space(8) : implicitHeight
        }
      }
    }
  }
}
