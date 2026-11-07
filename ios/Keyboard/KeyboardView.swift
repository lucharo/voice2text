import UIKit
import V2TKeyboardCore

/// What the key area reports to the controller. Character keys fire on release, as Apple's do, so a finger
/// can slide off a wrong key; delete fires on touch-down and repeats.
@MainActor protocol KeyboardViewDelegate: AnyObject {
  func keyboardView(_ v: KeyboardView, typed text: String, at point: CGPoint?)
  func keyboardView(_ v: KeyboardView, action: KeyAction)
  func keyboardViewDelete(_ v: KeyboardView, wholeWord: Bool)
  func keyboardView(_ v: KeyboardView, swiped trace: [CGPoint])
  func keyboardView(_ v: KeyboardView, moveCursor by: Int)
  func keyboardViewKeyDown(_ v: KeyboardView)
}

/// The key area: keys drawn as Core Animation layers (no view per key, no SwiftUI on the touch path), key
/// previews, long-press alternatives, swipe trails, held delete and the space-bar trackpad.
final class KeyboardView: UIView {
  weak var delegate: KeyboardViewDelegate?
  private(set) var layout: KeyboardLayout
  var shift: ShiftState = .off { didSet { if shift != oldValue { relabel() } } }
  /// The user tapped shift (rather than a sentence start): number keys show and type their second marks.
  var shiftManual = false { didSet { if shiftManual != oldValue { relabel() } } }
  var returnLabel = "return" { didSet { relabel() } }

  private var keyLayers: [String: CALayer] = [:]
  private var keyElements: [KeyElement] = []
  /// SF Symbol glyphs for special keys, kept apart from the text layers (a CATextLayer redraws over contents).
  private var symbolLayers: [String: CALayer] = [:]
  private var labelLayers: [String: CATextLayer] = [:]
  /// The small "v2t" in the space bar's bottom-right corner, where Apple's keyboard names its language.
  private(set) var brandLayer: CATextLayer?
  private let preview = PreviewLayer()
  private let trail = CAShapeLayer()

  /// What the view shows for one finger: its key's balloon or pressed look, timers, long-press alternatives
  /// and the trackpad. Whether the finger taps or swipes, and in what order taps type, is the arbiter's.
  @MainActor private final class Track {
    let key: Key
    var alternatives: [String] = []
    var chosen = 0
    var trackpad = false
    var lastTrackX: CGFloat = 0
    var timer: Timer?
    var repeats = 0
    init(key: Key) { self.key = key }
  }
  private var tracks: [ObjectIdentifier: Track] = [:]
  private var arbiter: TouchArbiter<ObjectIdentifier>
  /// The finger whose balloon is showing, so another finger lifting does not hide it.
  private var previewOwner: ObjectIdentifier?

