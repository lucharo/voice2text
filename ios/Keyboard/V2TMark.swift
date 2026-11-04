import UIKit

/// The v2t waveform as a keyboard glyph: the 16 bars of assets/logo/logo.svg (the waveform of the spoken
/// words "voice to text"), drawn in one colour like the keyboard's other key symbols, so the dictate keys read
/// as v2t's own without a badge.
enum V2TMark {
  /// (x, y, height) of each bar in the logo's 72x72 box. The bars span x 12...60 and y 16...56.
  static let bars: [(CGFloat, CGFloat, CGFloat)] = [
    (12.00, 26.98, 18.03), (15.10, 23.91, 24.19), (18.20, 16.00, 40.00), (21.30, 23.73, 24.54),
    (24.40, 31.29, 9.41), (27.50, 33.40, 5.20), (30.60, 25.27, 21.46), (33.70, 33.62, 4.75),
    (36.80, 31.32, 9.36), (39.90, 26.56, 18.88), (43.00, 29.78, 12.45), (46.10, 33.59, 4.82),
    (49.20, 33.68, 4.64), (52.30, 33.00, 6.00), (55.40, 33.78, 4.45), (58.50, 34.62, 2.76),
  ]

  /// The waveform `height` points tall in `color`; a template image when `color` is nil, so a button's tint
  /// colours it. Bars are thickened from the logo's 1.5 of 3.1 units to the stroke weight of the keyboard's
  /// regular-weight symbols.
  static func glyph(height: CGFloat, color: UIColor? = nil) -> UIImage {
    let s = height / 40, width = 48 * s + 2.2 * s
    let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
      (color ?? .black).setFill()
      for (x, y, h) in bars {
        let w = 2.2 * s
        UIBezierPath(roundedRect: CGRect(x: (x - 12) * s, y: (y - 16) * s, width: w, height: max(h * s, w)), cornerRadius: w / 2).fill()
      }
    }
    return color == nil ? image.withRenderingMode(.alwaysTemplate) : image
  }
}
