import Foundation
import Testing
import UIKit
import V2TKeyboardCore

/// Renders the real key area (KeyboardView, the keyboard extension's drawing code) with the iPad layouts,
/// off-screen at iPad widths, and writes each as a PNG to the folder in V2T_SHOTS for visual review. The
/// installed Simulator runtime offers no iPad device, so this is how the iPad keyboard gets looked at.
@MainActor struct PadKeyboardRenderTests {
  static func render(_ layout: KeyboardLayout, shift: ShiftState = .off, scale: CGFloat = 2) -> UIImage {
    let v = KeyboardView(layout: layout)
    v.shift = shift
    v.frame = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
    v.backgroundColor = Palette.background
    v.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    return UIGraphicsImageRenderer(size: v.bounds.size, format: format).image { ctx in v.layer.render(in: ctx.cgContext) }
  }

  @Test(arguments: [
    ("50-ipad-11in-portrait-en", CGFloat(834), false, KeyboardLanguage.english, KeyboardPage.letters, KeyboardForm.pad, ShiftState.off),
    ("51-ipad-11in-landscape-en", 1194, true, .english, .letters, .pad, .off),
    ("52-ipad-11in-portrait-es", 834, false, .spanish, .letters, .pad, .off),
    ("53-ipad-11in-portrait-numbers", 834, false, .english, .numbers, .pad, .off),
    ("55-ipad-mini-portrait-en", 744, false, .english, .letters, .pad, .off),
    ("60-ipad-13in-full-portrait-en", 1032, false, .english, .letters, .padFull, .off),
    ("61-ipad-13in-full-landscape-en", 1376, true, .english, .letters, .padFull, .off),
    ("62-ipad-13in-full-portrait-es", 1032, false, .spanish, .letters, .padFull, .off),
    ("63-ipad-13in-full-portrait-shift", 1032, false, .english, .letters, .padFull, .on),
    ("64-ipad-13in-full-portrait-numbers", 1032, false, .english, .numbers, .padFull, .off),
  ])
  func rendersTheIPadKeyboard(name: String, width: CGFloat, landscape: Bool, language: KeyboardLanguage, page: KeyboardPage,
                              form: KeyboardForm, shift: ShiftState) throws {
    let layout = KeyboardLayout(width: width, page: page, language: language, form: form, landscape: landscape)
    let image = Self.render(layout, shift: shift)
    #expect(image.size == CGSize(width: width, height: layout.height))
    let png = try #require(image.pngData())
    // a drawn keyboard: far larger than a blank image of the same size compresses to
    #expect(png.count > 20_000, "\(name): \(png.count) bytes")
    if let dir = ProcessInfo.processInfo.environment["V2T_SHOTS"] {
      try png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }
  }
}