  init(layout: KeyboardLayout) {
    self.layout = layout
    arbiter = TouchArbiter(unitWidth: layout.unitWidth)
    super.init(frame: .zero)
    isMultipleTouchEnabled = true
    trail.fillColor = nil
    trail.lineWidth = 6
    trail.lineCap = .round
    trail.lineJoin = .round
    trail.strokeColor = UIColor.systemBlue.withAlphaComponent(0.55).cgColor
    layer.addSublayer(trail)
    preview.zPosition = 10
    preview.isHidden = true
    layer.addSublayer(preview)
    rebuild()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func setLayout(_ l: KeyboardLayout) {
    layout = l
    arbiter.unitWidth = l.unitWidth
    if l.page != .letters { arbiter.stopSwipes() }  // a finger still down from the letters page taps
    rebuild()
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    rebuild()
  }

  // MARK: drawing

  private func isSpecial(_ k: Key) -> Bool {
    switch k.action {
    case .character, .space: false
    default: true
    }
  }

  /// A key's resting colour: the mic key is red, with a white waveform, so it stands out (#111).
  private func keyColor(_ k: Key) -> UIColor {
    if k.action == .mic { return Palette.record }
    return isSpecial(k) ? Palette.specialKey : Palette.key
  }

  private func rebuild() {
    keyLayers.values.forEach { $0.removeFromSuperlayer() }
    keyLayers = [:]
    labelLayers = [:]
    symbolLayers = [:]
    brandLayer = nil
    let scale = window?.screen.scale ?? UIScreen.main.scale
    for k in layout.keys {
      let l = CALayer()
      l.frame = k.frame
      l.cornerRadius = 8.5
      l.backgroundColor = keyColor(k).resolvedColor(with: traitCollection).cgColor
      l.shadowColor = UIColor.black.cgColor
      l.shadowOpacity = 0.12
      l.shadowRadius = 0
      l.shadowOffset = CGSize(width: 0, height: 1)
      let t = CATextLayer()
      t.contentsScale = scale
      t.alignmentMode = .center
      t.foregroundColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
      l.addSublayer(t)
      let sym = CALayer()
      sym.contentsGravity = .center
      l.addSublayer(sym)
      symbolLayers[k.id] = sym
      if k.action == .space { l.addSublayer(makeBrand(in: k.frame.size, scale: scale)) }
      layer.insertSublayer(l, below: trail)
      keyLayers[k.id] = l
      labelLayers[k.id] = t
    }
    keyElements = layout.keys.map { k in
      let e = KeyElement(accessibilityContainer: self)
      e.key = k
      e.accessibilityIdentifier = "key.\(k.id)"
      e.accessibilityFrameInContainerSpace = k.frame
      e.accessibilityTraits = .keyboardKey
      e.activate = { [weak self] in self?.activate(k) }
      return e
    }
    relabel()
  }

  /// Small and secondary, like the language name Apple's space bar shows; not an accessibility element (the
  /// key is still read as "space").
  private func makeBrand(in size: CGSize, scale: CGFloat) -> CATextLayer {
    let b = CATextLayer()
    b.contentsScale = scale
    b.string = "v2t"
    b.font = UIFont.systemFont(ofSize: 11, weight: .medium)
    b.fontSize = 11
    b.alignmentMode = .right
    b.foregroundColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
    b.frame = CGRect(x: 0, y: size.height - 18, width: size.width - 9, height: 14)
    brandLayer = b
    return b
  }

  override var accessibilityElements: [Any]? { get { keyElements } set {} }

  /// VoiceOver's double tap (and UI tests' accessibility activation) on a key.
  private func activate(_ k: Key) {
    switch k.action {
    case .character: delegate?.keyboardView(self, typed: k.output(shift: shift, manual: shiftManual)!, at: k.center)
    case .delete: delegate?.keyboardViewDelete(self, wholeWord: false)
    default: delegate?.keyboardView(self, action: k.action)
    }
  }

  private func relabel() {
    for k in layout.keys {
      guard let t = labelLayers[k.id] else { continue }
      let (text, size) = label(for: k)
      if let symbol = symbol(for: k), let sym = symbolLayers[k.id] {
        t.string = nil
        let img = k.action == .mic ? V2TMark.glyph(height: 20, color: .white) : Self.render(symbol, size: size, color: UIColor.label.resolvedColor(with: traitCollection))
        sym.contents = img.cgImage
        sym.contentsScale = img.scale
        sym.frame = CGRect(origin: .zero, size: k.frame.size)
        if let e = keyElements.first(where: { $0.key?.id == k.id }) { e.accessibilityLabel = spoken(k) }
        if k.action == .shift {
          keyLayers[k.id]?.backgroundColor = (shift == .off ? Palette.specialKey : Palette.key).resolvedColor(with: traitCollection).cgColor
        }
        continue
      }
      symbolLayers[k.id]?.contents = nil
      t.string = text
      t.font = UIFont.systemFont(ofSize: size, weight: k.isCharacter ? .regular : .regular)
      t.fontSize = size
      let h = size * 1.25
      t.frame = CGRect(x: 0, y: (k.frame.height - h) / 2 - (k.isCharacter && layout.page == .letters && shift == .off ? 2 : 0), width: k.frame.width, height: h)
      if let e = keyElements.first(where: { $0.key?.id == k.id }) { e.accessibilityLabel = spoken(k) }
      if k.action == .shift {
        keyLayers[k.id]?.backgroundColor = (shift == .off ? Palette.specialKey : Palette.key).resolvedColor(with: traitCollection).cgColor
      }
    }
  }

  private func spoken(_ k: Key) -> String {
    switch k.action {
    case .character: k.output(shift: shift, manual: shiftManual)!
    case .shift: shift == .locked ? "caps lock" : "shift"
    case .delete: "delete"
    case .space: "space"
    case .returnKey: returnLabel
    case .mic: "dictate"
    case .emoji: "emoji"
    case .nextKeyboard: "next keyboard"
    case .dismiss: "hide keyboard"
    case .tab: "tab"
    case .capsLock: shift == .locked ? "caps lock on" : "caps lock"
    case .page(let p): p == .letters ? "letters" : (p == .numbers ? "numbers" : "symbols")
    }
  }

  /// Special keys draw SF Symbols, as Apple's do.
  private func symbol(for k: Key) -> String? {
    switch k.action {
    case .shift: shift == .locked ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
    case .delete: "delete.left"
    case .returnKey where returnLabel == "return" || returnLabel == "intro": "return.left"
    case .mic: "mic"
    case .emoji: "face.smiling"
    case .nextKeyboard: "globe"
    case .dismiss: "keyboard.chevron.compact.down"
    case .tab: "arrow.right.to.line"
    case .capsLock: shift == .locked ? "capslock.fill" : "capslock"
    default: nil
    }
  }

  static func render(_ name: String, size: CGFloat, color: UIColor) -> UIImage {
    let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
    let symbol = (UIImage(systemName: name, withConfiguration: cfg) ?? UIImage()).withTintColor(color, renderingMode: .alwaysOriginal)
    // rasterised: a symbol image has no CGImage of its own for a layer to show
    return UIGraphicsImageRenderer(size: symbol.size).image { _ in symbol.draw(at: .zero) }
  }

  private func label(for k: Key) -> (String, CGFloat) {
    switch k.action {
    case .character: return (k.output(shift: shift, manual: shiftManual)!, layout.form.isPad ? (layout.metrics.keyHeight > 60 ? 28 : 24) : (layout.page == .letters ? 25 : 22))
    case .shift: return (shift == .locked ? "⇪" : "⇧", 22)
    case .delete: return ("⌫", 22)
    case .space: return ("", 16)  // Apple's space bar carries no label
    case .returnKey: return (returnLabel, layout.form.isPad ? 20 : 16)
    case .mic: return ("🎙", 19)
    case .emoji: return ("☺", 19)
    case .nextKeyboard: return ("🌐", 19)
    case .dismiss: return ("⌨", 19)
    case .tab: return ("⇥", 20)
    case .capsLock: return ("⇪", 20)
    case .page: return (k.label, layout.form.isPad ? 18 : 16)
    }
  }

  private func setPressed(_ k: Key, _ on: Bool) {
    guard let l = keyLayers[k.id] else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let pressed = k.action == .mic ? Palette.recordPressed : Palette.pressed
    l.backgroundColor = (on ? pressed : keyColor(k)).resolvedColor(with: traitCollection).cgColor
    CATransaction.commit()
  }

  // MARK: touches

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
      let p = touch.location(in: self)
      guard let key = layout.key(at: p) else { continue }
      let id = ObjectIdentifier(touch)
      let track = Track(key: key)
      tracks[id] = track
      arbiter.began(id, key: key, at: p, time: touch.timestamp, canSwipe: canSwipe(key))
      delegate?.keyboardViewKeyDown(self)
      switch key.action {
      case .character:
        press(track, id)
      case .delete:
        setPressed(key, true)
        delegate?.keyboardViewDelete(self, wholeWord: false)
        track.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self, weak track] _ in
          MainActor.assumeIsolated { if let self, let track { self.startDeleteRepeat(track) } }
        }
      case .space:
        setPressed(key, true)
        track.timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak track] _ in
          MainActor.assumeIsolated {
            guard let self, let track, self.arbiter.hold(id, types: false) else { return }
            track.trackpad = true
            track.lastTrackX = self.arbiter.points(of: id).last?.x ?? p.x
            self.setTrackpad(true)
          }
        }
      default:
        setPressed(key, true)
      }
    }
  }

  private func canSwipe(_ key: Key) -> Bool { key.startsSwipe && layout.page == .letters }

  /// A character key's balloon (the iPhone) or darkened key (Apple's iPad keyboard), and its long-press timer.
  private func press(_ track: Track, _ id: ObjectIdentifier) {
    let key = track.key
    if layout.form.isPad { setPressed(key, true) } else { showPreview(key, text: label(for: key).0, for: id) }
    guard key.longPress(shift: shift, manual: shiftManual).count > 1 else { return }
    track.timer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self, weak track] _ in
      MainActor.assumeIsolated {
        guard let self, let track, self.arbiter.hold(id, types: true) else { return }
        self.showAlternatives(track, for: id)
      }
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches {
      let id = ObjectIdentifier(touch)
      guard let track = tracks[id] else { continue }
      let p = touch.location(in: self)
      let samples = (event?.coalescedTouches(for: touch) ?? [touch]).map { ($0.location(in: self), $0.timestamp) }
      apply(arbiter.moved(id, samples))
      if track.trackpad {
        let step: CGFloat = 9
        let dx = p.x - track.lastTrackX
        if abs(dx) >= step {
          let n = Int(dx / step)
          delegate?.keyboardView(self, moveCursor: n)
          track.lastTrackX += CGFloat(n) * step
        }
        continue
      }
      if !track.alternatives.isEmpty {
        updateAlternativeChoice(track, x: p.x, for: id)
        continue
      }
      if arbiter.mode(of: id) == .swiping { drawTrail(arbiter.points(of: id)) }
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches { finish(touch, cancelled: false) }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches { finish(touch, cancelled: true) }
  }

  private func finish(_ touch: UITouch, cancelled: Bool) {
    let id = ObjectIdentifier(touch)
    guard let track = tracks.removeValue(forKey: id) else { return }
    release(track, id)
    if cancelled {
      if arbiter.mode(of: id) == .swiping { clearTrail() }
      arbiter.cancelled(id)
      if track.trackpad { setTrackpad(false) }
      return
    }
    // older fingers still down type first (rollover), then this one
    apply(arbiter.ended(id, at: touch.location(in: self), time: touch.timestamp))
    if track.trackpad { setTrackpad(false); return }
    if !track.alternatives.isEmpty {
      // older fingers typed just above may have used up an automatic capital. A letter key's menu is the same
      // letters in either case ("ß" shows as "SS"), so re-read it at today's shift; other keys' shifted menus
      // hold other marks, so the one chosen stays
      let now = track.key.longPress(shift: shift, manual: shiftManual)
      let pick = track.key.startsSwipe && now.count == track.alternatives.count ? now[track.chosen] : track.alternatives[track.chosen]
      delegate?.keyboardView(self, typed: pick, at: nil)
    }
  }

  /// Takes down a finger's balloon, pressed look and timer.
  private func release(_ track: Track, _ id: ObjectIdentifier) {
    track.timer?.invalidate()
    track.timer = nil
    if previewOwner == id { hidePreview() }
    setPressed(track.key, false)
  }

  private func apply(_ events: [TouchArbiter<ObjectIdentifier>.Event]) {
    for e in events {
      switch e {
      case .tapped(let key, let at, let id):
        // a finger typed by rollover is still down: it shows nothing more
        if let track = tracks[id] { release(track, id) }
        switch key.action {
        case .character: delegate?.keyboardView(self, typed: key.output(shift: shift, manual: shiftManual)!, at: at)
        case .delete: break
        default: delegate?.keyboardView(self, action: key.action)
        }
      case .swipeStarted(let id):
        if let track = tracks[id] { track.timer?.invalidate(); track.timer = nil }
        if previewOwner == id { hidePreview() }
      case .swiped(let trace, _):
        clearTrail()
        delegate?.keyboardView(self, swiped: trace)
      }
    }
  }

  // MARK: held delete

  private func startDeleteRepeat(_ track: Track) {
    track.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak track] _ in
      MainActor.assumeIsolated {
        guard let self, let track else { return }  // finish() invalidates the timer when the finger lifts
        track.repeats += 1
        // after a dozen characters, Apple's delete speeds up to whole words
        if track.repeats > 12 {
          if track.repeats % 2 == 0 { self.delegate?.keyboardViewDelete(self, wholeWord: true) }
        } else {
          self.delegate?.keyboardViewDelete(self, wholeWord: false)
        }
      }
    }
  }

  // MARK: previews and alternatives

  private func showPreview(_ key: Key, text: String, for id: ObjectIdentifier) {
    previewOwner = id
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    preview.show(text: text, over: key.frame, in: bounds, traits: traitCollection)
    CATransaction.commit()
  }

  private func hidePreview() {
    previewOwner = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    preview.isHidden = true
    CATransaction.commit()
  }

  private func showAlternatives(_ track: Track, for id: ObjectIdentifier) {
    guard case .character = track.key.action else { return }
    previewOwner = id
    let alts = track.key.longPress(shift: shift, manual: shiftManual)
    track.alternatives = alts
    track.chosen = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    preview.showAlternatives(alts, chosen: 0, over: track.key.frame, in: bounds, traits: traitCollection)
    CATransaction.commit()
  }

  private func updateAlternativeChoice(_ track: Track, x: CGFloat, for id: ObjectIdentifier) {
    previewOwner = id  // another finger's balloon may have taken the overlay over meanwhile
    let i = preview.alternativeIndex(at: x, count: track.alternatives.count)
    guard i != track.chosen else { return }
    track.chosen = i
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    preview.showAlternatives(track.alternatives, chosen: i, over: track.key.frame, in: bounds, traits: traitCollection)
    CATransaction.commit()
  }

  // MARK: trails and trackpad

  private func drawTrail(_ pts: [CGPoint]) {
    let path = UIBezierPath()
    path.move(to: pts[0])
    for p in pts.dropFirst() { path.addLine(to: p) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trail.path = path.cgPath
    CATransaction.commit()
  }

  private func clearTrail() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trail.path = nil
    CATransaction.commit()
  }

  private func setTrackpad(_ on: Bool) {
    for t in labelLayers.values { t.opacity = on ? 0 : 1 }
    for t in symbolLayers.values { t.opacity = on ? 0 : 1 }
    brandLayer?.opacity = on ? 0 : 1
  }
}

