import Testing
import UIKit
import V2TKeyboardCore

/// The mic key's styles and the space bar's "v2t", checked on the real key area (KeyboardView) rendered
/// off-screen at the iPhone width.
@MainActor struct KeyboardLookTests {
  let layout = KeyboardLayout(width: 402)
  var mic: Key { layout.keys.first { $0.action == .mic }! }
  var space: Key { layout.keys.first { $0.action == .space }! }

  /// Red pixels (Apple's record red, light or dark) inside `rect` of the rendered keys.
  func redPixels(style: MicKeyStyle, warm: Bool, in rect: CGRect) -> Int {
    let v = KeyboardView(layout: layout)
    v.micStyle = style
    v.micWarm = warm
    v.frame = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
    v.backgroundColor = Palette.background
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: v.bounds.size, format: format).image { v.layer.render(in: $0.cgContext) }
    let cg = image.cgImage!
    let data = CFDataGetBytePtr(cg.dataProvider!.data)!
    var n = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) {
        let i = y * cg.bytesPerRow + x * cg.bitsPerPixel / 8
        // BGRA in the renderer's format
        let b = Int(data[i]), g = Int(data[i + 1]), r = Int(data[i + 2])
        if r > 200, g < 100, b < 100 { n += 1 }
      }
    }
    return n
  }

  @Test func eachMicStyleColoursTheKeyOrItsWaveform() {
    let glyph = mic.frame.insetBy(dx: mic.frame.width * 0.3, dy: mic.frame.height * 0.3)  // the waveform only
    let edge = CGRect(x: mic.frame.minX + 3, y: mic.frame.midY, width: 4, height: 1)  // key fill, left of the waveform
    var seen: [String: [Bool]] = [:]
    for style in MicKeyStyle.allCases {
      for warm in [false, true] {
        seen["\(style.rawValue) warm=\(warm)"] = [redPixels(style: style, warm: warm, in: edge) > 0,
                                                  redPixels(style: style, warm: warm, in: glyph) > 0]
      }
    }
    // [red key fill, red waveform]; B's waveform is white on red, so its centre still has red between bars
    #expect(seen == [
      "A warm=false": [false, true], "A warm=true": [false, true],
      "B warm=false": [true, true], "B warm=true": [true, true],
      "C warm=false": [false, false], "C warm=true": [false, true],
    ])
  }

  @Test func noOtherKeyTurnsRed() {
    let others = CGRect(x: 0, y: 0, width: layout.width, height: mic.frame.minY - 1)  // every row above the mic's
    #expect(redPixels(style: .redKey, warm: true, in: others) == 0)
  }

  @Test func theSpaceBarCarriesV2tInItsBottomRightCornerAndIsStillReadAsSpace() throws {
    let v = KeyboardView(layout: layout)
    let brand = try #require(v.brandLayer)
    #expect(brand.string as? String == "v2t")
    let key = try #require(brand.superlayer).frame
    #expect(abs(key.minX - space.frame.minX) < 0.01 && abs(key.width - space.frame.width) < 0.01 && key.minY == space.frame.minY)
    #expect(brand.frame.maxX > space.frame.width - 12 && brand.frame.maxX <= space.frame.width)
    #expect(brand.frame.maxY > space.frame.height - 6 && brand.frame.maxY <= space.frame.height)
    let element = v.accessibilityElements?.compactMap { $0 as? KeyElement }.first { $0.key?.action == .space }
    #expect(element?.accessibilityLabel == "space")
  }
}
