import CoreGraphics
import Foundation

/// Decides, for every finger on the keys, whether it is a tap or a swipe, and keeps fast two-thumb typing in
/// order (#140). It holds no timers and draws nothing: `KeyboardView` feeds it touches and acts on what it
/// returns, and the tests feed it whole timelines.
///
/// Three rules keep a fast tap from being read as a swipe, all from Android's open-source keyboard (AOSP
/// LatinIME, the code Gboard grew from):
/// - **Rollover.** When a finger lifts, every older finger still down on a letter or space types first, in
///   the order they landed (LatinIME `PointerTracker.onUpEvent`, `PointerTrackerQueue.releaseAllPointersOlderThan`).
/// - **One finger swipes.** A finger slides into a swipe only while it is the only one on the keys; with
///   another finger down it stays a tap (LatinIME "detected sliding finger while multi touching").
/// - **No swipe straight after typing.** A finger that lands within 350 ms of the last tap (or while another
///   finger types) needs to travel
///   6 key widths, falling to the usual 0.7 over 450 ms, and to stay down at least 300 ms falling to 20 ms,
///   before it becomes a swipe (LatinIME `GestureStrokeRecognitionParams`: 350 ms, 6.0 → 0.35 key widths,
///   300 → 20 ms, 450 ms decay). A thumb that rolls as it lifts no longer turns its letter into a swipe.
public struct TouchArbiter<ID: Hashable> {
  /// What a finger's progress means for the keyboard.
  public enum Event: Equatable {
    /// A tap released: a character key types, other keys act (delete has already acted on touch-down).
    case tapped(Key, at: CGPoint, touch: ID)
    /// A finger crossed the threshold: stop its long-press timer, hide its balloon, draw a trail.
    case swipeStarted(touch: ID)
    /// A swipe ended; decode this trace.
    case swiped([CGPoint], touch: ID)
  }

  public enum Mode: Equatable {
    /// A character or space key, released early by a newer finger lifting.
    case tap
    /// Any other key: acts only when its own finger lifts, and never swipes.
    case press
    case swiping
    /// The view owns it: long-press alternatives or the space-bar trackpad.
    case held
    /// Already typed by rollover; the finger is still down but means nothing more.
    case spent
  }

  private struct Track {
    let id: ID
    let key: Key
    let start: CGPoint
    let began: TimeInterval
    var points: [CGPoint]
    var mode: Mode
    var canSwipe: Bool
    /// Held for long-press alternatives, which type when the finger lifts (the trackpad types nothing).
    var holdTypes = false
    /// Went a swipe's distance from where it landed at some point: never a long press after that.
    var travelled = false
  }

  /// One key's width, the unit of every distance.
  public var unitWidth: CGFloat
  /// Distance a finger travels before it becomes a swipe, in key widths.
  public static var swipeDistance: CGFloat { 0.7 }
  static var fastTypingWindow: TimeInterval { 0.35 }
  static var fastTypingDecay: TimeInterval { 0.45 }
  static var fastTypingDistance: CGFloat { 6 }
  static var fastTypingTime: (from: TimeInterval, to: TimeInterval) { (0.30, 0.02) }

  private var tracks: [Track] = []
  private var lastTap: TimeInterval?

  public init(unitWidth: CGFloat) { self.unitWidth = unitWidth }

  public func mode(of id: ID) -> Mode? { tracks.first { $0.id == id }?.mode }
  public func points(of id: ID) -> [CGPoint] { tracks.first { $0.id == id }?.points ?? [] }
  public var isEmpty: Bool { tracks.isEmpty }

  /// A finger landed on `key`. `canSwipe`: a letter key on the letters page.
  public mutating func began(_ id: ID, key: Key, at p: CGPoint, time: TimeInterval, canSwipe: Bool) {
    tracks.removeAll { $0.id == id }
    let releasable = key.isCharacter || key.action == .space
    // kept in landing order, which rollover types in, even when UIKit hands over two touches at once
    let at = tracks.firstIndex { $0.began > time } ?? tracks.endIndex
    tracks.insert(Track(id: id, key: key, start: p, began: time, points: [p], mode: releasable ? .tap : .press,
                        canSwipe: canSwipe), at: at)
  }

