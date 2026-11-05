import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A cloud drawn from primitives, so it stays crisp in the bar's tiny slot and
// follows the theme colour live. Tailscale and Dropbox draw their marks the
// same way rather than rendering an SVG.
Item {
  id: root

  property real iconSize: Style.font.icon
  readonly property real aspectRatio: 1.4
  property color color: Commons.Color.foreground
  property color badgeColor: Commons.Color.urgent
  property bool crossed: false     // paused
  property bool warning: false     // degraded, offline, or an error in the log
  property bool pulsing: false     // syncing

  width: iconSize * aspectRatio
  height: iconSize
  implicitWidth: width
  implicitHeight: height

  // Group opacity, so overlapping lobes read as one silhouette while pulsing.
  Item {
    id: cloud
    anchors.fill: parent
    layer.enabled: true
    opacity: root.pulsing ? 0.45 : 1.0
    Behavior on opacity {
      NumberAnimation { duration: Style.duration(700); easing.type: Easing.OutCubic }
    }

    SequentialAnimation {
      running: root.pulsing && Style.duration(1) > 0
      loops: Animation.Infinite
      onRunningChanged: if (!running) cloud.opacity = root.pulsing ? 0.45 : 1.0
      NumberAnimation { target: cloud; property: "opacity"; to: 1.0; duration: Style.duration(700); easing.type: Easing.OutCubic }
      NumberAnimation { target: cloud; property: "opacity"; to: 0.45; duration: Style.duration(700); easing.type: Easing.OutCubic }
    }

    Rectangle {
      // Main lobe
      x: root.width * 0.27; y: root.height * 0.08
      width: root.width * 0.46; height: width
      radius: width / 2
      color: root.color
    }
    Rectangle {
      // Right lobe
      x: root.width * 0.56; y: root.height * 0.30
      width: root.width * 0.36; height: width
      radius: width / 2
      color: root.color
    }
    Rectangle {
      // Left lobe
      x: root.width * 0.04; y: root.height * 0.40
      width: root.width * 0.32; height: width
      radius: width / 2
      color: root.color
    }
    Rectangle {
      // Base
      x: root.width * 0.06; y: root.height * 0.56
      width: root.width * 0.88; height: root.height * 0.38
      radius: height / 2
      color: root.color
    }
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 0.95
    height: Math.max(2, parent.height * 0.14)
    radius: height / 2
    color: root.color
    rotation: -40
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.height * 0.5)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Commons.Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      textFormat: Text.PlainText
      color: Commons.Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.8)
      font.bold: true
    }
  }
}