enum Palette {
  // Apple's iOS 27 keyboard, sampled from Simulator screenshots: keys white in light mode and rgb(68-70) in dark
  // mode, pressed keys rgb(197, 198, 204) in light mode.
  static let key = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : .white }
  static let specialKey = key
  static let pressed = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : UIColor(red: 197 / 255, green: 198 / 255, blue: 204 / 255, alpha: 1) }
  /// The mic key's red, Apple's record red, and a darker red while it is pressed.
  static let record = UIColor.systemRed
  static let recordPressed = UIColor { UIColor.systemRed.resolvedColor(with: $0).withAlphaComponent(0.7) }
  /// What the system's keyboard glass looks like behind the keys over a plain page (sampled: rgb(224, 226, 232)
  /// light, rgb(32-34) dark), for off-screen renders only. On screen the keyboard draws no background of its
  /// own, so the glass shows through as it does behind Apple's keys.
  static let background = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(red: 224 / 255, green: 226 / 255, blue: 232 / 255, alpha: 1) }
}

/// The balloon above a pressed key, and the row of long-press alternatives.
final class PreviewLayer: CALayer {
  private let text = CATextLayer()
  private var cells: [CATextLayer] = []
  private var cellWidth: CGFloat = 0
  private var originX: CGFloat = 0