  /// The finger moved through these samples, oldest first.
  public mutating func moved(_ id: ID, _ samples: [(CGPoint, TimeInterval)]) -> [Event] {
    var events: [Event] = []
    guard let i = tracks.firstIndex(where: { $0.id == id }) else { return events }
    for (p, t) in samples {
      tracks[i].points.append(p)
      let start = tracks[i].start
      if hypot(p.x - start.x, p.y - start.y) > Self.swipeDistance * unitWidth { tracks[i].travelled = true }
      if tracks[i].mode == .tap, tracks[i].canSwipe, startsSwipe(tracks[i], at: p, time: t) {
        tracks[i].mode = .swiping
        events.append(.swipeStarted(touch: id))
      }
    }
    return events
  }

  private func startsSwipe(_ track: Track, at p: CGPoint, time: TimeInterval) -> Bool {
    guard tracks.count == 1 else { return false }
    let travelled = hypot(p.x - track.start.x, p.y - track.start.y)
    let base = Self.swipeDistance * unitWidth
    // a tap typed shortly before this finger landed, or by another finger while it was down
    guard let lastTap, lastTap > track.began - Self.fastTypingWindow else { return travelled > base }
    let elapsed = time - track.began
    let decay = max(0, 1 - elapsed / Self.fastTypingDecay)
    let distance = base + (Self.fastTypingDistance * unitWidth - base) * decay
    let (from, to) = Self.fastTypingTime
    return travelled > distance && elapsed >= to + (from - to) * decay
  }

  /// The keys left the letters page: fingers still down tap rather than swipe, and a swipe under way is
  /// dropped (its letters belong to a page no longer shown).
  public mutating func stopSwipes() {
    for i in tracks.indices {
      tracks[i].canSwipe = false
      if tracks[i].mode == .swiping { tracks[i].mode = .spent }
    }
  }

  /// The view took this finger over: long-press alternatives showed (`types`: they type on lift), or the
  /// space bar became a trackpad. False when rollover has already typed it, or when a letter finger has
  /// travelled a swipe's distance and is only waiting out the after-typing delay.
  @discardableResult public mutating func hold(_ id: ID, types: Bool) -> Bool {
    guard let i = tracks.firstIndex(where: { $0.id == id }), tracks[i].mode == .tap || tracks[i].mode == .press
    else { return false }
    if tracks[i].canSwipe, tracks[i].travelled { return false }
    tracks[i].mode = .held
    tracks[i].holdTypes = types
    return true
  }

  /// The finger lifted. Older fingers still on a letter or space type first.
  public mutating func ended(_ id: ID, at p: CGPoint, time: TimeInterval) -> [Event] {
    guard let i = tracks.firstIndex(where: { $0.id == id }) else { return [] }
    var events: [Event] = []
    let track = tracks[i]
    if track.mode != .spent {
      for j in 0..<i where tracks[j].mode == .tap {
        events += release(j, at: tracks[j].points.last ?? tracks[j].start, time: time)
      }
    }
    switch track.mode {
    case .tap, .press:
      events.append(.tapped(track.key, at: p, touch: id))
      // return and tab type too, though another finger lifting never types them early
      if track.mode == .tap || track.key.action == .returnKey || track.key.action == .tab { lastTap = time }
    case .swiping: events.append(.swiped(track.points + [p], touch: id))
    case .held: if track.holdTypes { lastTap = time }  // the view types the alternative
    case .spent: break
    }
    tracks.removeAll { $0.id == id }
    return events
  }

  /// The system took the touch away: it means nothing.
  public mutating func cancelled(_ id: ID) {
    tracks.removeAll { $0.id == id }
  }

  private mutating func release(_ i: Int, at p: CGPoint, time: TimeInterval) -> [Event] {
    tracks[i].mode = .spent
    lastTap = time
    return [.tapped(tracks[i].key, at: p, touch: tracks[i].id)]
  }
}
