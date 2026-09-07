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
  readonly property string mode: lyricsService ? String(lyricsService.lyricsMode || "none") : "none"
  readonly property string status: lyricsService ? String(lyricsService.status || "idle") : "idle"
  readonly property string statusMessage: lyricsService ? String(lyricsService.statusMessage || "") : ""
  readonly property var lines: lyricsService ? lyricsService.lyricsLines : []
  readonly property int currentIndex: lyricsService ? Number(lyricsService.currentIndex) : -1
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
    spacing: Style.space(10)

    // Header
    Column {
      width: parent.width
      spacing: Style.space(4)

      Text {
        width: parent.width
        text: root.title !== "" ? root.title : (root.hasMedia ? "Unknown title" : "No track")
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : ""
        font.pixelSize: Style.font.subtitle
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        wrapMode: Text.WordWrap
        maximumLineCount: 2
      }

      Text {
        width: parent.width
        text: root.artist
        visible: root.artist !== ""
        color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : ""
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

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
    }

    PanelSeparator {
      width: parent.width
      foreground: root.bar ? root.bar.foreground : Color.foreground
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
        text: "Play a track to see lyrics"
        color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : ""
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
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
          text: root.status === "notfound" ? "Lyrics not found" : root.status === "offline" ? "Unable to fetch lyrics" : "Unable to fetch lyrics"
          color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.bodySmall
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
      }

      // ---------- synced ListView ----------
      ListView {
        id: syncedList
        anchors.fill: parent
        visible: root.hasMedia && root.mode === "synced" && root.lines.length > 0 && root.status === "ready"
        model: root.lines
        clip: true
        spacing: Style.space(4)
        boundsBehavior: Flickable.StopAtBounds

        // Keep current line centered
        preferredHighlightBegin: height / 2 - Style.space(14)
        preferredHighlightEnd: height / 2 + Style.space(14)
        highlightRangeMode: ListView.ApplyRange
        highlightMoveDuration: 280
        highlightMoveVelocity: 800
        highlightFollowsCurrentItem: true

        // Track currentIndex from service
        currentIndex: root.currentIndex >= 0 && root.currentIndex < count ? root.currentIndex : -1

        onMovementStarted: { root.userScrolling = true; userScrollCooldown.restart() }
        onFlickStarted: { root.userScrolling = true; userScrollCooldown.restart() }

        // Auto-center when currentIndex changes, unless user is scrolling
        Connections {
          target: root
          function onCurrentIndexChanged() {
            if (syncedList.visible && root.mode === "synced" && root.currentIndex >= 0) {
              if (root.userScrolling) return
              // Use timer to avoid fighting initial layout
              Qt.callLater(function() {
                if (!root.userScrolling && syncedList.visible) syncedList.positionViewAtIndex(root.currentIndex, ListView.Center)
              })
            }
          }
        }

        // When popup opens or model changes, center after layout
        onVisibleChanged: if (visible && root.currentIndex >= 0) Qt.callLater(function() { if (!root.userScrolling) syncedList.positionViewAtIndex(root.currentIndex, ListView.Center) })
        onCountChanged: if (visible && root.currentIndex >= 0) Qt.callLater(function() { if (!root.userScrolling) syncedList.positionViewAtIndex(root.currentIndex, ListView.Center) })

        delegate: Item {
          required property var modelData
          required property int index
          width: ListView.view.width
          implicitHeight: lineText.implicitHeight + Style.space(6)

          Text {
            id: lineText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            text: modelData.text || ""
            color: root.currentIndex === index ? Color.accent : (index < root.currentIndex ? (root.bar ? Qt.darker(root.bar.foreground, 1.25) : Color.foreground) : (root.bar ? root.bar.foreground : Color.foreground))
            font.family: root.bar ? root.bar.fontFamily : ""
            font.pixelSize: root.currentIndex === index ? Style.font.body : Style.font.bodySmall
            font.bold: root.currentIndex === index
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            opacity: root.currentIndex === -1 ? 1.0 : (root.currentIndex === index ? 1.0 : (Math.abs(index - root.currentIndex) === 1 ? 0.85 : 0.55))
            scale: root.currentIndex === index ? 1.02 : 1.0

            Behavior on color { ColorAnimation { duration: 180 } }
            Behavior on opacity { NumberAnimation { duration: 180 } }
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          }
        }
      }

      // ---------- plain ListView ----------
      ListView {
        id: plainList
        anchors.fill: parent
        visible: root.hasMedia && root.mode === "plain" && root.plainLines.length > 0 && root.status === "ready"
        model: root.plainLines
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds

        delegate: Text {
          required property var modelData
          required property int index
          width: ListView.view.width - Style.space(12)
          x: Style.space(6)
          text: modelData
          visible: text.trim() !== "" || index === 0 // keep empty lines as spacing
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : ""
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.WordWrap
          opacity: text.trim() === "" ? 0.0 : 1.0
          height: text.trim() === "" ? Style.space(8) : implicitHeight
        }
      }
    }
  }
}
