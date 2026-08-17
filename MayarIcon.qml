import QtQuick
import QtQuick.Shapes
import qs.Commons

// The Mayar brand mark, redrawn as tintable Shape paths the same way the
// first-party Dropbox and Tailscale icons are. The mark is two colours in
// Mayar's own branding (#0c52ef blue, #ed1e79 magenta), but a bar icon that
// keeps its brand colours is the odd one out in a row of glyphs that all take
// the bar foreground, so both paths are filled with a single themed colour and
// the silhouette carries the identity instead.
//
// The path data is lifted verbatim from the official SVG, flattened through
// rsvg so there is no clipPath or ICC profile left to interpret. Coordinates
// are therefore in the original 1365.33 viewBox space, and the mark's real ink
// bounds inside it are (33,200) to (1312,1166) — the artboard is mostly
// padding, so the wrapper below crops to the ink and scales that, letting the
// mark fill the icon box edge to edge like the glyphs beside it.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  // Dimmed rather than recoloured when something needs attention. This is a
  // logo, not a status glyph — a warning tint would read as part of the brand,
  // while a faded mark reads as inactive, which is the state being signalled.
  property bool attention: false

  readonly property real inkWidth: 1279
  readonly property real inkHeight: 966

  // `iconSize` is a nominal size, matching how the neighbouring icons are set:
  // they are font glyphs, so the size names an em box and the ink inside it is
  // shorter. This mark is pure ink with no such box, so drawing it at the full
  // iconSize made it visibly taller than everything else on the bar. Measured
  // off the rendered bar, the stock glyphs come out 17px of ink where this was
  // 22px, hence the ratio — it makes `iconSize` mean the same thing here as it
  // does for a glyph, rather than making every call site pass a fudged number.
  readonly property real capRatio: 17 / 22

  height: iconSize * capRatio
  width: height * (inkWidth / inkHeight)
  implicitWidth: width
  implicitHeight: height

  // Sized in viewBox units and scaled down as a whole, rather than transformed
  // on the Shape itself: a `transform:` list of Translate + Scale composes in
  // an order that is easy to get backwards, and getting it backwards moves the
  // mark cleanly outside the icon box, where it renders as nothing at all.
  Item {
    width: root.inkWidth
    height: root.inkHeight
    scale: root.height / root.inkHeight
    transformOrigin: Item.TopLeft
    opacity: root.attention ? 0.45 : 1.0

    Behavior on opacity {
      NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
    }

    Shape {
      // Shifts the artboard so the mark's ink starts at the icon's edge.
      x: -33
      y: -200
      width: 1366
      height: 1366
      antialiasing: true
      // CurveRenderer, not the layer-and-multisample trick the first-party
      // icons use. Those draw at roughly their final size; this one is drawn
      // at artboard scale and shrunk ~60x, and a layer would rasterise the
      // glyph at 1366px only to minify it with bilinear filtering, which is
      // what put stair-steps on the M's diagonals. CurveRenderer evaluates the
      // curves in the fragment shader after the transform, so it is scale-free.
      preferredRendererType: Shape.CurveRenderer

      // The M itself.
      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.WindingFill
        PathSvg {
          path: "M 960.046875 1164.644531 L 1010.457031 832.648438 C 1025.703125 733.035156 1046.445312 608.367188 1075.898438 455.523438 L 1071.6875 455.523438 C 1017.671875 592.617188 960.046875 726.144531 915.597656 820.613281 L 768.039062 1144.652344 L 588.3125 1144.652344 L 572.996094 821.363281 C 568.566406 731.320312 562.105469 595.621094 560.390625 455.523438 L 557.535156 455.523438 C 528.082031 597.867188 500.875 733.785156 477.8125 832.648438 L 400.480469 1164.644531 L 190.550781 1164.644531 L 431.609375 202.109375 L 728.621094 202.109375 L 739.367188 526.285156 C 742.296875 612.753906 750.398438 729.324219 749.042969 834.753906 L 754.148438 834.753906 C 788.605469 729.324219 839.085938 608.933594 875.96875 524.785156 L 1012.671875 202.109375 L 1311.324219 202.109375 L 1180.328125 1164.644531 Z"
        }
      }

      // The swoosh across the M's top-left shoulder.
      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.WindingFill
        PathSvg {
          path: "M 728.554688 200.691406 L 33.3125 200.691406 C 33.3125 200.691406 616.90625 370.242188 742.054688 588.242188 Z"
        }
      }
    }
  }
}
