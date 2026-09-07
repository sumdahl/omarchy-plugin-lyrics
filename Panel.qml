import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// sumiran.lyrics — bar widget with popup.
// Isolated from existing media plugins; only integration is via omarchy.media service.
Panel {
  id: root
  moduleName: "sumiran.lyrics"
  ipcTarget: "sumiran.lyrics"

  readonly property var lyricsService: bar && bar.shell ? bar.shell.firstPartyServiceFor("sumiran.lyrics") : null
  readonly property var mediaService: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.media") : null
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null

  readonly property bool hasMedia: !!(activePlayer && (activePlayer.trackTitle || activePlayer.trackArtist))
  readonly property string title: activePlayer ? String(activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? String(activePlayer.trackArtist || "") : ""

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Lyrics glyph — distinct from media panel
    text: "󰎆"
    active: root.opened
    opacity: root.hasMedia ? 1.0 : 0.45
    tooltipText: root.hasMedia ? (root.artist !== "" ? root.title + " — " + root.artist : root.title) : "Lyrics — no track"

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton && root.mediaService && root.activePlayer) {
        root.mediaService.runAction("playPause", false, root.mediaService.playerKey(root.activePlayer))
      } else {
        root.toggle()
      }
    }
    onWheelMoved: function(delta) {
      if (!root.mediaService || !root.activePlayer) return
      if (delta > 0) root.mediaService.runAction("previous", false, root.mediaService.playerKey(root.activePlayer))
      else if (delta < 0) root.mediaService.runAction("next", false, root.mediaService.playerKey(root.activePlayer))
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(contentItem.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          if (!root.mediaService || !root.activePlayer) return
          if (dx > 0) root.mediaService.runAction("next", false, root.mediaService.playerKey(root.activePlayer))
          else root.mediaService.runAction("previous", false, root.mediaService.playerKey(root.activePlayer))
          return
        }
      }
      onActivateRequested: {
        if (root.mediaService && root.activePlayer) root.mediaService.runAction("playPause", false, root.mediaService.playerKey(root.activePlayer))
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      LyricsPanel {
        id: contentItem
        width: parent.width
        bar: root.bar
        lyricsService: root.lyricsService
      }
    }
  }
}
