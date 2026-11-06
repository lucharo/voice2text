import Testing
import UIKit
import V2TKeyboardCore

/// The red mic key and the space bar's "v2t", checked on the real key area (KeyboardView) rendered
/// off-screen at the iPhone width.
@MainActor struct KeyboardLookTests {
  let layout = KeyboardLayout(width: 402)
  var mic: Key { layout.keys.first { $0.action == .mic }! }
  var space: Key { layout.keys.first { $0.action == .space }! }

  /// Counts the pixels inside `rect` of the rendered keys that are Apple's record red and that are white.
  func colours(in rect: CGRect, style: UIUserInterfaceStyle) -> (red: Int, white: Int) {
    let v = KeyboardView(layout: layout)
    v.overrideUserInterfaceStyle = style
    v.frame = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
    v.backgroundColor = Palette.background
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3  // the waveform's bars are about a point wide: at 1x they only blend into the red
    let image = UIGraphicsImageRenderer(size: v.bounds.size, format: format).image { v.layer.render(in: $0.cgContext) }
    let cg = image.cgImage!
    let data = [UInt8](cg.dataProvider!.data! as Data)  // a copy, so no pointer outlives the CFData
    var red = 0, white = 0
    for y in Int(rect.minY * 3)..<Int(rect.maxY * 3) {
      for x in Int(rect.minX * 3)..<Int(rect.maxX * 3) {
        let i = y * cg.bytesPerRow + x * cg.bitsPerPixel / 8
        // BGRA in the renderer's format
        let b = Int(data[i]), g = Int(data[i + 1]), r = Int(data[i + 2])
        if r > 200, g < 100, b < 100 { red += 1 }
        if r > 240, g > 240, b > 240 { white += 1 }
      }
    }
    return (red, white)
  }

  @Test(arguments: [UIUserInterfaceStyle.light, .dark])
  func theMicKeyIsRedWithAWhiteWaveform(style: UIUserInterfaceStyle) {
    let fill = CGRect(x: mic.frame.minX + 3, y: mic.frame.midY, width: 4, height: 1)  // left of the waveform
    let glyph = mic.frame.insetBy(dx: mic.frame.width * 0.3, dy: mic.frame.height * 0.3)
    #expect(colours(in: fill, style: style).red == 4 * 3 * 3)
    #expect(colours(in: glyph, style: style).white > 100)
  }

  @Test func noOtherKeyTurnsRed() {
    let others = CGRect(x: 0, y: 0, width: layout.width, height: mic.frame.minY - 1)  // every row above the mic's
    #expect(colours(in: others, style: .light).red == 0)
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