  override init() {
    super.init()
    cornerRadius = 10
    shadowColor = UIColor.black.cgColor
    shadowOpacity = 0.25
    shadowRadius = 3
    shadowOffset = CGSize(width: 0, height: 1)
    text.alignmentMode = .center
    addSublayer(text)
  }
  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func show(text s: String, over key: CGRect, in bounds: CGRect, traits: UITraitCollection) {
    cells.forEach { $0.removeFromSuperlayer() }
    cells = []
    let w = key.width + 18, h: CGFloat = 54
    var x = key.midX - w / 2
    x = max(bounds.minX + 1, min(bounds.maxX - w - 1, x))
    // the balloon may cover the suggestion bar but never leaves the keyboard's own view
    frame = CGRect(x: x, y: max(bounds.minY - 44, key.minY - h - 4), width: w, height: h)
    backgroundColor = Palette.key.resolvedColor(with: traits).cgColor
    text.contentsScale = UIScreen.main.scale
    text.string = s
    text.fontSize = 34
    text.foregroundColor = UIColor.label.resolvedColor(with: traits).cgColor
    text.frame = CGRect(x: 0, y: 6, width: w, height: 42)
    text.isHidden = false
    isHidden = false
  }

  func showAlternatives(_ alts: [String], chosen: Int, over key: CGRect, in bounds: CGRect, traits: UITraitCollection) {
    text.isHidden = true
    cells.forEach { $0.removeFromSuperlayer() }
    cells = []
    cellWidth = max(32, key.width)
    let w = cellWidth * CGFloat(alts.count) + 8, h: CGFloat = 50
    var x = key.minX - 4
    x = max(bounds.minX + 1, min(bounds.maxX - w - 1, x))
    originX = x + 4
    frame = CGRect(x: x, y: max(bounds.minY - 44, key.minY - h - 4), width: w, height: h)
    backgroundColor = Palette.key.resolvedColor(with: traits).cgColor
    for (i, a) in alts.enumerated() {
      let c = CATextLayer()
      c.contentsScale = UIScreen.main.scale
      c.alignmentMode = .center
      c.string = a
      c.fontSize = 26
      c.cornerRadius = 7
      c.foregroundColor = (i == chosen ? UIColor.white : UIColor.label.resolvedColor(with: traits)).cgColor
      c.backgroundColor = i == chosen ? UIColor.systemBlue.cgColor : nil
      c.frame = CGRect(x: 4 + CGFloat(i) * cellWidth, y: 6, width: cellWidth, height: 38)
      addSublayer(c)
      cells.append(c)
    }
    isHidden = false
  }

  func alternativeIndex(at x: CGFloat, count: Int) -> Int {
    max(0, min(count - 1, Int((x - originX) / max(cellWidth, 1))))
  }
}

/// One key as an accessibility element, so VoiceOver can read and type it like Apple's keys.
final class KeyElement: UIAccessibilityElement {
  var key: Key?
  var activate: (() -> Void)?
  override func accessibilityActivate() -> Bool {
    activate?()
    return true
  }
}
